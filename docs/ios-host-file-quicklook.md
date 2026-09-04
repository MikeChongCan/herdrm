# iOS：终端里的宿主文件链接 → Quick Look（只读）

> 状态：计划（评审后修订，未实现）
> 前置：长按 http(s) context menu（`main` @ `5c37845`）
> 范围：`HerdrMobile` Attach。文件在 **herdr 所在那台机器** 上，不是手机磁盘。

## 需求

长按终端里的路径 / `file://`，把文件 **当时那一份** 拉到手机，用 **Quick Look** 只读打开。不是 live tail，不是挂盘。

## 评审后必须遵守的约束

1. **SwiftTerm 不会把裸 `README.md` 当链接。** 隐式正则每条路径分支都要 `/` 或 scheme。不改 SwiftTerm。裸文件名靠 **已选中的文本** 兜底（双击选词再长按 / 选区编辑菜单）。
2. **`SSHSFTPAttributes.permissions` 被 `& 0o777`，目录位没有。** 必须在 mask 前暴露 `isDirectory`（或完整 file type）。
3. **`readFileIfPresent` 无上限。** 25 MiB 必须在读 chunk 时打断，不能只信 stat。
4. **`$HOME` 在 `socketPath` override 时根本不探。** home 与 socket 解析分开，始终探并存在 transport 上。
5. **`file://hostname/path` 不能用 `URL.path` 默默丢掉 host。** 只接受空 host 或 `localhost`。
6. **cwd 不能冻在 `MobileTerminalScreen.init`。** 点预览时从 snapshot 按 paneID 现查。
7. 非 `file` 的 scheme（`ssh:` `git:` `mailto:` `ftp:` `javascript:`…）一律不是宿主路径。
8. 路径去掉首尾空白；含内部空白则拒绝（SwiftTerm wrap 会把空格尾巴拼进来）。
9. Windows 盘符路径拒绝。没有 Windows 路径翻译。

## 检测

长按 `configurationForMenuAtLocation`：

1. `terminal.link(at: .screen, .explicitAndImplicit)` → `DetectedLink.parse`
2. 若 nil 且 `selection.active` → 用 `selection.getSelectedText()` 再 parse（裸 `README.md`）
3. 仍 nil → 返回 nil（Select）

| raw | 结果 |
|---|---|
| http(s) | `.web` |
| `file://` 且 host 空/`localhost` | `.hostFile(path)` |
| `file://otherhost/…` | nil |
| `/…` `~/…` `./…` `../…` 以及含 `/` 的相对路径 | `.hostFile`（相对路径要有 live cwd） |
| 选中的 `README.md`（无 `/`） | `.hostFile`，相对 live cwd；无 cwd 则只能复制原文 |
| 其它 scheme | nil |

`~` 用 transport 上存的 remote home，不是 iOS sandbox。

会话 chip 仍只收集 http(s)。

## 拉取

`MobileTransport.openSFTP(timeout:)`。

`SSHSFTPAttributes` 增加 `isDirectory: Bool`（stat 的 mode `& 0o170000 == 0o040000`）。`permissions` 继续是 0o777 权限位，不要把 type 混进去。

新 API 或给 `readFileIfPresent` 加 `maxBytes`：chunk 累加超过则 abort，返回明确错误。读超时 **60s**，与 RPC 4s 探针分开。

流程：stat → 无 size 或 size>25MiB 拒绝 → 目录拒绝 → bounded read → 写入 `Caches/HostFilePreviews/<uuid>/原名` → QL → dismiss 删目录。

## UI

文件菜单：预览、复制路径。不要 Safari。

网页菜单不变。

加载：小 ProgressView overlay。失败 alert。

QL：`import QuickLook`，`QLPreviewController` 一项，从 `nearestViewController()` present。

## 落点

- HerdrKit `DetectedLink` / `HostFilePath.parse(raw:cwd:home:)`
- HerdrSSH `isDirectory` + bounded read
- MobileTransport：存 `remoteHome`、`openSFTP`
- MobileTerminalView：菜单分支、fetch、QL
- MobileRootView：传入 paneID 即可，cwd 现查
- CHANGELOG Unreleased

不改 SwiftTerm。不改 Mac DeviceFilesView。不把 DeviceFileService 搬到 iOS。

## 测试（HerdrKit）

1. `file:///Users/me/README.md` → `/Users/me/README.md`
2. `file://localhost/Users/me/a.md` → 同上
3. `file://other/Users/me/a.md` → nil
4. `./docs/a.md` + cwd `/proj` → `/proj/docs/a.md`
5. `~/foo.md` + home `/Users/me` → `/Users/me/foo.md`
6. `https://x.com` → web
7. `javascript:…` `ssh:host` `git://` `C:\Windows\a.md` → nil
8. `foo.md` + cwd `/proj` → `/proj/foo.md`（选区兜底）
9. `foo.md` 无 cwd → nil
10. `" /tmp/a.md "` trim → `/tmp/a.md`；内部空格拒绝

## QA

1. `./foo.md` 或 `file://` 长按 → QL 看到当前内容。
2. 双击 `README.md` 再长按 → 也能预览。
3. 改远端文件后再预览是新快照。
4. https 菜单不变；空白仍是 Select。
5. 缺失 / 目录 / >25MiB → 提示，不崩。
6. 离开终端，Caches 预览目录已清。

## 实现顺序

1. HerdrKit 解析 + 测试
2. SFTP isDirectory + bounded read
3. transport home + openSFTP
4. 菜单 + QL
5. 真机
