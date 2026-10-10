// 验证 Firefox 专用环境变量并恢复测试进程的原始环境。
module ProfileEnvironmentTests;

import FirefoxPortable;
import core.sys.windows.windows;
import std.exception: enforce;

// 保存变量的精确存在状态和内容，不将缺失变量还原为空字符串。
struct EnvironmentVariableSnapshot
{
    wstring name;
    wchar[] value;
    bool present;

    // 读取当前测试进程环境，不读取或修改系统永久环境。
    this(wstring variableName)
    {
        name = variableName;
        DWORD length = GetEnvironmentVariableW(name.ptr, null, 0);
        if(!length)
        {
            present = GetLastError() != ERROR_ENVVAR_NOT_FOUND;
            value = [cast(wchar)0];
        }
        else
        {
            present = true;
            value.length = length;
            enforce(GetEnvironmentVariableW(name.ptr, value.ptr, length) < length);
        }
    }

    // 单测结束后恢复自己的进程环境，避免影响随后用例。
    void restore()
    {
        enforce(SetEnvironmentVariableW(name.ptr, present ? value.ptr : null) != 0);
    }
}

// 通用环境不变是明确契约；仅 Firefox 的四个专用变量更新。
unittest
{
    auto names = ["APPDATA"w, "LOCALAPPDATA"w, "ProgramData"w, "XRE_PROFILE_PATH"w, "XRE_PROFILE_LOCAL_PATH"w, "MOZ_APP_DATA"w, "MOZ_LOCAL_APP_DATA"w];
    EnvironmentVariableSnapshot[] saved;
    foreach(name; names)
    {
        saved ~= EnvironmentVariableSnapshot(name);
    }

    scope(exit)
    {
        foreach(ref value; saved)
        {
            value.restore();
        }
    }

    enforce(putText(profilePath.ptr, "C:\\便携测试根"w.ptr));
    enforce(prepareAuxiliaryPaths());

    foreach(name; names[0 .. 3])
    {
        enforce(SetEnvironmentVariableW(name.ptr, "C:\\系统目录哨兵"w.ptr) != 0);
    }

    enforce(setProfileEnvironment());
    wchar[32768] result = 0;

    foreach(name; names[0 .. 3])
    {
        enforce(GetEnvironmentVariableW(name.ptr, result.ptr, result.length) > 0);
        enforce(lstrcmpiW(result.ptr, "C:\\系统目录哨兵"w.ptr) == 0, "不得改写通用环境变量");
    }

    const(wchar)*[4] expected = [profilePath.ptr, cachePath.ptr, metadataPath.ptr, cachePath.ptr];

    foreach(index, name; names[3 .. $])
    {
        enforce(GetEnvironmentVariableW(name.ptr, result.ptr, result.length) > 0);
        enforce(lstrcmpiW(result.ptr, expected[index]) == 0);
    }

    // 同样不能把原先不存在的通用变量创建出来。
    foreach(name; names[0 .. 3])
    {
        enforce(SetEnvironmentVariableW(name.ptr, null) != 0);
    }

    enforce(setProfileEnvironment());

    foreach(name; names[0 .. 3])
    {
        enforce(GetEnvironmentVariableW(name.ptr, result.ptr, result.length) == 0);
        enforce(GetLastError() == ERROR_ENVVAR_NOT_FOUND);
    }
}
