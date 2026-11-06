// 提供 Unicode 控制台与 UTF-8 重定向输出，并验证输出契约。
module org.rocex.firefox.test.ConsoleEncodingTests;

import core.sys.windows.windows;
import std.conv: text;
import std.exception: enforce;
import std.string: replace;
import std.utf: toUTF16;

// 接受与 writeln 相同的常见字符串和数值参数。
void consoleLine(Arguments...)(Arguments arguments)
{
    consoleWrite(text(arguments) ~ "\n");
}

// 不改变代码页或系统设置，统一输出中文测试结果。
void consoleWrite(string message)
{
    writeOutput(GetStdHandle(STD_OUTPUT_HANDLE), message);
}

// 控制台使用 UTF-16 API，不受活动代码页影响；文件和管道保持 UTF-8。
void writeOutput(HANDLE handle, string message)
{
    DWORD mode;
    if(GetConsoleMode(handle, &mode))
    {
        auto wide = toUTF16(message.replace("\r\n", "\n").replace("\n", "\r\n"));
        size_t offset;
        while(offset < wide.length)
        {
            size_t count = wide.length - offset;
            if(count > 16000)
            {
                count = 16000;
            }
            // 避免在分块边界拆开 UTF-16 代理项。
            if(offset + count < wide.length && wide[offset + count - 1] >= 0xd800 && wide[offset + count - 1] <= 0xdbff)
            {
                --count;
            }
            DWORD written;
            enforce(WriteConsoleW(handle, wide.ptr + offset, cast(DWORD)count, &written, null) != 0 && written > 0, "控制台 Unicode 输出失败");
            offset += written;
        }
    }
    else
    {
        size_t offset;
        while(offset < message.length)
        {
            size_t count = message.length - offset;
            if(count > 65536)
            {
                count = 65536;
            }
            DWORD written;
            enforce(WriteFile(handle, message.ptr + offset, cast(DWORD)count, &written, null) != 0 && written > 0, "UTF-8 输出失败");
            offset += written;
        }
    }
}

// 有控制台时使用独立非活动缓冲区验证 Unicode，不切换屏幕或更改代码页。
unittest
{
    auto buffer = CreateConsoleScreenBuffer(GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, CONSOLE_TEXTMODE_BUFFER, null);
    if(buffer == INVALID_HANDLE_VALUE)
    {
        // CI 或无控制台宿主无法创建控制台缓冲区，管道路径由下一个用例必测。
        return;
    }
    scope(exit)
    {
        CloseHandle(buffer);
    }
    writeOutput(buffer, "中文输出测试");
    wchar[32] result = 0;
    DWORD count;
    COORD origin;
    // 中文在控制台占双宽单元，回读区域需覆盖 12 个单元，而非 6 个。
    enforce(ReadConsoleOutputCharacterW(buffer, result.ptr, 12, origin, &count) != 0);
    enforce(count >= 6 && result[0 .. 6] == "中文输出测试"w, text("控制台 Unicode 回读不符：", count, " / ", result[0 .. count]));
}

// 重定向输出必须保留原始 UTF-8 字节，包含中文和非 BMP 字符。
unittest
{
    HANDLE reader, writer;
    enforce(CreatePipe(&reader, &writer, null, 4096) != 0);
    scope(exit)
    {
        CloseHandle(reader);
        CloseHandle(writer);
    }
    enum message = "隔离浏览器测试：中文路径，字节数=13824，符号😀\n";
    writeOutput(writer, message);
    char[512] bytes;
    DWORD count;
    enforce(ReadFile(reader, bytes.ptr, bytes.length, &count, null) != 0);
    enforce(bytes[0 .. count] == message, "管道中的 UTF-8 字节必须保持不变");
    writeOutput(writer, "");
}
