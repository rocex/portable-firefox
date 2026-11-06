// 仅为 LDC BetterC 产物提供内存操作；普通测试程序使用 C 运行时实现。
module org.rocex.firefox.RuntimeMemory;

version(D_BetterC)  : version(LDC)
{
    import core.volatile: volatileLoad, volatileStore;

    // 满足 LLVM 生成的块复制调用；volatile 防止优化器把循环再次改写为 memcpy。
    extern (C) void* memcpy(void* destination, const(void)* source, size_t count) nothrow @nogc
    {
        auto output = cast(ubyte*)destination;
        auto input = cast(const(ubyte)*)source;
        foreach(index; 0 .. count)
        {
            volatileStore(output + index, volatileLoad(cast(ubyte*)(input + index)));
        }
        return destination;
    }

    // 不依赖 CRT 的内存填充。
    extern (C) void* memset(void* destination, int value, size_t count) nothrow @nogc
    {
        auto output = cast(ubyte*)destination;
        foreach(index; 0 .. count)
        {
            volatileStore(output + index, cast(ubyte)value);
        }
        return destination;
    }
}
