# Firefox 便携版路径映射

通过 `version.dll` 指定 Firefox 的配置、缓存和系统数据路径，不修改 Firefox 程序文件。支持 Windows x86、x64，使用 D / Dub 构建，无第三方包及 C/D 运行时依赖。

## 构建与使用

安装 Dub 和包含双架构库的 LDC2（已验证 1.43.0），执行：

```text
dub build --config=portable --build=release --arch=x86_64 --compiler=ldc2
dub build --config=portable --build=release --arch=x86 --compiler=ldc2
```

也可将 `--compiler=ldc2` 改为 `--compiler=dmd`。LDC2 使用内置 LLD；Release 启用体积优化、只读节合并及 NX/ASLR，不使用压缩壳。

| Firefox 位数 | LDC2 产物 | 大小 |
|---|---|---:|
| 64 位 | dist/x86_64/version.dll | 12,288 字节（12 KiB） |
| 32 位 | dist/x86/version.dll | 10,752 字节（10.5 KiB） |

完全退出 Firefox 并备份配置，将对应 DLL 放到 `firefox.exe` 同目录。按浏览器位数选择产物；构建不会自动部署。

可选的 `portable.ini` 与 DLL 同目录：

```ini
PortableDataPath=profile
```

- 缺文件、缺键或空值时使用 `profile`。
- 相对路径基于 DLL 目录；支持中文、空格、环境变量、绝对路径及普通 UNC。
- 支持 UTF-8 和带 BOM 的 UTF-16LE，文件上限 64 KiB。
- 忽略节标题和未知键；重复根键、无效编码或无效路径会报错。
- 配置不可读或无效时写入 `portable.log` 并停止当前进程，不回退系统配置。

## 路径映射

设 P 为 `PortableDataPath` 的绝对路径：

| 用途 | 路径 |
|---|---|
| Firefox 用户配置 | P |
| 本地配置／缓存、LocalAppData 查询 | P/AppData |
| 应用元数据 | P/AppData/State |
| RoamingAppData 查询 | P/AppData/RoamingAppData |
| ProgramData 查询 | P/AppData/ProgramData |

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
      cache2/                   网页缓存
      startupCache/
      ProgramData/
```

目录树仅表示映射位置。**DLL 不创建数据目录、不探测写权限、不搬迁或删除文件**，目录由 Firefox 实际使用时创建，缺少父目录时不保证写入成功。`portable.log` 位于 DLL 同目录。

仅设置 `XRE_PROFILE_PATH`、`XRE_PROFILE_LOCAL_PATH`、`MOZ_APP_DATA`、`MOZ_LOCAL_APP_DATA`；通用 `APPDATA`、`LOCALAPPDATA`、`ProgramData` 保持原值。修改配置后须完全退出 Firefox 再启动。

## 实现与边界

- 转发系统 `version.dll` 的 17 个接口。
- 只重定向 `SHGetKnownFolderPath` 的 RoamingAppData、LocalAppData、ProgramData；未知目录透传，返回内存由调用方使用 `CoTaskMemFree` 释放。
- 仅修补 `firefox.exe`、`mozglue.dll`、`xul.dll` 的普通 IAT，使用加载包装和 `GetProcAddress` 处理晚加载模块及动态取址。
- 带 `-contentproc`／`--contentproc` 的进程只转发版本接口，不初始化目录 Hook。
- 不覆盖其他 Shell 目录 API、非核心模块、提前缓存的指针或独立更新／崩溃辅助程序；不保证零系统痕迹。
- 代理未被加载时无法强制便携；主进程 DLL 初始化仍受加载器锁约束。
- 已验证本地 x64 Firefox 160 beta 的页面流程，不承诺所有版本和功能；不关闭沙箱或系统防护。

## 测试

### 单元测试：无需 Firefox

```text
dub test --compiler=ldc2 --arch=x86_64
dub test --compiler=ldc2 --arch=x86
dub test --compiler=dmd --arch=x86_64
dub test --compiler=dmd --arch=x86
```

默认 `dub test` 使用 `unittest` 配置，先用所选编译器构建双架构 Release，再验证配置、路径、ABI、环境、KnownFolder/IAT、PE 结构和中文输出。IAT 测试在独立子进程中执行。PATH 中需要 Dub、对应编译器及双架构库。

### Firefox 集成测试

**项目根目录的 `firefox/` 必须包含完整、可运行的 x64 Firefox。** 不能只放 `firefox.exe` 或未解压的安装包。

```text
项目根目录/
  dub.json
  source/
  source-test/
  firefox/
    firefox.exe
    xul.dll
    mozglue.dll
    omni.ja
    browser/
    defaults/
    ...                         保留其余原始文件
```

上面不是可裁剪的最小文件清单。准备完成后执行：

```text
dub test --config=firefox-test --compiler=ldc2 --arch=x86_64
```

此配置构建 x64 DLL，并使用隔离程序副本和全新数据目录验证页面、JavaScript HTTP 请求及截图。需要可用磁盘空间和回环端口；缺 Firefox 时明确失败，不自动下载或跳过。

测试副本和证据保存在 `build/browser-*`。不复制原 data、profile、INI 或代理 DLL，不修改原浏览器配置；超时只清理测试进程树。控制台输出 Unicode，文件和管道使用 UTF-8。

| 环境变量 | 用途 |
|---|---|
| `PORTABLE_FIREFOX_SOURCE` | 测试浏览器程序目录 |
| `PORTABLE_TEST_DLL` | 与浏览器位数匹配的自产 DLL |
| `PORTABLE_ARTIFACT_ROOT` | PE 校验根目录，包含 x86、x86_64 |

测试进程位数不代表浏览器位数。验证 x86 Firefox 时须提供完整的 32 位浏览器及对应 DLL，并设置上述路径。

## GitHub Actions

`.github/workflows/build.yml` 在分支／标签推送、Pull Request 时运行，也支持手动触发。

- `windows-latest` 上运行最新稳定 DMD、LDC2 × x86、x86_64 四组构建和非浏览器单测；不运行 Firefox 测试。
- 保留编译器签名验证；安装失败等待 60 秒后重试一次，仍失败则停止。
- LDC2 使用内置 LLD；DMD 通过 `LINKCMD`／`LINKCMD64` 选择安装包中的 `lld-link.exe`。
- 测试通过后上传 ZIP，含 `version.dll`、`portable.ini`；Actions Artifacts 保留 30 天。
- 推送的标签名包含 `release`（不区分大小写）时，四组全部成功后发布同名 GitHub Release，附上四份 ZIP。
- 发布使用 `GITHUB_TOKEN` 的 `contents: write` 权限，无需额外令牌。

`windows-latest` 是 GitHub 托管环境，不代表所有 Windows 桌面版本均已验证。

## 代码目录

- `source/org/rocex/firefox/FirefoxPortable.d`：配置、路径、进程初始化及版本接口代理。
- `source/org/rocex/firefox/FolderRedirection.d`：KnownFolder 路径包装和 IAT 处理。
- `source/org/rocex/firefox/RuntimeMemory.d`：仅为 LDC BetterC 构建提供内存操作。
- `source-test/org/rocex/firefox/test/`：单元测试与独立 Firefox 集成测试，不编入 DLL。

生产模块使用 `org.rocex.firefox` 包，测试模块使用 `org.rocex.firefox.test` 包。
