// 解析便携配置、重定向 Firefox 数据目录，并转发系统版本接口。
module org.rocex.firefox.FirefoxPortable;

import core.sys.windows.windows;
import org.rocex.firefox.FolderRedirection;

// 缓冲区容量包含结尾零字符。
enum iniCapacity = 65536;
enum pathCapacity = 32768;

// 配置读取缓冲区及配置根值。
__gshared ubyte[iniCapacity + 2] iniBytes;
__gshared wchar[pathCapacity] iniPath = 0;
__gshared wchar[iniCapacity + 2] iniText = 0;
__gshared wchar[pathCapacity] profileValue = 0;

// 便携目录及路径解析缓冲区。
__gshared wchar[pathCapacity] basePath = 0;
__gshared wchar[pathCapacity] cachePath = 0;
__gshared wchar[pathCapacity] commonPath = 0;
__gshared wchar[pathCapacity] expandedPath = 0;
__gshared wchar[pathCapacity] metadataPath = 0;
__gshared wchar[pathCapacity] profilePath = 0;
__gshared wchar[pathCapacity] roamingPath = 0;
__gshared wchar[pathCapacity] scratchPath = 0;

// UTF-8 日志缓冲区及日志路径。
__gshared char[pathCapacity * 4] logBytes = 0;
__gshared wchar[pathCapacity] logPath = 0;

// 导出列表顺序与转发槽序号一致。
enum exportNames = [
    "GetFileVersionInfoA", "GetFileVersionInfoByHandle", "GetFileVersionInfoExA", "GetFileVersionInfoExW", "GetFileVersionInfoSizeA",
    "GetFileVersionInfoSizeExA", "GetFileVersionInfoSizeExW",
    "GetFileVersionInfoSizeW",
    "GetFileVersionInfoW", "VerFindFileA", "VerFindFileW", "VerInstallFileA", "VerInstallFileW", "VerLanguageNameA", "VerLanguageNameW", "VerQueryValueA",
    "VerQueryValueW"
];

// 系统版本接口的转发地址表。
__gshared void*[exportNames.length] versionTargets;

// 编译期将导出槽偏移转换为汇编混入使用的十进制文本。
private template decimalOffset(size_t value)
{
    static if(value < 10)
    {
        enum decimalOffset = "0123456789"[value .. value + 1];
    }
    else
    {
        enum decimalOffset = decimalOffset!(value / 10) ~ decimalOffset!(value % 10);
    }
}

// 编译期按导出顺序拼接零结尾名称。
private template packedNames(size_t index)
{
    static if(index == exportNames.length)
    {
        enum packedNames = "";
    }
    else
    {
        enum packedNames = exportNames[index] ~ '\0' ~ packedNames!(index + 1);
    }
}

/* x64 仅使用 ABI 允许的易失暂存寄存器 R11，不改变参数寄存器、栈参数和返回地址。
   x86 使用易失寄存器 EAX，保留 stdcall 参数及栈清理责任给真实系统函数。 */
static foreach(index, exportName; exportNames)
{
    version(Win64)
    {
        mixin("extern(C) void proxy" ~ exportName ~ "() nothrow @nogc { asm nothrow @nogc { naked; mov R11, qword ptr [versionTargets + " ~ decimalOffset!(
                index * 8) ~ "]; jmp R11; } }");
    }
    else
    {
        mixin("extern(C) void proxy" ~ exportName ~ "() nothrow @nogc { asm nothrow @nogc { naked; mov EAX, dword ptr [versionTargets + " ~ decimalOffset!(
                index * 4) ~ "]; jmp EAX; } }");
    }
}

// 在 Firefox 选择配置前设置便携路径。
bool configurePortable(HINSTANCE moduleHandle) nothrow @nogc
{
    DWORD count = GetModuleFileNameW(null, scratchPath.ptr, pathCapacity);
    if(!count || count >= pathCapacity)
    {
        return false;
    }
    auto fileName = scratchPath.ptr;
    foreach(index; 0 .. count)
    {
        if(scratchPath[index] == '\\')
        {
            fileName = scratchPath.ptr + index + 1;
        }
    }
    if(lstrcmpiW(fileName, "firefox.exe"w.ptr) != 0)
    {
        return true;
    }
    // 内容类子进程不重复初始化，避免干预沙箱。
    if(isContentProcess())
    {
        return true;
    }
    count = GetModuleFileNameW(moduleHandle, basePath.ptr, pathCapacity);
    if(!count || count >= pathCapacity)
    {
        return false;
    }
    while(count && basePath[count - 1] != '\\')
    {
        --count;
    }
    if(!count)
    {
        return false;
    }
    basePath[count] = 0;
    if(!putText(iniPath.ptr, basePath.ptr) || !putText(iniPath.ptr, "portable.ini"w.ptr, true) || !putText(logPath.ptr, basePath.ptr) || !putText(logPath.ptr,
            "portable.log"w.ptr, true))
    {
        return false;
    }
    auto fileHandle = CreateFileW(logPath.ptr, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if(fileHandle != INVALID_HANDLE_VALUE)
    {
        CloseHandle(fileHandle);
    }
    if(GetModuleHandleW("portable64.dll"w.ptr) || GetModuleHandleW("portable32.dll"w.ptr))
    {
        return failStart("检测到其他便携模块，请使用官方 Firefox 程序文件。"w.ptr);
    }
    if(!readIni() || !parseIni())
    {
        return failStart("portable.ini 不可读、编码无效或路径键重复。"w.ptr);
    }
    if(!preparePaths())
    {
        return failStart("PortableDataPath 无效或过长。"w.ptr);
    }
    if(!setProfileEnvironment())
    {
        return failStart("无法设置 Firefox 便携环境。"w.ptr);
    }
    if(!initializeFolderHooks(moduleHandle, roamingPath.ptr, cachePath.ptr, commonPath.ptr) || !patchBrowserModules())
    {
        return failStart("无法安装便携系统目录重定向。"w.ptr);
    }
    writeLog("Firefox 便携配置及系统目录重定向已应用。"w.ptr);
    writeLog(profilePath.ptr);
    writeLog(cachePath.ptr);
    return true;
}

// 严格解码 UTF-8 / UTF-16LE；空文件和仅含 BOM 的文件使用默认配置。
bool decodeIni(DWORD byteCount) nothrow @nogc
{
    if(byteCount > iniCapacity)
    {
        return false;
    }
    iniText[0] = 0;
    size_t textCount;
    if(byteCount >= 2 && iniBytes[0] == 0xff && iniBytes[1] == 0xfe)
    {
        if(byteCount % 2)
        {
            return false;
        }
        textCount = (byteCount - 2) / 2;
        foreach(index; 0 .. textCount)
        {
            iniText[index] = cast(wchar)(iniBytes[index * 2 + 2] | (iniBytes[index * 2 + 3] << 8));
        }

        // UTF-16 代理项必须成对，避免向文件 API 传入畸形文本。
        for(size_t index; index < textCount; ++index)
        {
            uint code = iniText[index];
            if(code >= 0xd800 && code <= 0xdbff)
            {
                if(++index >= textCount || iniText[index] < 0xdc00 || iniText[index] > 0xdfff)
                {
                    return false;
                }
            }
            else if(code >= 0xdc00 && code <= 0xdfff)
            {
                return false;
            }
        }
    }
    else
    {
        uint offset = byteCount >= 3 && iniBytes[0] == 0xef && iniBytes[1] == 0xbb && iniBytes[2] == 0xbf ? 3 : 0;
        if(byteCount == offset)
        {
            return true;
        }
        int converted = MultiByteToWideChar(65001, 8, cast(const(char)*)iniBytes.ptr + offset, cast(int)(byteCount - offset), iniText.ptr, cast(int)iniText
                .length - 1);
        if(converted <= 0)
        {
            return false;
        }
        textCount = converted;
    }

    foreach(index; 0 .. textCount)
    {
        if(!iniText[index])
        {
            return false;
        }
    }

    iniText[textCount] = 0;
    return true;
}

// 在 DLL 进程附加时初始化；加载锁下的初始化仍有兼容性约束。
extern (Windows) BOOL dllEntry(HINSTANCE moduleHandle, DWORD reason, LPVOID reserved) nothrow @nogc
{
    if(reason != DLL_PROCESS_ATTACH)
    {
        return TRUE;
    }
    if(!loadSystemVersion(moduleHandle))
    {
        return FALSE;
    }
    DisableThreadLibraryCalls(moduleHandle);
    return configurePortable(moduleHandle) ? TRUE : FALSE;
}

// 编译期计算含零终止符的导出名称长度。
private ubyte[exportNames.length] exportNameSizes() pure nothrow @nogc
{
    ubyte[exportNames.length] sizes;
    foreach(index, name; exportNames)
    {
        sizes[index] = cast(ubyte)(name.length + 1);
    }
    return sizes;
}

// 记录配置错误并终止当前进程，防止误用系统配置。
bool failStart(const(wchar)* message) nothrow @nogc
{
    writeLog("错误：便携配置未生效，停止启动。"w.ptr);
    writeLog(message);
    TerminateProcess(GetCurrentProcess(), 1610);
    return false;
}

// 按 Windows 引号规则识别完整参数，也接受参数后的等号。
bool hasArgument(const(wchar)* wanted, const(wchar)* commandLine = null) nothrow @nogc
{
    auto cursor = commandLine is null ? GetCommandLineW() : commandLine;

    while(*cursor)
    {
        while(*cursor == ' ' || *cursor == '\t')
        {
            ++cursor;
        }
        if(!*cursor)
        {
            break;
        }
        size_t matched;
        bool quoted, mismatch;

        // 比较解码后的参数字符；不分配缓冲区或加载 Shell。
        void matchCharacter(wchar character) nothrow @nogc
        {
            if(wanted[matched] && wanted[matched] == character)
            {
                ++matched;
            }
            else
            {
                mismatch = true;
            }
        }

        while(*cursor && (quoted || (*cursor != ' ' && *cursor != '\t')))
        {
            size_t slashCount;
            while(*cursor == '\\')
            {
                ++slashCount;
                ++cursor;
            }
            if(*cursor == '"')
            {
                foreach(index; 0 .. slashCount / 2)
                {
                    matchCharacter('\\');
                }

                if(slashCount % 2)
                {
                    matchCharacter('"');
                }
                else
                {
                    quoted = !quoted;
                }
                ++cursor;
                continue;
            }

            foreach(index; 0 .. slashCount)
            {
                matchCharacter('\\');
            }

            if(!*cursor || (!quoted && (*cursor == ' ' || *cursor == '\t')))
            {
                break;
            }
            if(!mismatch && !wanted[matched] && *cursor == '=')
            {
                return true;
            }
            matchCharacter(*cursor++);
        }

        if(!mismatch && !wanted[matched])
        {
            return true;
        }
    }

    return false;
}

// 识别 contentproc 参数；后台任务不属于内容进程。
bool isContentProcess(const(wchar)* commandLine = null) nothrow @nogc
{
    return hasArgument("-contentproc"w.ptr, commandLine) || hasArgument("--contentproc"w.ptr, commandLine);
}

// 使用绝对系统路径加载真实 DLL；模块保持加载直至进程退出。
bool loadSystemVersion(HINSTANCE moduleHandle) nothrow @nogc
{
    DWORD count = GetSystemDirectoryW(scratchPath.ptr, pathCapacity);
    if(!count || count >= pathCapacity || !putText(scratchPath.ptr, "\\version.dll"w.ptr, true))
    {
        return false;
    }
    auto systemModule = LoadLibraryExW(scratchPath.ptr, null, 0x800);
    if(!systemModule || systemModule == moduleHandle)
    {
        return false;
    }
    auto name = packedNames!0.ptr;
    static immutable ubyte[exportNames.length] nameSizes = exportNameSizes();

    foreach(index, ref target; versionTargets)
    {
        target = cast(void*)GetProcAddress(systemModule, name);
        if(!target)
        {
            return false;
        }
        name += nameSizes[index];
    }

    return true;
}

// 只读取配置根，缺失或空值使用 profile；其他配置全部忽略。
bool parseIni() nothrow @nogc
{
    if(!putText(profileValue.ptr, "profile"w.ptr))
    {
        return false;
    }
    bool seenProfile;
    auto cursor = iniText.ptr;

    while(*cursor)
    {
        auto line = cursor;
        while(*cursor && *cursor != '\n')
        {
            ++cursor;
        }
        if(*cursor)
        {
            *cursor++ = 0;
        }
        line = trimText(line);
        if(!*line || *line == ';' || *line == '#')
        {
            continue;
        }
        // 忽略节标题，所有配置键使用同一作用域。
        if(*line == '[')
        {
            continue;
        }
        auto value = line;
        while(*value && *value != '=')
        {
            ++value;
        }
        if(!*value)
        {
            return false;
        }
        *value++ = 0;
        line = trimText(line);
        value = trimText(value);
        size_t length = textLength(value);
        if(length >= 2 && value[0] == '"' && value[length - 1] == '"')
        {
            value[length - 1] = 0;
            ++value;
        }
        if(lstrcmpiW(line, "PortableDataPath"w.ptr) == 0)
        {
            if(seenProfile || (*value && !putText(profileValue.ptr, value)))
            {
                return false;
            }
            seenProfile = true;
        }
    }

    return true;
}

// 从配置根派生缓存、系统数据和元数据路径。
bool prepareAuxiliaryPaths() nothrow @nogc
{
    wchar*[4] outputs = [cachePath.ptr, roamingPath.ptr, commonPath.ptr, metadataPath.ptr];
    const(wchar)*[4] suffixes = [""w.ptr, "\\RoamingAppData"w.ptr, "\\ProgramData"w.ptr, "\\State"w.ptr];

    if(!putText(scratchPath.ptr, profilePath.ptr) || !putText(scratchPath.ptr, "\\AppData"w.ptr, true))
    {
        return false;
    }

    foreach(index; 0 .. outputs.length)
    {
        if(!putText(outputs[index], scratchPath.ptr) || !putText(outputs[index], suffixes[index], true))
        {
            return false;
        }
    }

    return true;
}

// 解析配置根并派生 AppData 路径。
bool preparePaths() nothrow @nogc
{
    return resolvePath(profileValue.ptr, profilePath.ptr) && prepareAuxiliaryPaths();
}

// 在固定容量内复制或追加字符串。
bool putText(wchar* destination, const(wchar)* source, bool append = false) nothrow @nogc
{
    size_t offset = append ? textLength(destination) : 0;
    size_t length = textLength(source);
    if(offset + length >= pathCapacity)
    {
        return false;
    }
    foreach(index; 0 .. length + 1)
    {
        destination[offset + index] = source[index];
    }
    return true;
}

// 缺失配置文件视为空配置；权限、共享冲突等读取失败仍返回错误。
bool readIni() nothrow @nogc
{
    iniText[0] = 0;
    auto fileHandle = CreateFileW(iniPath.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if(fileHandle == INVALID_HANDLE_VALUE)
    {
        DWORD errorCode = GetLastError();
        return errorCode == ERROR_FILE_NOT_FOUND || errorCode == ERROR_PATH_NOT_FOUND;
    }
    DWORD highSize;
    DWORD byteCount = GetFileSize(fileHandle, &highSize);
    DWORD actualCount;
    bool valid = highSize == 0 && byteCount <= iniCapacity;
    if(valid)
    {
        valid = ReadFile(fileHandle, iniBytes.ptr, byteCount, &actualCount, null) != 0 && actualCount == byteCount;
    }
    CloseHandle(fileHandle);
    return valid && decodeIni(byteCount);
}

// 展开环境变量并以 DLL 目录为基准；拒绝依赖当前盘符的路径。
bool resolvePath(const(wchar)* value, wchar* output) nothrow @nogc
{
    DWORD count = ExpandEnvironmentStringsW(value, expandedPath.ptr, pathCapacity);
    if(!count || count > pathCapacity)
    {
        return false;
    }
    for(auto cursor = expandedPath.ptr; *cursor; ++cursor)
    {
        if(*cursor == '/')
        {
            *cursor = '\\';
        }
    }
    bool uncPath = expandedPath[0] == '\\' && expandedPath[1] == '\\';
    bool drivePath = expandedPath[0] && expandedPath[1] == ':' && expandedPath[2] == '\\';
    if((expandedPath[0] == '\\' && !uncPath) || (expandedPath[1] == ':' && !drivePath))
    {
        return false;
    }
    // 不接受设备命名空间；普通 UNC 网络共享仍按配置支持。
    if(uncPath && (expandedPath[2] == '?' || expandedPath[2] == '.'))
    {
        return false;
    }
    if(!putText(scratchPath.ptr, uncPath || drivePath ? ""w.ptr : basePath.ptr) || !putText(scratchPath.ptr, expandedPath.ptr, true))
    {
        return false;
    }
    count = GetFullPathNameW(scratchPath.ptr, pathCapacity, output, null);
    if(!count || count >= pathCapacity)
    {
        return false;
    }
    while(count > 3 && output[count - 1] == '\\')
    {
        output[--count] = 0;
    }
    return true;
}

// 设置 XRE/MOZ 变量，保持 Windows 通用目录环境不变。
bool setProfileEnvironment() nothrow @nogc
{
    const(wchar)*[4] names = ["XRE_PROFILE_PATH"w.ptr, "XRE_PROFILE_LOCAL_PATH"w.ptr, "MOZ_APP_DATA"w.ptr, "MOZ_LOCAL_APP_DATA"w.ptr];
    const(wchar)*[4] paths = [profilePath.ptr, cachePath.ptr, metadataPath.ptr, cachePath.ptr];

    foreach(index; 0 .. names.length)
    {
        if(!SetEnvironmentVariableW(names[index], paths[index]))
        {
            return false;
        }
    }

    return true;
}

// 返回零结尾宽字符串的长度。
size_t textLength(const(wchar)* text) nothrow @nogc
{
    size_t length;
    while(text[length])
    {
        ++length;
    }
    return length;
}

// 去除 INI 行或字段两端的空白。
wchar* trimText(wchar* text) nothrow @nogc
{
    while(*text == ' ' || *text == '\t' || *text == '\r')
    {
        ++text;
    }
    size_t length = textLength(text);
    while(length && (text[length - 1] == ' ' || text[length - 1] == '\t' || text[length - 1] == '\r'))
    {
        --length;
    }
    text[length] = 0;
    return text;
}

// 日志为 UTF-8；失败时不改变调用者的错误处理策略。
void writeLog(const(wchar)* text) nothrow @nogc
{
    if(!logPath[0])
    {
        return;
    }
    auto fileHandle = CreateFileW(logPath.ptr, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if(fileHandle == INVALID_HANDLE_VALUE)
    {
        return;
    }
    int byteCount = WideCharToMultiByte(65001, 0, text, -1, logBytes.ptr, cast(int)logBytes.length, null, null);
    DWORD written;
    if(byteCount > 1)
    {
        WriteFile(fileHandle, logBytes.ptr, byteCount - 1, &written, null);
    }
    WriteFile(fileHandle, "\r\n".ptr, 2, &written, null);
    CloseHandle(fileHandle);
}
