# iOS 终端链接：长按 Context Menu

> 状态：计划（未实现）
> 范围：`HerdrMobile` 的 Attach 终端。不换终端引擎。
> 目标：长按 URL 弹出系统 context menu（打开 / 复制 / 分享），换行切开的 URL 也能整段命中。

---

## 1. 要解决什么

现在 iPhone 上几乎选不到链接。

- SwiftTerm 默认 `linkHighlightMode = .hover`。没有指针悬停，隐式 URL 点不开。
- `requestOpenLink` 一旦命中就立刻 `UIApplication.shared.open`。和滚动、选区抢手势，也不让人选「复制还是打开」。
- macOS 已经有选中后右键 Open Link / Copy Link Address。iOS 没有对等物。

HerdrMobile 是 display-first（终端只看、composer 打字）。正确交互是 **长按出系统菜单**，不是单击打开。

---

## 2. 两个问题的结论

### 2.1 输出里被换行切开的 URL

能解决。分两种换行，不要混在一起。

| 种类 | 终端里实际发生了什么 | 命中 |
|---|---|---|
| **软换行** | 一行写满 `cols`，下一行 `isWrapped = true`。字节流里 URL 是连续的，只是画成两行 | SwiftTerm 已经按 `isWrapped` 链拼回去再跑链接正则。`link(at:)` 返回完整 URL，`rowRanges` 跨多行 |
| **硬换行** | 输出里真的有 `\n`（agent 自己折行、日志 prettier、markdown） | SwiftTerm 有启发式拼接：上一行尾、下一行头都像 URL 续写，就拼。长按走 `link(at:)` 就能吃到 |
| **OSC 8** | 显示文字和真正 URL 不是同一段（甚至显示文字中间有换行） | URL 存在 cell payload 里，不依赖可见文字是否被切开。长按命中任意一段即可 |

**不要**拿 `getBufferAsData()` 去扫链接。它每一行后面都插 `\n`，软换行会被拆成两段，`NSDataDetector` 会失败。

会话清单如果要从 buffer 收集，必须先按软换行（再加硬换行启发式）拼成逻辑行，再检测。从 PTY 字节流收集更简单：软换行根本不存在于字节里；硬换行才需要拼。

长按路径优先 `terminal.link(at:)`，不要自己再写一套折行。

做不到、也不做的：URL 中间夹了普通英文句子再续上；那不是链接，是两段字。

### 2.2 `NSDataDetector` 要不要一起用

要用，但只用 `.link`。不要做人名。

用户记得的「NSString entity detector」是 **`NSDataDetector`**（`NSRegularExpression` 子类）。公开类型只有：

- `.link`
- `.phoneNumber`
- `.address`
- `.date`
- `.transitInformation`

**没有人名。** 人名是 `NLTagger` 的 `.nameType`（或已弃用的 `NSLinguisticTagger`）。终端日志里 `Darwin`、`main`、`HEAD` 会被当成名字，噪音极大，这个产品不用。

`UITextView.dataDetectorTypes` 只对 `UITextView` 有效。SwiftTerm 是格子 `UIView`，那条路走不通。

怎么配：

| 路径 | 用什么 | 为什么 |
|---|---|---|
| 长按 hit-test | 先 `terminal.link(at: .buffer, .explicitAndImplicit)` | 已经处理 OSC 8 + 软/硬换行。我们不要重写 |
| 长按兜底 | 把按点附近拼好的逻辑行丢给 `NSDataDetector(.link)` | SwiftTerm 正则漏掉的 URL（奇怪 query、IDN）还能捞到 |
| 会话清单 | 拼好的逻辑行 + `NSDataDetector(.link)`；OSC 8 从 cell payload 另收 | 清单要的是「这段会话里出现过哪些网页」，不需要路径/文件名 |
| 过滤 | 只保留 `http` / `https` | SwiftTerm 隐式匹配还会给出 `file:`、相对路径、`ssh:`。iOS 上那些不是「打开网页」 |

`NSDataDetector` **不会**跨 `\n` 匹配。调用方必须先拼软换行。这是 API 限制，不是可选项。

macOS 的 `firstURL(in:)` 已经在用 `NSDataDetector(.link)`。iOS 复用同一过滤（scheme 白名单），不要再写一套正则。

---

## 3. 交互

### 3.1 长按（主路径）

按在链接上：系统 `UIContextMenuInteraction`。

- 预览：一行 URL（小 `UIViewController`）。不要抬起整块终端。
- 动作：
  - **打开** → `UIApplication.shared.open`
  - **复制** → 剪贴板
  - **分享** → `UIActivityViewController`（可选但值得做，iOS 习惯）
- 按在空白：`configurationForMenuAtLocation` 返回 `nil`。SwiftTerm 原来的 Select / Copy / Paste 气泡还在。
- 手指一滑：继续现有单指滚动，不出菜单。

**单击永远不打开链接。**

### 3.2 选区（对齐 macOS）

选区文本里 `NSDataDetector` 扫到 `http`/`https` 时，编辑菜单加同样三个动作。双击选中一整段 URL 就能用。换行切开的 URL：若选区只覆盖半截，菜单用选区文字跑 detector；若半截构不成合法 URL，菜单不加链接项——用户应改成长按（会拼完整段）。

### 3.3 会话清单（次路径，Heeler Attach Link）

key bar 一个带数字的链接 chip → sheet 列出本次 Attach 里收集到的网页。离开 `MobileTerminalScreen` 清空。滚动、重连保留（session 还活着）。

这是长按的备份：URL 已经滚出屏幕、或软换行命中失败时，清单里还有。

不做：始终给所有 URL 加下划线（agent 日志会花掉）。

---

## 4. 检测管线

```
长按 location
  → col/row（现有滚动手势已经在算）
  → terminal.link(at: .buffer(pos), .explicitAndImplicit)
      ├─ OSC 8 → 用 payload URL（不是显示文字）
      └─ 隐式（已拼 wrap）→ 用 match.text
  → 若空：拼按点所在逻辑行，NSDataDetector(.link)
  → scheme ∈ {http, https} 才出菜单
  → 否则 nil（把长让给 Select）
```

会话收集（PTY 泵字节之后，或新行 dirty 时）：

```
displayBuffer 按 isWrapped 拼逻辑行
  + 硬换行启发式（可选，第一版可只做软换行）
  → 每条逻辑行 NSDataDetector(.link)
  + 扫描 OSC 8 payload
  → 去重（URL 字符串）、保序、上限 50
```

第一版硬换行启发式可以只靠长按的 `link(at:)`，清单只保证软换行 + 字节流里连续的 URL。硬换行清单漏掉可以第二版补；长按命中更重要。

---

## 5. 手势冲突

现在已经有三套：

| 手势 | 谁 | 规则 |
|---|---|---|
| 单指 pan | `MobileTerminalUIView` 滚动 | 移动则滚动。context menu 系统自己会在位移后取消 |
| 0.7s long press | SwiftTerm `UIMenuController` | 空白处 Select |
| `UIContextMenuInteraction` | 我们加 | 链接上赢；空白返回 nil |

`shouldRecognizeSimultaneously` 对滚动保持现在的 `false`。context menu 的 recognizer 在命中链接时应让 SwiftTerm long press 失败（`require(toFail:)` 或命中后 `UIMenuController.hideMenu()`）。

iPad 触控板右键走同一 `UIContextMenuInteraction`，不用另写。

SwiftUI `.contextMenu` 不要用：绑的是整块 `UIViewRepresentable`，命不中格子。

---

## 6. 落点

纯逻辑（可测，不碰 UI）：

- `Packages/HerdrKit/Sources/HerdrKit/TerminalLink.swift`
  - `firstWebURL(in:)`：`NSDataDetector(.link)` + http/https 过滤（从 macOS `TerminalView.firstURL` 抽出来，macOS / iOS 共用）
  - 去重、上限、保序的小收集器

UI：

- `Sources/HerdrMobile/MobileTerminalView.swift` 的 `MobileTerminalUIView`
  - `UIContextMenuInteraction`
  - 选区菜单补链接动作
- `MobileAttachSession`
  - 收集器生命周期（start/stop/restart 清空或保留：重连保留，`onDisappear` 清空）
- `MobileTerminalScreen` key bar
  - 链接 chip + sheet

macOS：把 `firstURL` 改成调 HerdrKit，行为不变。

不改 SwiftTerm 源码。不换 libghostty。

---

## 7. 测试

HerdrKit 单测（必须先写再接线）：

1. 普通 `https://example.com/path?q=1` → 检出
2. `http` 同样
3. `ftp://`、`file://`、`mailto:`、`/usr/bin/ls`、相对路径 → 丢弃
4. 软换行拼合：`"https://github.com/foo/bar/pull/1"` 在 col=20 处切开成两行再拼 → 一条完整 URL
5. `getBufferAsData` 那种每行 `\n` 的错误输入 → 不断成两条（用拼合函数，不用 raw dump）
6. OSC 8 显示文字是 `docs`、payload 是 `https://…` → 清单和长按都用 payload
7. 去重：同一 URL 出现两次 → 一条
8. 上限 50：第 51 条丢掉或挤掉最旧（选定一种，测那种）
9. 人名 / 电话 / 地址：`NSDataDetector` 即使匹配也不进清单（只开 `.link`）

UI 无法单测的，QA 手测：见第 9 节。

---

## 8. 不做

- 单击打开
- 人名、电话、地址、日期
- `file://`、本地路径、`localhost` 自动端口转发
- 换终端引擎
- SwiftUI `.contextMenu` 包整个终端
- 给所有 URL 常驻下划线
- 离开详情后持久化链接历史

---

## 9. QA

1. agent 打一行短 `https://…` → 长按 → 打开 / 复制 / 分享都对。
2. 把终端缩窄，让 GitHub URL 软换行成两行 → 按在第一行或第二行都弹出**完整** URL，打开的不是半截。
3. 硬换行（agent 在 URL 中间真打了回车）→ 长按尽量拼出完整段；拼不出也不崩溃，空白长按仍是 Select。
4. OSC 8（显示 `changelog`，实际指向网页）→ 菜单打开的是 payload。
5. 长按空白 → Select / Copy / Paste，没有 Open Link。
6. 滚动、composer、key bar 不受影响。
7. 链接 chip 数字随新 URL 增加；离开屏幕再进 → 清零。
8. 选中半截 URL → 菜单可以没有链接项；选中整段 → 有。

---

## 10. 实现顺序

1. HerdrKit：`firstWebURL` + 收集器 + 软换行拼合 + 测试。
2. macOS 改为调用 `firstWebURL`（行为不变，防漂移）。
3. `MobileTerminalUIView` 挂 `UIContextMenuInteraction`，hit-test 用 `link(at:)` + `firstWebURL`。
4. 选区菜单补三个动作。
5. session 收集 + key bar chip + sheet。
6. 真机走第 9 节。

第 1–4 步就能交付「长按换行 URL → 打开或复制」。清单是加分，不挡主路径。
