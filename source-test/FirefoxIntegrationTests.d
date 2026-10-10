// 通过隔离 Firefox 副本验证页面、JavaScript 请求和便携目录。
module FirefoxIntegrationTests;

import core.sys.windows.windows;
import core.thread: Thread;
import core.time: msecs;
import core.atomic: atomicLoad, atomicStore, atomicOp;
import std.socket;
import std.file;
import std.path;
import std.string: startsWith, indexOf, toLower;
import std.conv: to;
import std.utf: toUTF16;
import std.exception: enforce;
import ConsoleEncodingTests: writeln = consoleLine;
import std.process: environment;
import std.digest.sha: sha256Of;
import std.digest: toHexString;

// Windows 作业契约和测试等待上限；部分 D Windows 头未声明这些枚举值。
private enum jobKillOnClose = 0x2000;
private enum jobExtendedLimitInformation = cast(JOBOBJECTINFOCLASS)9;
private enum browserTimeoutMilliseconds = 60_000;

// 独立回环 HTTP 服务：浏览器必须执行 JavaScript HTTP 请求才会请求 proof。
class LoopbackHttpTestServer
{
    TcpSocket listener;
    Thread worker;
    shared bool stopping;
    shared uint proofs;
    ushort port;

    this()
    {
        listener = new TcpSocket;
        listener.bind(new InternetAddress("127.0.0.1", 0));
        port = cast(ushort)(cast(InternetAddress)listener.localAddress).port;
        listener.listen(8);
        listener.blocking = false;
        worker = new Thread(&serve);
        worker.start();
    }

    // 单请求一连接，响应包含明确长度；不访问外部服务器。
    void serve()
    {
        while(!atomicLoad(stopping))
        {
            Socket client;
            try
            {
                client = listener.accept();
            }
            catch(SocketException)
            {
                Thread.sleep(20.msecs);
                continue;
            }

            if(client is null || !client.isAlive)
            {
                Thread.sleep(20.msecs);
                continue;
            }

            scope(exit)
            {
                client.close();
            }
            client.blocking = true;
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 2000);
            char[4096] request;
            auto count = client.receive(request);
            if(count <= 0)
            {
                continue;
            }
            string line = cast(string)request[0 .. count];
            string body;
            string mime = "text/html; charset=utf-8";
            if(line.startsWith("GET /api "))
            {
                body = "network-ok";
                mime = "text/plain";
            }
            else if(line.startsWith("GET /proof "))
            {
                atomicOp!"+="(proofs, 1);
                body = "ok";
            }
            else
            {
                body = `<!doctype html><meta charset="utf-8"><title>Portable test</title>
<style>body{background:#dff4e5;color:#124825;font:32px sans-serif;padding:50px}</style>
<h1 id="result">页面已加载，等待网络请求</h1><p>Firefox portable isolated test</p>
<script>try {let r=new XMLHttpRequest();r.open('GET','/api',false);r.send();
if(r.status!==200||r.responseText!=='network-ok')throw Error('HTTP '+r.status);
document.querySelector('#result').textContent='网页、JavaScript 与 HTTP 请求正常';
r.open('GET','/proof',false);r.send();}catch(e){document.querySelector('#result').textContent='失败：'+e}</script>`;
            }

            string response = "HTTP/1.1 200 OK\r\nContent-Type: " ~ mime ~ "\r\nContent-Length: " ~ body.length.to!string ~ "\r\nConnection: close\r\n\r\n" ~ body;
            size_t sent;
            while(sent < response.length)
            {
                auto amount = client.send(response[sent .. $]);
                if(amount <= 0)
                {
                    break;
                }
                sent += amount;
            }
        }
    }

    // 停止仅属于测试进程的服务线程。
    void close()
    {
        atomicStore(stopping, true);
        worker.join();
        listener.close();
    }
}

// 复制程序文件而非用户数据；源目录不写入、不运行现有代理。
void copyBrowser(string source, string destination)
{
    mkdir(destination);
    foreach(entry; dirEntries(source, SpanMode.shallow))
    {
        string name = baseName(entry.name);
        if(name.toLower == "data" || name == "profile" || name == "version.dll" || name == "portable.ini" || name == "portable.log")
        {
            continue;
        }
        string target = buildPath(destination, name);
        if(entry.isDir)
        {
            copyBrowser(entry.name, target);
        }
        else
        {
            copy(entry.name, target);
        }
    }
}

// Windows Job 仅管理新启动的测试树；失败或超时不杀用户已运行的 Firefox。
DWORD launchBrowser(string executable, string arguments, string workingDirectory)
{
    HANDLE job = CreateJobObjectW(null, null);
    enforce(job !is null, "无法创建隔离进程作业");
    scope(exit)
    {
        CloseHandle(job);
    }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    limits.BasicLimitInformation.LimitFlags = jobKillOnClose;
    enforce(SetInformationJobObject(job, jobExtendedLimitInformation, &limits, limits.sizeof) != 0);
    STARTUPINFOW startup;
    startup.cb = startup.sizeof;
    SECURITY_ATTRIBUTES attributes;
    attributes.nLength = attributes.sizeof;
    attributes.bInheritHandle = TRUE;
    auto outputPath = toUTF16(buildPath(workingDirectory, "browser-output.log") ~ "\0");
    auto output = CreateFileW(outputPath.ptr, GENERIC_WRITE, FILE_SHARE_READ, &attributes, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    enforce(output != INVALID_HANDLE_VALUE, "无法创建浏览器诊断日志");
    scope(exit)
    {
        CloseHandle(output);
    }
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = output;
    startup.hStdError = output;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    PROCESS_INFORMATION process;
    auto command = toUTF16('"' ~ executable ~ "\" " ~ arguments ~ "\0").dup;
    auto directory = toUTF16(workingDirectory ~ "\0");
    enforce(CreateProcessW(null, command.ptr, null, null, TRUE, CREATE_SUSPENDED, null, directory.ptr, &startup, &process) != 0,
        "Firefox 创建失败：" ~ GetLastError().to!string);
    scope(exit)
    {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
    if(!AssignProcessToJobObject(job, process.hProcess))
    {
        TerminateProcess(process.hProcess, 1);
        throw new Exception("无法将测试 Firefox 加入独立作业");
    }

    ResumeThread(process.hThread);
    DWORD waitResult = WaitForSingleObject(process.hProcess, browserTimeoutMilliseconds);
    if(waitResult != WAIT_OBJECT_0)
    {
        TerminateJobObject(job, 1);
        write(buildPath(workingDirectory, "timeout.txt"), "Firefox 60 秒未退出，测试已终止其独立进程树。\n");
        throw new Exception("Firefox 页面测试超时，已清理本次测试进程树");
    }

    DWORD exitCode;
    enforce(GetExitCodeProcess(process.hProcess, &exitCode) != 0);
    return exitCode;
}

// 统一测试中的浏览器验证使用独立程序副本和配置，不使用用户 profile 或关闭沙箱。
unittest
{
    string source = absolutePath(environment.get("PORTABLE_FIREFOX_SOURCE", "firefox"));
    string dll = absolutePath(environment.get("PORTABLE_TEST_DLL", "dist/x86_64/version.dll"));
    enforce(exists(buildPath(source, "firefox.exe")), "缺少测试用 Firefox 程序目录");
    enforce(exists(dll), "需要先构建与测试 Firefox 位数一致的 DLL");
    auto dllHash = sha256Of(cast(ubyte[])read(dll)).toHexString.idup.toLower;
    enforce(dllHash != "d2d9242307b199ecc7fd1981ac40862b9d84276c2d6a5364ab8400d98138aefc", "禁止运行原始参考样本");
    string root = absolutePath(buildPath("build", "browser-" ~ GetCurrentProcessId().to!string ~ "-" ~ GetTickCount().to!string));
    mkdirRecurse(root);
    string application = buildPath(root, "App");
    copyBrowser(source, application);
    copy(dll, buildPath(application, "version.dll"));
    write(buildPath(application, "portable.ini"), "PortableDataPath=../Data\n");
    // 不预建 Data，验证仅路径替换即可支持 Firefox 首次启动。
    auto server = new LoopbackHttpTestServer;
    scope(exit)
    {
        server.close();
    }
    string screenshot = buildPath(root, "page.png");
    // 命令行 profile 仅作隔离保险，代理未加载时也不会使用用户现有配置。
    string arguments = "-no-remote -headless -profile \"" ~ buildPath(root, "Data") ~ "\"";

    arguments ~= " --window-size 1000,650 --screenshot \"" ~ screenshot ~ "\" http://127.0.0.1:" ~ server.port.to!string ~ "/";
    writeln("隔离浏览器测试目录：", root);
    DWORD exitCode = launchBrowser(buildPath(application, "firefox.exe"), arguments, root);
    uint proofCount = atomicLoad(server.proofs);
    write(buildPath(root, "result.txt"), "退出码=" ~ exitCode.to!string ~ "\nJavaScript网络验证次数=" ~ proofCount.to!string ~ "\n");
    enforce(exitCode == 0, "Firefox 退出码：" ~ exitCode.to!string);
    enforce(proofCount > 0, "Firefox 没有完成 JavaScript HTTP 请求，不能认定网页恢复");
    enforce(exists(screenshot) && getSize(screenshot) > 1000, "未生成有效页面截图");
    string log = readText(buildPath(application, "portable.log"));
    enforce(log.indexOf(buildPath(root, "Data")) >= 0, "未确认代理应用了隔离配置");
    string[] cacheFiles;
    foreach(entry; dirEntries(buildPath(root, "Data"), SpanMode.depth))
    {
        string relative = relativePath(entry.name, buildPath(root, "Data"));
        string normalized = relative.toLower;
        if(normalized.indexOf("microsoft\\windows\\caches") >= 0 || normalized.indexOf("microsoft/windows/caches") >= 0)
        {
            cacheFiles ~= relative;
        }
    }

    string localData = buildPath(root, "Data", "AppData");
    enforce(exists(buildPath(localData, "cache2")), "网页缓存应直接生成在 AppData/cache2");
    enforce(!exists(buildPath(localData, "LocalAppData")), "新配置不应生成多余的 LocalAppData 层");
    string report = "Microsoft/Windows/Caches 条目数=" ~ cacheFiles.length.to!string ~ "\n";
    report ~= "本地配置／缓存根=" ~ localData ~ "\n";
    foreach(name; ["RoamingAppData", "LocalAppData", "ProgramData", "State"])
    {
        report ~= name ~ "目录存在=" ~ exists(buildPath(root, "Data", "AppData", name)).to!string ~ "\n";
    }

    foreach(path; cacheFiles)
    {
        report ~= path ~ "\n";
    }

    string commonData = buildPath(root, "Data", "AppData", "ProgramData");
    report ~= "Mozilla GUID 目录存在=" ~ exists(buildPath(commonData, "Mozilla-1de4eec8-1241-4177-a864-e594e8d1fb38")).to!string ~ "\n";
    write(buildPath(root, "directory-report.txt"), report);
    writeln(report);
    writeln("真实 Firefox 页面、JavaScript HTTP 请求、截图验证通过：", screenshot);
}
