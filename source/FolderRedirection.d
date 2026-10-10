// Firefox 核心模块的目录路径替换与进程内 IAT 修补；不创建用户数据目录。
module FolderRedirection;

import core.sys.windows.windows;
import core.atomic: atomicExchange;

// 只重定向当前进程中的三个数据目录，不修改系统 Shell 配置。
enum folderRoaming = 0;
enum folderLocal = 1;
enum folderCommon = 2;
enum folderCapacity = 32_768;

// Shell 返回错误、非执行映射标志及 PE 描述符布局。
private enum invalidArgument = cast(HRESULT)0x80070057;
private enum outOfMemory = cast(HRESULT)0x8007000e;
private enum nonExecutableLoadFlags = 0x63;
private enum portableFailureExitCode = 1610;
private enum importDescriptorSize = 20;

__gshared wchar[folderCapacity][3] folderPaths = 0;
__gshared LONG patchLock;
__gshared HMODULE shellModule, comModule, ownerModule;
__gshared bool hooksReady;

// 自有 GUID 定义避免依赖运行时初始化的 KnownFolder 常量。
struct KnownFolderId
{
    uint first;
    ushort second, third;
    ubyte[8] last;
}

immutable KnownFolderId roamingId = KnownFolderId(0x3eb685db, 0x65f9, 0x4cf6, [0xa0, 0x3a, 0xe3, 0xef, 0x65, 0x72, 0x9f, 0x3d]);
immutable KnownFolderId localId = KnownFolderId(0xf1b32785, 0x6fba, 0x4fcf, [0x9d, 0x55, 0x7b, 0x8e, 0x7f, 0x15, 0x70, 0x91]);
immutable KnownFolderId commonId = KnownFolderId(0x62ab5d82, 0xfdc1, 0x4dc3, [0xa9, 0xdd, 0x07, 0x0d, 0x1d, 0x49, 0x5d, 0x97]);

alias GetKnownFolderPathFunction = extern (Windows) HRESULT function(const(KnownFolderId)*, DWORD, HANDLE, wchar**) nothrow @nogc;
alias ComTaskAllocateFunction = extern (Windows) void* function(size_t) nothrow @nogc;
__gshared GetKnownFolderPathFunction originalKnownPath;
__gshared ComTaskAllocateFunction taskAllocate;

// 固定长度比较 KnownFolder GUID，不使用 CRT 内存函数。
int folderIndex(const(KnownFolderId)* id) nothrow @nogc
{
    if(!id)
    {
        return -1;
    }
    const(KnownFolderId)*[3] identifiers = [&roamingId, &localId, &commonId];
    foreach(index; 0 .. 3)
    {
        auto left = cast(const(ubyte)*)id;
        auto right = cast(const(ubyte)*)identifiers[index];
        bool equal = true;
        foreach(position; 0 .. 16)
        {
            if(left[position] != right[position])
            {
                equal = false;
            }
        }
        if(equal)
        {
            return cast(int)index;
        }
    }
    return -1;
}

// 将完整路径写入调用者缓冲区，容量包含终止符。
bool copyFolder(wchar* destination, size_t capacity, const(wchar)* source) nothrow @nogc
{
    if(!destination || !source || !capacity)
    {
        return false;
    }
    size_t length;
    while(source[length])
    {
        ++length;
    }
    if(length >= capacity)
    {
        return false;
    }
    foreach(index; 0 .. length + 1)
    {
        destination[index] = source[index];
    }
    return true;
}

// 路径由 COM 分配，调用者可以按原 API 契约使用 CoTaskMemFree。
extern (Windows) HRESULT redirectedKnownPath(const(KnownFolderId)* id, DWORD flags, HANDLE token, wchar** output) nothrow @nogc
{
    int index = folderIndex(id);
    if(index < 0)
    {
        return originalKnownPath(id, flags, token, output);
    }
    if(!output)
    {
        return invalidArgument;
    }
    *output = null;
    size_t length;
    while(folderPaths[index][length])
    {
        ++length;
    }
    auto result = cast(wchar*)taskAllocate((length + 1) * wchar.sizeof);
    if(!result)
    {
        return outOfMemory;
    }
    copyFolder(result, length + 1, folderPaths[index].ptr);
    *output = result;
    return 0;
}

// 每项记录原函数和替代函数；以地址匹配避免误拦截同名第三方接口。
struct FunctionRedirect
{
    void* original;
    void* replacement;
}

__gshared FunctionRedirect[6] replacements;
alias GetProcAddressFunction = extern (Windows) FARPROC function(HMODULE, LPCSTR) nothrow @nogc;
alias LoadLibraryWideFunction = extern (Windows) HMODULE function(LPCWSTR) nothrow @nogc;
alias LoadLibraryAnsiFunction = extern (Windows) HMODULE function(LPCSTR) nothrow @nogc;
alias LoadLibraryExWideFunction = extern (Windows) HMODULE function(LPCWSTR, HANDLE, DWORD) nothrow @nogc;
alias LoadLibraryExAnsiFunction = extern (Windows) HMODULE function(LPCSTR, HANDLE, DWORD) nothrow @nogc;

// 仅为已注册函数返回替代地址；序号查询也先由系统解析。
void* replacementFor(void* address) nothrow @nogc
{
    if(address)
    {
        foreach(ref item; replacements)
        {
            if(item.original == address)
            {
                return item.replacement;
            }
        }
    }
    return address;
}

// 动态取址同时覆盖延迟加载 helper 对 Shell 和加载器接口的解析。
extern (Windows) FARPROC redirectedGetProcAddress(HMODULE moduleHandle, LPCSTR name) nothrow @nogc
{
    auto address = (cast(GetProcAddressFunction)replacements[1].original)(moduleHandle, name);
    return cast(FARPROC)replacementFor(cast(void*)address);
}

// 四个加载入口共用收尾，保持原函数返回值、错误码及数据映射不修补的约定。
HMODULE finishModuleLoad(HMODULE result, DWORD flags = 0) nothrow @nogc
{
    DWORD errorCode = GetLastError();
    if(result && !(flags & nonExecutableLoadFlags) && !patchBrowserModules())
    {
        TerminateProcess(GetCurrentProcess(), portableFailureExitCode);
    }
    SetLastError(errorCode);
    return result;
}

// 加载完成后修补浏览器新模块；不在 DLL 通知的未链接阶段修改 IAT。
extern (Windows) HMODULE redirectedLoadLibraryW(LPCWSTR name) nothrow @nogc
{
    return finishModuleLoad((cast(LoadLibraryWideFunction)replacements[2].original)(name));
}

// ANSI 加载入口与宽字符入口采用相同策略。
extern (Windows) HMODULE redirectedLoadLibraryA(LPCSTR name) nothrow @nogc
{
    return finishModuleLoad((cast(LoadLibraryAnsiFunction)replacements[3].original)(name));
}

// 数据文件映射不执行导入修补，普通代码模块才参与后续扫描。
extern (Windows) HMODULE redirectedLoadLibraryExW(LPCWSTR name, HANDLE fileHandle, DWORD flags) nothrow @nogc
{
    return finishModuleLoad((cast(LoadLibraryExWideFunction)replacements[4].original)(name, fileHandle, flags), flags);
}

// ANSI 扩展加载入口保留系统返回值和错误码。
extern (Windows) HMODULE redirectedLoadLibraryExA(LPCSTR name, HANDLE fileHandle, DWORD flags) nothrow @nogc
{
    return finishModuleLoad((cast(LoadLibraryExAnsiFunction)replacements[5].original)(name, fileHandle, flags), flags);
}

// 原子替换对齐 IAT 槽，完成后立即恢复页面权限，不生成可执行跳板。
bool patchSlot(void** slot) nothrow @nogc
{
    // 只在不获取加载器锁的短页面写入期间串行化，防止恢复错误的旧权限。
    while(atomicExchange(&patchLock, 1))
    {
        Sleep(0);
    }
    scope(exit)
    {
        atomicExchange(&patchLock, 0);
    }
    auto current = *slot;
    auto replacement = replacementFor(current);
    if(current == replacement)
    {
        return true;
    }
    DWORD oldProtection, unused;
    if(!VirtualProtect(slot, (void*).sizeof, PAGE_READWRITE, &oldProtection))
    {
        return false;
    }
    atomicExchange(slot, replacement);
    return VirtualProtect(slot, (void*).sizeof, oldProtection, &unused) != 0;
}

// 在已加载 PE 映像内检查地址范围，防止损坏的导入表越界。
bool withinImage(size_t offset, size_t count, size_t imageSize) nothrow @nogc
{
    return offset <= imageSize && count <= imageSize - offset;
}

// 修补一张已解析的函数指针表，并要求终止项位于映像范围内。
bool patchThunks(ubyte* bytes, uint thunkRva, uint imageSize) nothrow @nogc
{
    if(!thunkRva || thunkRva % (void*).sizeof)
    {
        return false;
    }
    while(withinImage(thunkRva, (void*).sizeof, imageSize))
    {
        auto slot = cast(void**)(bytes + thunkRva);
        if(!*slot)
        {
            return true;
        }
        if(!patchSlot(slot))
        {
            return false;
        }
        thunkRva += (void*).sizeof;
    }
    return false;
}

// 遍历普通导入描述符，要求零终止项位于数据目录声明的范围内。
pragma(inline, true) private bool patchImports(ubyte* bytes, uint imageSize, uint importRva, uint importSize) nothrow @nogc
{
    if(!importRva)
    {
        return true;
    }
    if(!withinImage(importRva, importSize, imageSize))
    {
        return false;
    }
    bool terminated;
    for(size_t offset = importRva; withinImage(offset, importDescriptorSize, cast(size_t)importRva + importSize); offset += importDescriptorSize)
    {
        uint nameRva = *cast(uint*)(bytes + offset + 12);
        if(!nameRva)
        {
            terminated = true;
            break;
        }
        if(!patchThunks(bytes, *cast(uint*)(bytes + offset + 16), imageSize))
        {
            return false;
        }
    }
    return terminated;
}

// 仅修补普通 IAT；现代标准延迟 helper 经已包装的 GetProcAddress 解析。
// 不遍历延迟表，不支持旧 VA 描述符、已缓存的延迟地址或绕过该入口的自定义解析器。
bool patchModule(HMODULE moduleHandle) nothrow @nogc
{
    if(!moduleHandle || moduleHandle == ownerModule)
    {
        return true;
    }
    auto bytes = cast(ubyte*)moduleHandle;
    if(*cast(ushort*)bytes != 0x5a4d)
    {
        return false;
    }
    uint peOffset = *cast(uint*)(bytes + 0x3c);
    if(peOffset > 0x100000 || *cast(uint*)(bytes + peOffset) != 0x4550)
    {
        return false;
    }
    auto optional = bytes + peOffset + 24;
    version(Win64)
    {
        enum directoryOffset = 112;
    }
    else
    {
        enum directoryOffset = 96;
    }
    uint imageSize = *cast(uint*)(optional + 56);
    uint importRva = *cast(uint*)(optional + directoryOffset + 8);
    uint importSize = *cast(uint*)(optional + directoryOffset + 12);
    return patchImports(bytes, imageSize, importRva, importSize);
}

// 获取临时模块引用后修补，避免并发卸载；尚未加载的模块留给加载包装处理。
bool patchNamedModule(const(wchar)* name) nothrow @nogc
{
    HMODULE heldModule;
    if(!GetModuleHandleExW(0, name, &heldModule))
    {
        return GetLastError() == ERROR_MOD_NOT_FOUND;
    }
    bool result = patchModule(heldModule);
    FreeLibrary(heldModule);
    return result;
}

// 覆盖范围只有三个已知模块，直接按名称获取，无需创建并枚举整个进程快照。
bool patchBrowserModules() nothrow @nogc
{
    return hooksReady && patchNamedModule("firefox.exe"w.ptr) && patchNamedModule("mozglue.dll"w.ptr) && patchNamedModule("xul.dll"w.ptr);
}

// 只从系统目录加载 Shell/COM，避免应用目录中同名库劫持。
bool initializeFolderHooks(HMODULE self, const(wchar)* roaming, const(wchar)* local, const(wchar)* common) nothrow @nogc
{
    if(!copyFolder(folderPaths[0].ptr, folderCapacity, roaming) || !copyFolder(folderPaths[1].ptr, folderCapacity, local) || !copyFolder(folderPaths[2].ptr,
            folderCapacity, common))
    {
        return false;
    }
    ownerModule = self;
    shellModule = LoadLibraryExW("shell32.dll"w.ptr, null, 0x800);
    comModule = LoadLibraryExW("ole32.dll"w.ptr, null, 0x800);
    if(!shellModule || !comModule)
    {
        return false;
    }
    originalKnownPath = cast(GetKnownFolderPathFunction)GetProcAddress(shellModule, "SHGetKnownFolderPath".ptr);
    taskAllocate = cast(ComTaskAllocateFunction)GetProcAddress(comModule, "CoTaskMemAlloc".ptr);
    if(!originalKnownPath || !taskAllocate)
    {
        return false;
    }
    replacements[0] = FunctionRedirect(cast(void*)originalKnownPath, cast(void*)&redirectedKnownPath);
    auto kernelModule = GetModuleHandleW("kernel32.dll"w.ptr);
    if(!kernelModule)
    {
        return false;
    }
    replacements[1] = FunctionRedirect(cast(void*)GetProcAddress(kernelModule, "GetProcAddress".ptr), cast(void*)&redirectedGetProcAddress);
    replacements[2] = FunctionRedirect(cast(void*)GetProcAddress(kernelModule, "LoadLibraryW".ptr), cast(void*)&redirectedLoadLibraryW);
    replacements[3] = FunctionRedirect(cast(void*)GetProcAddress(kernelModule, "LoadLibraryA".ptr), cast(void*)&redirectedLoadLibraryA);
    replacements[4] = FunctionRedirect(cast(void*)GetProcAddress(kernelModule, "LoadLibraryExW".ptr), cast(void*)&redirectedLoadLibraryExW);
    replacements[5] = FunctionRedirect(cast(void*)GetProcAddress(kernelModule, "LoadLibraryExA".ptr), cast(void*)&redirectedLoadLibraryExA);
    foreach(ref item; replacements)
    {
        if(!item.original || !item.replacement)
        {
            return false;
        }
    }
    hooksReady = true;
    return true;
}
