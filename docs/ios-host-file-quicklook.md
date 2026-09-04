# iOS：终端里的宿主文件链接 → Quick Look（只读）

> 状态：计划（未实现）
> 前置：已上线的长按 http(s) context menu（`main` @ `5c37845`）
> 范围：`HerdrMobile` Attach。文件在 **herdr 所在那台机器** 上，不是手机本地磁盘。

## 需求

Agent 终端里会出现路径和 `file://` 链接（`README.md`、`./docs/foo.md`、`/Users/…/bar.swift`）。现在 `WebURL.first` 把这些全丢掉。

用户要：

1. 长按路径，和网页一样出系统菜单。
2. **预览** = 把文件 **当前内容** 拉到手机，用 **Quick Look** 只读打开。
3. 不是 live tail，也不是把远端目录挂成本地磁盘。一次打开 = 一份快照。

Markdown 用 QL 当纯文本看即可（「read all 就可以了」）。图片 / PDF / 源码同样走 QL。

## 不做

- 单击打开（沿用网页规则）
- 手机 Files / iCloud 里的文件
- 写回远端、编辑、保存
- 目录浏览（那是 Mac `DeviceFilesView`）
- 把 `DeviceFileService`（macOS-only，走系统 `ssh`+`cat`）搬到 iOS
- 无限大文件、可执行文件当脚本跑
- 把路径当 Safari URL 打开

## 检测

SwiftTerm `link(at:)` 已经会命中：

- `file:` scheme
- 绝对路径 `/…`
- `./` `../` `~/` 以及部分相对路径

长按仍用 `.screen` + `link(at:)`。分类从「只认 http(s)」扩成：

| `link(at:)` 返回 | 判定 | 菜单 |
|---|---|---|
| `http` / `https` | 网页 | 打开 / 复制 / 分享（现状） |
| `file://…` | 宿主路径 = URL.path | 预览 / 复制路径 |
| `/…` `~/…` `./…` `../…` | 宿主路径 | 同上 |
| `javascript:` `data:` `ftp:` | 丢弃 | 无菜单 |
| 空白 | 无 | Select |

相对路径相对 **该 pane 的 `cwd`**（`AgentInfo.cwd` / `PaneInfo.cwd`）。没有 cwd 且路径不是绝对/`~` → 菜单项「预览」不可用，仍可复制原文。

`~` 用 SSH 上已经解析过的 home（`MobileTransport` 建连时探过 home）。不要在手机上展开成 iOS sandbox home。

路径规范化：`standardizingPath`，拒绝空字符串。允许 `..` 解析后的绝对路径（宿主自己的文件系统）；不要做 chroot，这是开发者看自己机器上的文件。

## 拉取（快照，不是 stream）

iOS 已有 `SSHConnection.openSFTP` + `SSHSFTPClient.readFileIfPresent` / `attributes`。`MobileTransport` 今天没有暴露 SFTP，要加：

```swift
func openSFTP(timeout: Duration) async throws -> SSHSFTPClient
```

流程：

1. 解析成宿主绝对路径。
2. `attributes`：没有 size、或 size > **25 MiB** → 提示太大，不拉。
3. 目录（permissions 含目录位）→ 不预览。
4. `readFileIfPresent` → `nil` 当「文件不存在」。
5. 写到 `Caches/HostFilePreviews/<uuid>/原文件名`，扩展名必须保留（QL 靠它）。
6. `QLPreviewController` 打开该本地副本。
7. dismiss 后删掉该 uuid 目录。

第一版整文件读入内存再落盘。25 MiB 上限让这可接受。以后要更大文件再改成边读边写；那不是这一版。

不要对 PTY 字节做文件检测来预取。只在用户点「预览」时拉。会话 chip 继续只收集 http(s)。

## UI

长按文件：

- **预览**（主动作，context menu 预览区也可以直接 commit 到 QL）
- **复制路径**
- 不要「用 Safari 打开」

加载中：终端上盖一个小进度（不确定进度即可）。失败：alert（不存在 / 太大 / SFTP 不可用）。

QL：`QLPreviewController` + `QLPreviewControllerDataSource`（一项）。`QLPreviewControllerDelegate` 里关掉分享/导出若容易；否则只读副本在 Caches、用户分享出去也只是那份快照。

`MobileTerminalScreen` 需要 `cwd: String?`（从 selected agent/pane 传入）。`MobileRootView` 已有这些模型。

## 落点

- `Packages/HerdrKit/Sources/HerdrKit/TerminalLink.swift`
  - `HostFilePath.parse(raw:cwd:home:)` → 绝对 POSIX 路径或 nil
  - `DetectedLink.web(URL)` / `.hostFile(String)`
- `Packages/HerdrKit/Tests/HerdrKitTests/` 路径解析测试（`~/a`、`./a.md` + cwd、`file:///Users/x/a.md`、拒绝 http）
- `Sources/HerdrMobile/MobileTransport.swift`：`openSFTP`
- `Sources/HerdrMobile/MobileTerminalView.swift`：菜单分支 + fetch + QL present
- `CHANGELOG` Unreleased

不改 SwiftTerm。不改 Mac `DeviceFilesView`。

## 测试

1. `file:///Users/me/README.md` + cwd 任意 → `/Users/me/README.md`
2. `./docs/a.md` + cwd `/proj` → `/proj/docs/a.md`
3. `~/foo.md` + home `/Users/me` → `/Users/me/foo.md`
4. `https://x.com` → web，不是 hostFile
5. `javascript:…` → nil
6. 空 cwd + `foo.md` → nil（相对路径无法解析）

SFTP / QL 真机测。

## QA

1. agent 打 `cat README.md` 或打印 `./foo.md` → 长按路径 → 预览 → 手机 QL 看到当前内容。
2. 改远端文件后再预览 → 是新快照，不是第一次缓存。
3. 长按 https 仍是打开/复制/分享，行为不变。
4. 空白长按仍是 Select。
5. 不存在的路径 → 失败提示，不崩。
6. 离开终端再进 → 临时预览文件已清。

## 实现顺序

1. HerdrKit 路径解析 + 测试。
2. `MobileTransport.openSFTP`。
3. 长按菜单文件分支 + SFTP 快照 + QL。
4. 把 `cwd` 传入 `MobileTerminalScreen`。
5. 真机：markdown、图片、缺失文件、过大文件。
