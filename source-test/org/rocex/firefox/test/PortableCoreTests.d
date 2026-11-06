// 验证配置解析、路径派生和系统版本接口转发。
module org.rocex.firefox.test.PortableCoreTests;

import org.rocex.firefox.FirefoxPortable;

import core.sys.windows.windows;
import core.volatile: volatileLoad;
import std.conv: to;
import std.exception: enforce;
import std.file: exists, mkdir, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.utf: toUTF16;

// 通过未知函数地址模拟模块外部调用，避免优化器按桩的 void 声明折叠测试。
size_t callForward(size_t address) nothrow @nogc
{
    alias VersionForwardingTestFunction = extern (Windows) size_t function(size_t, size_t, size_t, size_t, size_t, size_t, size_t) nothrow @nogc;
    return (cast(VersionForwardingTestFunction)volatileLoad(&address))(1, 2, 3, 4, 5, 6, 7);
}

// 与零结尾缓冲区比较，避免依赖 D 数组默认填充值。
void expectText(const(wchar)* actual, wstring expected)
{
    enforce(actual[0 .. textLength(actual)] == expected, "文本结果与预期不符");
}

// 用超过寄存器参数数量的 stdcall 调用核对裸跳转，不执行系统版本接口。
extern (Windows) size_t forwardingTarget(size_t first, size_t second, size_t third, size_t fourth, size_t fifth, size_t sixth, size_t seventh) nothrow @nogc
{
    return first + second * 2 + third * 3 + fourth * 4 + fifth * 5 + sixth * 6 + seventh * 7;
}

// 将测试内容送入正式解码器及解析器，不执行 DLL 入口。
void parseText(string text, bool expected = true)
{
    enforce(text.length <= iniCapacity);
    foreach(index, value; text)
    {
        iniBytes[index] = cast(ubyte)value;
    }

    bool result = decodeIni(cast(DWORD)text.length) && parseIni();
    enforce(result == expected, "配置解析结果不符：" ~ text);
}

// 全部 17 个导出桩使用真实调用验证 x86 栈清理和 x64 寄存器／栈参数保持。
unittest
{
    static assert(exportNames.length == 17);
    static foreach(index, name; exportNames)
    {
        versionTargets[index] = cast(void*)&forwardingTarget;
        mixin("enforce(callForward(cast(size_t)&proxy" ~ name ~ ") == 140);");
        versionTargets[index] = null;
    }
}

// 只解析 Windows 系统 version.dll，逐项核对紧凑名称串与连续槽对应关系。
unittest
{
    enforce(loadSystemVersion(GetModuleHandleW(null)));
    auto systemModule = GetModuleHandleW(scratchPath.ptr);
    enforce(systemModule !is null);
    static foreach(index, name; exportNames)
    {
        enforce(versionTargets[index] == cast(void*)GetProcAddress(systemModule, (name ~ '\0').ptr), "系统导出名称与转发槽错位");
    }
}

// 验证无节配置、节标题忽略、未知键忽略及重复根键拒绝。
unittest
{
    parseText("");
    expectText(profileValue.ptr, "profile"w);
    parseText("[General]\nPortableDataPath=资料\n[Env]\nTmpDataPath=缓存\n");
    expectText(profileValue.ptr, "资料"w);
    parseText("PortableDataPath=custom\n");
    expectText(profileValue.ptr, "custom"w);
    parseText("[General]\n[Env]\nTmpDataPath=temp\n");
    expectText(profileValue.ptr, "profile"w);
    parseText("[Other]\nPortableDataPath=accepted\n[General]\nPortable=1\nOtherOption=yes\n");
    expectText(profileValue.ptr, "accepted"w);
    parseText("PortableDataPath=\nUnknown=value\n");
    expectText(profileValue.ptr, "profile"w);
    parseText("PortableDataPath=a\n[Other]\nportabledatapath=b\n", false);
    parseText("PortableDataPath=\nPortableDataPath=b\n", false);
    parseText("[general]\nportabledatapath=\"中文 目录\"\n[env]\nTMPDATAPATH=\n");
    expectText(profileValue.ptr, "中文 目录"w);
    parseText("[General]\n[Env]\nTmpDataPath=a\n[Env]\nTmpDataPath=b\n");
    parseText("[General]\nbroken line\n", false);
}

// UTF-8、UTF-16LE、空 BOM 和非法编码边界。
unittest
{
    parseText("PortableDataPath=a\0b", false);
    parseText("\xef\xbb\xbf");
    parseText("\xc0\xaf", false);

    auto utf16Text = "[General]\r\nPortableDataPath=中文\r\n[Env]\nTmpDataPath=缓存\r\n"w;
    iniBytes[0] = 0xff;
    iniBytes[1] = 0xfe;
    foreach(index, value; utf16Text)
    {
        iniBytes[index * 2 + 2] = cast(ubyte)value;
        iniBytes[index * 2 + 3] = cast(ubyte)(value >> 8);
    }

    enforce(decodeIni(cast(DWORD)(utf16Text.length * 2 + 2)) && parseIni());
    expectText(profileValue.ptr, "中文"w);
    enforce(decodeIni(2) && parseIni());
    expectText(profileValue.ptr, "profile"w);
    iniBytes[2] = 0;
    iniBytes[3] = 0xd8;
    enforce(!decodeIni(4), "应拒绝孤立 UTF-16 代理项");
    enforce(!decodeIni(3), "应拒绝奇数字节 UTF-16");
    enforce(!decodeIni(iniCapacity + 1));
}

// 路径派生和内容进程参数识别；不访问 UNC 网络共享。
unittest
{
    enforce(isContentProcess("firefox.exe -contentproc"w.ptr));
    enforce(isContentProcess("firefox.exe --contentproc"w.ptr));
    enforce(!isContentProcess("firefox.exe --backgroundtask task"w.ptr));
    enforce(!isContentProcess("firefox.exe -backgroundtask task"w.ptr));
    enforce(!isContentProcess("firefox.exe -contentprocessor"w.ptr));
    enforce(!isContentProcess("firefox.exe \"text -contentproc\""w.ptr));
    enforce(isContentProcess("\"C:\\Program Files\\firefox.exe\" \"--contentproc\""w.ptr));
    enforce(isContentProcess("firefox.exe --contentproc=child"w.ptr));
    enforce(isContentProcess("firefox.exe\t-content\"proc\""w.ptr));
    enforce(!isContentProcess(`firefox.exe -contentproc\"`w.ptr));
    enforce(!isContentProcess(`firefox.exe "-contentproc\\"`w.ptr));
    enforce(!isContentProcess(`firefox.exe -contentproc\`w.ptr));
    enforce(isContentProcess(`firefox.exe "text\" -contentproc" --contentproc`w.ptr));

    enforce(putText(basePath.ptr, "C:\\便携 测试\\App\\"w.ptr));
    parseText("");
    enforce(preparePaths());
    expectText(profilePath.ptr, "C:\\便携 测试\\App\\profile"w);
    expectText(cachePath.ptr, "C:\\便携 测试\\App\\profile\\AppData"w);
    expectText(metadataPath.ptr, "C:\\便携 测试\\App\\profile\\AppData\\State"w);
    expectText(roamingPath.ptr, "C:\\便携 测试\\App\\profile\\AppData\\RoamingAppData"w);
    expectText(commonPath.ptr, "C:\\便携 测试\\App\\profile\\AppData\\ProgramData"w);
    enforce(resolvePath("profile/AppData"w.ptr, cachePath.ptr));
    expectText(cachePath.ptr, "C:\\便携 测试\\App\\profile\\AppData"w);
    enforce(resolvePath("../Profiles"w.ptr, profilePath.ptr));
    expectText(profilePath.ptr, "C:\\便携 测试\\Profiles"w);
    enforce(resolvePath("D:/绝对路径"w.ptr, profilePath.ptr));
    expectText(profilePath.ptr, "D:\\绝对路径"w);
    enforce(!resolvePath("C:relative"w.ptr, profilePath.ptr));
    enforce(!resolvePath("\\relative"w.ptr, profilePath.ptr));
    enforce(!resolvePath("\\\\?\\C:\\device"w.ptr, profilePath.ptr));
    enforce(!resolvePath("\\\\.\\device"w.ptr, profilePath.ptr));
    enforce(resolvePath("\\\\server\\share\\folder"w.ptr, profilePath.ptr));
    expectText(profilePath.ptr, "\\\\server\\share\\folder"w);
    // 只解析 UNC 文本，不访问网络共享。
    enforce(SetEnvironmentVariableW("PORTABLE_TEST_ROOT"w.ptr, "D:\\环境目录"w.ptr) != 0);
    scope(exit)
    {
        SetEnvironmentVariableW("PORTABLE_TEST_ROOT"w.ptr, null);
    }
    enforce(resolvePath("%PORTABLE_TEST_ROOT%/缓存"w.ptr, cachePath.ptr));
    expectText(cachePath.ptr, "D:\\环境目录\\缓存"w);
    parseText("PortableDataPath=%PORTABLE_TEST_ROOT%/profile\n");
    enforce(preparePaths());
    expectText(profilePath.ptr, "D:\\环境目录\\profile"w);
    enforce(SetEnvironmentVariableW("PORTABLE_TEST_ROOT"w.ptr, "C:\\changed"w.ptr));
    parseText("PortableDataPath=%PORTABLE_TEST_ROOT%/profile\n");
    enforce(preparePaths());
    expectText(cachePath.ptr, "C:\\changed\\profile\\AppData"w);
}

// 在唯一临时目录验证配置读取与纯路径派生，不执行进程级钩子或创建数据目录。
unittest
{
    enforce(putText(basePath.ptr, "C:\\便携 测试\\App\\"w.ptr));
    string testPath = buildPath(tempDir(), "portable-tests-" ~ GetCurrentProcessId().to!string ~ "-" ~ GetTickCount().to!string);
    enforce(!exists(testPath), "临时测试目录已存在");
    mkdir(testPath);
    scope(exit)
    {
        rmdirRecurse(testPath);
    }
    auto absentPath = toUTF16(buildPath(testPath, "portable.ini") ~ "\0");
    enforce(putText(iniPath.ptr, absentPath.ptr));
    enforce(readIni() && parseIni());
    expectText(profileValue.ptr, "profile"w);
    write(buildPath(testPath, "portable.ini"), "");
    enforce(readIni() && parseIni());
    write(buildPath(testPath, "portable.ini"), "PortableDataPath=数据\nTmpDataPath=本地\n");
    enforce(readIni() && parseIni());
    expectText(profileValue.ptr, "数据"w);
    enforce(preparePaths());
    expectText(cachePath.ptr, "C:\\便携 测试\\App\\数据\\AppData"w);
    expectText(roamingPath.ptr, "C:\\便携 测试\\App\\数据\\AppData\\RoamingAppData"w);
    expectText(commonPath.ptr, "C:\\便携 测试\\App\\数据\\AppData\\ProgramData"w);
    expectText(metadataPath.ptr, "C:\\便携 测试\\App\\数据\\AppData\\State"w);
    {
        auto lockedHandle = CreateFileW(iniPath.ptr, GENERIC_READ, 0, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        enforce(lockedHandle != INVALID_HANDLE_VALUE);
        scope(exit)
        {
            CloseHandle(lockedHandle);
        }
        enforce(!readIni(), "文件被锁定时不得静默使用默认配置");
    }

    auto nestedPath = toUTF16(buildPath(testPath, "中文", "配置") ~ "\0");
    enforce(putText(profilePath.ptr, nestedPath.ptr));
    enforce(prepareAuxiliaryPaths());
    enforce(!exists(buildPath(testPath, "中文")), "路径派生不得创建目录或测试文件");
}
