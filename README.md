# Firefox 便携版路径映射

面向现代官方 Windows Firefox 的 D 项目。通过程序目录的 `version.dll` 指定用户配置、缓存和系统数据路径，不修改 Firefox 程序文件。

## 构建与使用

需要 Windows、Dub 和包含 x86/x64 库的 LDC2（当前验证 1.43.0）；无第三方包，不依赖 D/C 运行时。

```text
dub build --config=portable --build=release --arch=x86_64 --compiler=ldc2
dub build --config=portable --build=release --arch=x86 --compiler=ldc2
```

| Firefox 位数 | 产物 | 大小 |
|---|---|---:|
| 64 位 | dist/x86_64/version.dll | 12,288 字节（12 KiB） |
| 32 位 | dist/x86/version.dll | 10,752 字节（10.5 KiB） |

完全退出 Firefox、备份配置后，将对应 DLL 放到 `firefox.exe` 同目录。位数按浏览器选择，不按操作系统选择。构建不自动覆盖 `firefox/` 中的文件。

可选 `portable.ini` 与 DLL 同目录，只有一个配置键：

```ini
PortableDataPath=profile
```

缺文件、缺键或空值使用 `profile` 目录。相对路径以 DLL 所在目录为基准，支持中文、空格、环境变量、UTF-8 和带 BOM 的 UTF-16LE。检查编码、长度、重复根键及设备路径；忽略未知键和节标题。配置文件无法读取或内容无效时记录错误并停止当前进程，不回退到默认系统配置。

## 路径映射

设 `profile` 为 `PortableDataPath` 的绝对路径：

| 用途 | 路径 |
|---|---|
| Firefox 用户配置 | profile |
| 本地配置／缓存 | profile/AppData |
| 应用元数据 | profile/AppData/State |
| RoamingAppData 查询 | profile/AppData/RoamingAppData |
| LocalAppData 查询 | profile/AppData |
| ProgramData 查询 | profile/AppData/ProgramData |

默认目录布局示意：

```text
Firefox/
  firefox.exe
  version.dll
  portable.ini                  可选
  profile/                      Firefox 用户配置
    AppData/
      State/                    应用元数据
      RoamingAppData/
        Mozilla/                浏览器需要时生成
      cache2/                   网页缓存，直接位于 AppData
      startupCache/
      ProgramData/
```

这只是路径布局示意，各目录由 Firefox 实际使用时创建，不一定全部出现。

DLL 只替换路径：**不创建数据目录、不探测写权限、不搬迁或删除已有数据**。只有 DLL 同目录的 `portable.log` 用于诊断。各目录的创建和写入失败由 Firefox 自己处理；缺少父目录时，不保证每个组件都能自行递归创建。

只设置 Firefox 的 `XRE_PROFILE_PATH`、`XRE_PROFILE_LOCAL_PATH`、`MOZ_APP_DATA`、`MOZ_LOCAL_APP_DATA`，不修改通用 `APPDATA`、`LOCALAPPDATA`、`ProgramData`。每个非内容 Firefox 进程读取当前配置；带 `-contentproc` 或 `--contentproc` 参数的进程仅转发系统版本接口，不执行目录初始化。修改配置后请完全退出 Firefox 再启动。

## 实现范围

1. 转发真实系统 version.dll 的 17 个接口，支持 x86/x64 ABI。
2. 读取一个配置根，派生固定路径，设置 Firefox 专用环境。
3. **只重定向 SHGetKnownFolderPath** 的 RoamingAppData、LocalAppData、ProgramData；未知 ID 透传，返回内存遵守 CoTaskMemFree 契约。
4. 仅修补 firefox.exe、mozglue.dll、xul.dll 的普通 IAT；保留 GetProcAddress 和标准 LoadLibrary 包装，以处理核心模块晚加载和动态取址。

标准延迟加载辅助函数经过被修补的 `GetProcAddress` 入口时可被覆盖；不扫描延迟导入表，不保证覆盖提前缓存的地址。目录包装函数的返回内存由调用方通过 `CoTaskMemFree` 释放。

## 测试

**运行测试前，必须在项目根目录下的 `firefox/` 子目录准备一套完整、可运行的 x64 Firefox 程序。** 不能只放 `firefox.exe`，也不能放尚未解压的安装包；需要保留 Firefox 原有的 DLL、资源文件和子目录。

```text
项目根目录/
  dub.json
  source/
  source-test/
  firefox/                      完整的 x64 Firefox 程序目录
    firefox.exe
    xul.dll
    mozglue.dll
    omni.ja
    browser/
    defaults/
    ...                         其余原始文件也必须保留
```

以上仅列出部分文件，不是可裁剪的最小清单。缺少完整 Firefox 时，真实浏览器测试无法完成，`dub test` 会失败；测试不会自动下载 Firefox，也不会跳过浏览器验证。

准备完成后，在项目根目录执行：

```text
dub test
```

唯一 `unittest` 配置自动构建两种架构的 Release，再运行配置、路径、ABI、环境变量、KnownFolder/IAT、PE 产物、中文输出和真实 Firefox 页面测试。IAT 测试自动使用子进程，避免污染其他测试；不需要手动选择测试组。控制台使用 Unicode 输出，文件和管道使用 UTF-8。测试代码不编入 DLL。

前置条件：PATH 中有完整 LDC2；默认 `firefox/` 存在 x64 Firefox 程序文件；磁盘能容纳新副本，允许监听回环端口。缺前置条件明确报错，不自动下载或跳过。

浏览器测试复制程序到新建 `build/browser-*`，不复制原 data、profile、INI 或代理 DLL。固定使用不存在的全新 Data，不预建目录；通过回环页面的 JavaScript HTTP 请求和截图验证。使用 Windows Job 在超时后清理测试进程树，不关闭沙箱，不运行原始参考 DLL，不修改原浏览器配置。

- `PORTABLE_FIREFOX_SOURCE`：指定测试浏览器程序目录。
- `PORTABLE_TEST_DLL`：指定与浏览器位数匹配的自产 DLL。
- `PORTABLE_ARTIFACT_ROOT`：指定只读 PE 校验产物根（包含 x86、x86_64）。

测试使用全新配置。`dub test --arch=x86 --compiler=ldc2` 使用 32 位测试进程，但默认真实 Firefox 仍为 x64，不代表已验证 32 位浏览器。

## 明确的兼容边界

- 当前实际页面验证基于本地 x64 Firefox 160 beta；不承诺旧版、衍生浏览器、插件或所有浏览器功能。
- 只重定向 `SHGetKnownFolderPath`；其他 Shell 目录 API 的调用可能返回系统路径。
- 代理若未被加载，无法强制便携；非核心模块、模块初始化阶段、提前缓存的指针和自定义解析器可能绕过。
- 内容进程不装 Hook，独立更新服务和崩溃辅助程序不受控制。没有零系统痕迹保证。
- 主进程 DLL 初始化仍有系统库加载和 I/O，存在加载器锁兼容约束。
- 没有通过关闭安全更新、沙箱或系统防护来保证运行。

## 代码职责

- `source/FirefoxPortable.d`：配置、路径、进程初始化和系统版本接口代理。
- `source/FolderRedirection.d`：唯一 KnownFolder 路径包装及必要加载/IAT 处理。
- `source/RuntimeMemory.d`：LLVM 隐式内存操作的最小实现，避免 CRT 依赖。
- `source-test/`：统一 unittest；测试代码不编入 DLL。

发布配置使用体积优先优化、只读节合并、标准 PE 对齐和 NX/ASLR，不使用压缩壳。
