// 只读检查 DLL 产物的 PE 布局、导出接口和安全约束。
module org.rocex.firefox.test.PeArtifactTests;

import org.rocex.firefox.test.ConsoleEncodingTests: writeln = consoleLine;

import std.algorithm: canFind, sort;
import std.array: array;
import std.conv: to;
import std.digest: toHexString;
import std.digest.sha: sha256Of;
import std.exception: enforce;
import std.file: exists, read, readText;
import std.path: buildPath;
import std.process: environment;
import std.string: indexOf, splitLines, strip, toLower;

// 只读 PE 解析器，不调用 LoadLibrary，不执行入口或导出函数。
struct PeImageReader
{
    const(ubyte)[] bytes;
    size_t optionalOffset;
    bool is64;
    PeSectionHeader[] sections;

    // 获取数据目录的 RVA。
    uint directoryRva(size_t index) const
    {
        return readValue(optionalOffset + (is64 ? 112 : 96) + index * 8);
    }

    // 将落盘 RVA 转换为文件偏移，不允许读取仅有虚拟空间的区域。
    size_t fileOffset(uint rva) const
    {
        foreach(section; sections)
        {
            if(rva >= section.rva && cast(ulong)rva < cast(ulong)section.rva + section.rawSize)
            {
                return cast(size_t)section.rawOffset + rva - section.rva;
            }
        }

        throw new Exception("RVA 不对应文件数据：" ~ rva.to!string);
    }

    // 验证 PE 头并读取节表。
    void parse()
    {
        sections = null;
        enforce(readValue(0, 2) == 0x5a4d, "缺少 MZ 头");
        size_t peOffset = readValue(0x3c);
        enforce(readValue(peOffset) == 0x4550, "缺少 PE 头");
        uint machine = readValue(peOffset + 4, 2);
        enforce(machine == 0x8664 || machine == 0x14c, "必须为 x64 或 x86");
        is64 = machine == 0x8664;
        enforce((readValue(peOffset + 22, 2) & 0x2000) != 0, "必须为 DLL");
        optionalOffset = peOffset + 24;
        enforce(readValue(optionalOffset, 2) == (is64 ? 0x20b : 0x10b), "PE 格式与机器类型不匹配");
        size_t tableOffset = optionalOffset + readValue(peOffset + 20, 2);
        foreach(index; 0 .. readValue(peOffset + 6, 2))
        {
            size_t offset = tableOffset + index * 40;
            auto section = PeSectionHeader(readValue(offset + 8), readValue(offset + 12), readValue(offset + 16), readValue(offset + 20), readValue(offset + 36));
            enforce(cast(ulong)section.rawOffset + section.rawSize <= bytes.length, "节超出文件");
            enforce(!((section.flags & 0x20000000) && (section.flags & 0x80000000)), "存在可写且可执行节");
            sections ~= section;
        }

        uint entryRva = readValue(optionalOffset + 16);
        bool executableEntry;
        foreach(section; sections)
        {
            if(entryRva >= section.rva && cast(ulong)entryRva < cast(ulong)section.rva + section.virtualSize)
            {
                executableEntry = (section.flags & 0x20000000) != 0;
            }
        }

        enforce(executableEntry, "入口不在可执行节");
    }

    // 读取零结尾 ASCII 名称。
    string readString(uint rva) const
    {
        size_t offset = fileOffset(rva);
        size_t end = offset;
        while(end < bytes.length && bytes[end])
        {
            ++end;
        }

        enforce(end < bytes.length, "PE 字符串未终止");
        return cast(string)bytes[offset .. end].idup;
    }

    // 所有字段读取均做范围检查，避免损坏文件越界。
    uint readValue(size_t offset, size_t count = 4) const
    {
        enforce(count <= 4 && offset <= bytes.length && count <= bytes.length - offset, "PE 字段越界");
        uint result;
        foreach(index; 0 .. count)
        {
            result |= cast(uint)bytes[offset + index] << (index * 8);
        }

        return result;
    }

    // 检查系统依赖、导出裸跳转、目标槽及安全标志。
    void verifyExports(string[] expectedNames) const
    {
        string[] imports;
        size_t offset = fileOffset(directoryRva(1));
        while(readValue(offset + 12))
        {
            imports ~= readString(readValue(offset + 12)).toLower;
            size_t thunk = fileOffset(readValue(offset) ? readValue(offset) : readValue(offset + 16));
            while(readValue(thunk) || (is64 && readValue(thunk + 4)))
            {
                bool ordinalImport = (readValue(thunk + (is64 ? 4 : 0)) & 0x80000000) != 0;
                if(!ordinalImport)
                {
                    string functionName = readString(readValue(thunk) + 2);
                    enforce(!["CreateDirectoryA", "CreateDirectoryW", "CreateDirectoryExA", "CreateDirectoryExW"].canFind(functionName),
                        "纯路径替换产物不得导入目录创建 API");
                }
                thunk += is64 ? 8 : 4;
            }
            offset += 20;
        }

        enforce(imports == ["kernel32.dll"], "发现非预期依赖：" ~ imports.to!string);
        enforce(directoryRva(9) == 0 && directoryRva(13) == 0 && directoryRva(14) == 0, "不得包含 TLS、延迟导入或 CLR");
        uint requiredFlags = is64 ? 0x160 : 0x140;
        enforce((readValue(optionalOffset + 70, 2) & requiredFlags) == requiredFlags, "缺少地址随机化或 NX 标志");
        if(!is64)
        {
            enforce(directoryRva(5) != 0, "x86 绝对地址跳转必须具有重定位表");
        }

        size_t exportOffset = fileOffset(directoryRva(0));
        uint nameCount = readValue(exportOffset + 24);
        enforce(nameCount == 17, "应导出 17 个版本接口");
        size_t namesOffset = fileOffset(readValue(exportOffset + 32));
        size_t ordinalsOffset = fileOffset(readValue(exportOffset + 36));
        size_t functionsOffset = fileOffset(readValue(exportOffset + 28));
        string[] actualNames;
        foreach(index; 0 .. nameCount)
        {
            actualNames ~= readString(readValue(namesOffset + index * 4));
            uint ordinal = readValue(ordinalsOffset + index * 2, 2);
            enforce(readValue(exportOffset + 16) + ordinal == index + 1, "导出序号发生变化");
            uint functionRva = readValue(functionsOffset + ordinal * 4);
            size_t functionOffset = fileOffset(functionRva);
            long targetRva;
            if(is64)
            {
                enforce(readValue(functionOffset, 3) == 0x1d8b4c, "x64 导出必须只加载 R11 暂存寄存器");
                // DMD 使用 REX.WB，LDC 使用 REX.B；间接近跳转在 x64 下两者语义相同。
                uint jumpEncoding = readValue(functionOffset + 7, 3);
                enforce(jumpEncoding == 0xe3ff41 || jumpEncoding == 0xe3ff49, "x64 导出必须直接跳转 R11");
                targetRva = cast(long)functionRva + 7 + cast(int)readValue(functionOffset + 3);
            }
            else
            {
                enforce(readValue(functionOffset, 1) == 0xa1, "x86 导出必须只加载 EAX 暂存寄存器");
                enforce(readValue(functionOffset + 5, 2) == 0xe0ff, "x86 导出必须直接跳转 EAX");
                targetRva = cast(long)readValue(functionOffset + 1) - readValue(optionalOffset + 28);
            }

            bool writableSlot;
            foreach(section; sections)
            {
                if(targetRva >= section.rva && targetRva + (is64 ? 8 : 4) <= cast(long)section.rva + section.virtualSize)
                {
                    writableSlot = (section.flags & 0x80000000) != 0;
                }
            }

            enforce(writableSlot, "接口跳转槽不在可写数据节");
        }

        enforce(actualNames.sort.array == expectedNames.sort.array, "导出接口与定义不匹配");
        enforce(bytes.length <= 24576, "DLL 超过 24 KiB 体积预算");
    }
}

// PE 节的文件布局和运行时权限。
struct PeSectionHeader
{
    uint virtualSize, rva, rawSize, rawOffset, flags;
}

// 纯内存负例覆盖字段越界、损坏头、无落盘 RVA 和未终止字符串。
unittest
{
    import std.exception: assertThrown;

    auto emptyImage = PeImageReader([]);
    assertThrown!Exception(emptyImage.parse());
    assertThrown!Exception(emptyImage.readValue(size_t.max));
    assertThrown!Exception(emptyImage.readValue(0, 5));

    auto invalidHeader = PeImageReader(new ubyte[64]);
    assertThrown!Exception(invalidHeader.parse());
    ubyte[] truncatedHeader = new ubyte[64];
    truncatedHeader[0] = 0x4d;
    truncatedHeader[1] = 0x5a;
    truncatedHeader[0x3c] = 0xff;
    auto truncatedImage = PeImageReader(truncatedHeader);
    assertThrown!Exception(truncatedImage.parse());

    auto stringImage = PeImageReader(cast(const(ubyte)[])[0x41, 0x42]);
    stringImage.sections = [PeSectionHeader(4, 0x1000, 2, 0, 0)];
    assertThrown!Exception(stringImage.fileOffset(0x1002));
    assertThrown!Exception(stringImage.readString(0x1000));
}

// 构造最小内存 PE，仅用于校验头、节权限和入口的解析负例。
unittest
{
    import std.exception: assertThrown;

    ubyte[] imageBytes = new ubyte[512];
    // 按小端写入内存字段，不读写任何磁盘产物。
    void putValue(size_t offset, uint value, size_t count = 4)
    {
        foreach(index; 0 .. count)
        {
            imageBytes[offset + index] = cast(ubyte)(value >> (index * 8));
        }
    }

    putValue(0, 0x5a4d, 2);
    putValue(0x3c, 64);
    putValue(64, 0x4550);
    putValue(68, 0x8664, 2);
    putValue(70, 1, 2);
    putValue(84, 112, 2);
    putValue(86, 0x2000, 2);
    putValue(88, 0x20b, 2);
    putValue(104, 0x1000);
    putValue(208, 16);
    putValue(212, 0x1000);
    putValue(216, 16);
    putValue(220, 256);
    putValue(236, 0x20000000);
    auto validImage = PeImageReader(imageBytes);
    validImage.parse();

    // 每个变体从有效内存样本复制，避免负例之间相互污染。
    void expectInvalid(size_t offset, uint value, size_t count = 4)
    {
        auto savedBytes = imageBytes.dup;
        putValue(offset, value, count);
        auto invalidImage = PeImageReader(imageBytes);
        assertThrown!Exception(invalidImage.parse());
        imageBytes = savedBytes;
    }

    expectInvalid(64, 0);
    expectInvalid(68, 0, 2);
    expectInvalid(86, 0, 2);
    expectInvalid(88, 0x10b, 2);
    expectInvalid(220, 512);
    expectInvalid(236, 0xa0000000);
    expectInvalid(104, 0x2000);
    expectInvalid(236, 0);
}

// 默认严格核对两个架构的落盘产物；缺失即失败，路径相对于项目根目录。
unittest
{
    string definitionPath = buildPath("source", "org", "rocex", "firefox", "VersionExports.def");
    enforce(exists(definitionPath), "缺少导出定义：" ~ definitionPath);
    string[] expectedNames;
    foreach(line; readText(definitionPath).splitLines)
    {
        auto trimmed = line.strip;
        auto separator = trimmed.indexOf('=');
        if(separator > 0)
        {
            expectedNames ~= trimmed[0 .. separator];
        }
    }

    enforce(expectedNames.length == 17, "导出定义应包含 17 个接口");
    foreach(architecture; ["x86_64", "x86"])
    {
        auto dllPath = buildPath(environment.get("PORTABLE_ARTIFACT_ROOT", "dist"), architecture, "version.dll");
        enforce(exists(dllPath), "缺少待校验产物：" ~ dllPath);
        auto image = PeImageReader(cast(ubyte[])read(dllPath));
        image.parse();
        enforce(image.is64 == (architecture == "x86_64"), "产物架构与目录不匹配：" ~ dllPath);
        image.verifyExports(expectedNames);
        writeln("静态校验通过：", dllPath, "，架构 ", architecture, "，17 个接口。");
        writeln("产物字节数：", image.bytes.length);
        writeln("SHA-256：", sha256Of(image.bytes).toHexString.toLower);
    }

    string referencePath = buildPath("参考", "version.dll");
    if(exists(referencePath))
    {
        auto referenceHash = sha256Of(cast(ubyte[])read(referencePath)).toHexString.idup.toLower;
        enforce(referenceHash == "d2d9242307b199ecc7fd1981ac40862b9d84276c2d6a5364ab8400d98138aefc", "参考样本已改变");
        writeln("参考样本：哈希未变");
    }

    writeln("显式导入仅依赖 KERNEL32.dll；运行时另从系统目录加载 version、shell32 和 ole32。");
    writeln("产物校验阶段未加载或执行 DLL。");
}
