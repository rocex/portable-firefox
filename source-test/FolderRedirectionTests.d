// 在独立子进程验证目录重定向、IAT 修补和并发页面权限。
module FolderRedirectionTests;

import FolderRedirection;
import core.sys.windows.windows;
// 使用 KnownFolder GUID 布局声明系统 Shell 接口，验证普通 IAT 重定向。
extern (Windows) HRESULT SHGetKnownFolderPath(const(KnownFolderId)* id, DWORD flags, HANDLE token, wchar** output) nothrow @nogc;

pragma(lib, "shell32");
import std.exception: enforce;
import std.file: mkdir, mkdirRecurse, rmdirRecurse, tempDir, exists;
import std.process: execute;

version(processChild)
{
}
else
{
    import ConsoleEncodingTests: write = consoleWrite;
}
import std.path: absolutePath, buildPath;
import std.conv: to;
import std.utf: toUTF16;
import core.thread: Thread;
import core.atomic: atomicStore, atomicLoad;

// 统一 dub test 中自动编译并启动独立 IAT 子测试，避免修改父测试进程的导入表。
unittest
{
    version(processChild)
    {
        string testPath = buildPath(tempDir(), "portable-process-tests-" ~ GetCurrentProcessId().to!string ~ "-" ~ GetTickCount().to!string);
        enforce(!exists(testPath), "临时测试目录已存在");
        mkdir(testPath);
        scope(exit)
        {
            rmdirRecurse(testPath);
        }
        testFolders(testPath);
    }
    else
    {
        mkdirRecurse(buildPath("build", "tests"));
        version(Win64)
        {
            enum architecture = "64";
        }
        else
        {
            enum architecture = "32";
        }
        string executable = absolutePath(buildPath("build", "tests", "iat-child-" ~ architecture ~ ".exe"));
        auto compilation = execute([
            "ldc2", "-m" ~ architecture, "-unittest", "-main", "-d-version=processChild", "-Isource", "source/FolderRedirection.d", "source/RuntimeMemory.d",
            "source-test/FolderRedirectionTests.d", "-of=" ~ executable
        ]);
        write(compilation.output);
        enforce(compilation.status == 0, "IAT 子测试编译失败，需要 PATH 中有完整 LDC2");
        auto result = execute([executable]);
        write(result.output);
        enforce(result.status == 0, "IAT 子测试失败，退出码：" ~ result.status.to!string);
    }
}

alias ComTaskFreeFunction = extern (Windows) void function(void*) nothrow @nogc;

// 取当前目录接口的结果，用于确认测试不改变系统 API 或用户目录。
wstring knownResult(GetKnownFolderPathFunction functionPointer, const(KnownFolderId)* id, ComTaskFreeFunction release)
{
    wchar* result;
    enforce(functionPointer(id, 0, null, &result) >= 0 && result !is null);
    size_t length;
    while(result[length])
    {
        ++length;
    }

    auto text = result[0 .. length].idup;
    release(result);
    return text;
}

// 用自有 PE 布局检查普通导入边界，并确认不扫描延迟导入目录。
void testImportTables()
{
    auto memory = cast(ubyte*)VirtualAlloc(null, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    enforce(memory !is null);
    scope(exit)
    {
        VirtualFree(memory, 0, MEM_RELEASE);
    }
    *cast(ushort*)memory = 0x5a4d;
    *cast(uint*)(memory + 0x3c) = 0x80;
    *cast(uint*)(memory + 0x80) = 0x4550;
    auto optional = memory + 0x98;
    *cast(uint*)(optional + 56) = 4096;
    version(Win64)
    {
        enum directoryOffset = 112;
    }
    else
    {
        enum directoryOffset = 96;
    }
    *cast(uint*)(optional + directoryOffset + 8) = 0x200;
    *cast(uint*)(optional + directoryOffset + 12) = 40;
    *cast(uint*)(memory + 0x200 + 12) = 0x400;
    *cast(uint*)(memory + 0x200 + 16) = 0x300;
    *cast(void**)(memory + 0x300) = cast(void*)originalKnownPath;
    *cast(uint*)(optional + directoryOffset + 13 * 8) = 0x500;
    *cast(uint*)(optional + directoryOffset + 13 * 8 + 4) = 64;
    *cast(uint*)(memory + 0x500) = 1;
    *cast(uint*)(memory + 0x504) = 0x400;
    *cast(uint*)(memory + 0x50c) = 0x600;
    *cast(void**)(memory + 0x600) = cast(void*)originalKnownPath;
    enforce(patchModule(cast(HMODULE)memory));
    enforce(*cast(void**)(memory + 0x300) == cast(void*)&redirectedKnownPath);
    enforce(*cast(void**)(memory + 0x600) == cast(void*)originalKnownPath, "不修补已解析的延迟 IAT");
    *cast(uint*)(memory + 0x50c) = 4096;
    enforce(patchModule(cast(HMODULE)memory), "不遍历延迟导入表");
    *cast(uint*)(memory + 0x200 + 16) = 4096;
    enforce(!patchModule(cast(HMODULE)memory), "应拒绝越界普通导入表");
    *cast(uint*)(memory + 0x200 + 16) = 0x300;
    *cast(uint*)(optional + directoryOffset + 12) = 20;
    enforce(!patchModule(cast(HMODULE)memory), "普通导入描述符必须包含终止项");
}

// 两个相邻 IAT 槽共享只读页，多线程修补必须保持一致并恢复原始权限。
void testConcurrentPatching()
{
    auto memory = cast(void**)VirtualAlloc(null, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    enforce(memory !is null);
    scope(exit)
    {
        VirtualFree(memory, 0, MEM_RELEASE);
    }
    memory[0] = cast(void*)originalKnownPath;
    memory[1] = replacements[1].original;
    DWORD oldProtection;
    enforce(VirtualProtect(memory, 4096, PAGE_READONLY, &oldProtection) != 0);
    shared bool failed;
    auto first = new Thread({
        foreach(attempt; 0 .. 500)
        {
            if(!patchSlot(memory))
            {
                atomicStore(failed, true);
            }
        }
    });
    auto second = new Thread({
        foreach(attempt; 0 .. 500)
        {
            if(!patchSlot(memory + 1))
            {
                atomicStore(failed, true);
            }
        }
    });

    first.start();
    second.start();
    first.join();
    second.join();
    enforce(!atomicLoad(failed));
    enforce(memory[0] == cast(void*)&redirectedKnownPath && memory[1] == cast(void*)&redirectedGetProcAddress);
    MEMORY_BASIC_INFORMATION information;
    enforce(VirtualQuery(memory, &information, information.sizeof) != 0);
    enforce(information.Protect == PAGE_READONLY, "并发修补后必须恢复原始页面权限");
}

// 模拟 COM 分配失败，验证失败时清空输出指针。
extern (Windows) void* failAllocation(size_t size) nothrow @nogc
{
    return null;
}

// 在自有测试进程修补 IAT，不加载 DLL 产物、不修改系统函数机器码。
void testFolders(string temporaryRoot)
{
    string roaming = buildPath(temporaryRoot, "Roaming");
    string local = buildPath(temporaryRoot, "AppData");
    string common = buildPath(temporaryRoot, "ProgramData");
    auto roamingWide = toUTF16(roaming ~ "\0");
    auto localWide = toUTF16(local ~ "\0");
    auto commonWide = toUTF16(common ~ "\0");
    // null 允许显式修补测试 EXE，而不会把测试进程识别为 Firefox。
    enforce(initializeFolderHooks(null, roamingWide.ptr, localWide.ptr, commonWide.ptr));
    auto release = cast(ComTaskFreeFunction)GetProcAddress(comModule, "CoTaskMemFree".ptr);
    enforce(release !is null);
    auto systemRoaming = knownResult(originalKnownPath, &roamingId, release);
    enforce(folderIndex(&roamingId) == folderRoaming);
    enforce(folderIndex(&localId) == folderLocal);
    enforce(folderIndex(&commonId) == folderCommon);
    enforce(folderIndex(null) == -1);
    enforce(knownResult(&redirectedKnownPath, &roamingId, release) == roamingWide[0 .. $ - 1]);
    enforce(knownResult(&redirectedKnownPath, &localId, release) == localWide[0 .. $ - 1]);
    enforce(knownResult(&redirectedKnownPath, &commonId, release) == commonWide[0 .. $ - 1]);
    enforce(redirectedKnownPath(&roamingId, 0, null, null) == cast(HRESULT)0x80070057);
    {
        auto allocate = taskAllocate;
        scope(exit)
        {
            taskAllocate = allocate;
        }
        taskAllocate = &failAllocation;
        wchar* failedOutput = cast(wchar*)1;
        enforce(redirectedKnownPath(&localId, 0, null, &failedOutput) == cast(HRESULT)0x8007000e);
        enforce(failedOutput is null);
    }
    KnownFolderId unknown;
    enforce(folderIndex(&unknown) == -1);
    wchar* originalOutput, redirectedOutput;
    enforce(originalKnownPath(&unknown, 0, null, &originalOutput) == redirectedKnownPath(&unknown, 0, null, &redirectedOutput));
    release(originalOutput);
    release(redirectedOutput);
    // Desktop 是有效但未重定向的 ID，验证成功透传及 COM 释放契约。
    immutable KnownFolderId desktopId = KnownFolderId(0xb4bfcc3a, 0xdb2c, 0x424c, [0xb0, 0x29, 0x7f, 0xe9, 0x9a, 0x87, 0xc6, 0x41]);
    enforce(knownResult(&redirectedKnownPath, &desktopId, release) == knownResult(originalKnownPath, &desktopId, release));
    // 即使指定 CREATE，三个目标目录仍由浏览器管理，查询层不创建。
    foreach(id; [&roamingId, &localId, &commonId])
    {
        wchar* requested;
        enforce(redirectedKnownPath(id, 0x8000, null, &requested) == 0 && requested !is null);
        release(requested);
    }
    enforce(!exists(roaming) && !exists(local) && !exists(common), "目录查询不得创建数据目录");
    enforce(knownResult(originalKnownPath, &roamingId, release) == systemRoaming, "原始系统接口不应受到影响");
    SetLastError(1234);
    enforce(finishModuleLoad(null) is null && GetLastError() == 1234);
    // 数据文件映射不需要已安装 Hook，也不得触发退出或修改错误码。
    hooksReady = false;
    SetLastError(4321);
    enforce(finishModuleLoad(cast(HMODULE)1, 0x2) == cast(HMODULE)1 && GetLastError() == 4321);
    hooksReady = true;
    SetLastError(5678);
    enforce(finishModuleLoad(shellModule) == shellModule && GetLastError() == 5678);
    testConcurrentPatching();
    testImportTables();
    // 真实普通 IAT 覆盖静态 Shell 调用及现代延迟 helper 使用的动态取址入口。
    enforce(patchModule(GetModuleHandleW(null)));
    auto dynamicKnown = cast(GetKnownFolderPathFunction)GetProcAddress(shellModule, "SHGetKnownFolderPath".ptr);
    enforce(cast(void*)dynamicKnown == cast(void*)&redirectedKnownPath);
    enforce(knownResult(dynamicKnown, &commonId, release) == commonWide[0 .. $ - 1]);
    enforce(knownResult(&SHGetKnownFolderPath, &localId, release) == localWide[0 .. $ - 1], "静态 Shell 导入应被重定向");
    enforce(cast(void*)GetProcAddress(comModule, "CoTaskMemFree".ptr) == cast(void*)release, "非目标函数必须透传");
    enforce(patchModule(GetModuleHandleW(null)), "重复修补应幂等");
    auto loadedShell = LoadLibraryW("shell32.dll"w.ptr);
    enforce(loadedShell !is null);
    FreeLibrary(loadedShell);
}

