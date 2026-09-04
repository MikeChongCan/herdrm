# iOS 终端链接：长按 Context Menu

> 状态：计划（评审后修订，未实现）
> 范围：`HerdrMobile` 的 Attach 终端。不换终端引擎，不改 SwiftTerm 源码。
> 目标：长按 URL 弹出系统 context menu（打开 / 复制 / 分享）。软换行切开的 URL 整段命中。

评审记录见文末。已对照源码接受的约束写进正文，不再保留被否的 API 假设。

---

## 1. 要解决什么

iPhone 上几乎选不到链接。缺口是 **没有长按菜单**，不是「单击把链接抢走了」。

- SwiftTerm 默认 `linkHighlightMode = .hover`。iPhone 没有悬停，`linkForClick` 对隐式 URL 基本不命中；`singleTap` 还要求 `isFirstResponder`（键盘开着）。
- iPad 有指针时 `.hover` 会高亮，单击仍走 `requestOpenLink` → 立刻 `UIApplication.shared.open`。加 context menu **不会**关掉这条。必须把 delegate 改成空操作，打开只从菜单发生。
- macOS 已有选中后右键 Open Link / Copy Link Address。iOS 没有对等物。

HerdrMobile 是 display-first。正确交互是长按出系统菜单。

---

## 2. 换行 URL 与 NSDataDetector

### 2.1 换行

| 种类 | 实际发生了什么 | 长按能不能整段命中 |
|---|---|---|
| **软换行** | 写满 `cols`，下一行 `isWrapped = true`。PTY 字节里 URL 连续 | 能。`link(at:)` 按 `isWrapped` 链拼完再跑正则 |
| **硬换行** | 输出里真有 `\n` | **只有上一行画到右缘附近才拼。** `canJoinImplicitRows` 要求 `lastCol >= cols - max(2, cols/5)`。agent 在屏中折断的短 URL，`link(at:)` 给半截。QA 接受半截，不崩溃 |
| **OSC 8** | 显示文字和 payload URL 不是同一段 | 能。命中任一格子用 payload。**payload 仍要走 http/https 白名单**，SwiftTerm 不做 scheme 检查，`javascript:` / `data:` 会原样返回 |

不要用 `getBufferAsData()` 扫链接：每行后面都插 `\n`，软换行被拆。

`displayBuffer`、`Buffer.lines`、`isWrapped` 都是 SwiftTerm **internal**。HerdrMobile / HerdrKit **不能**按行遍历 buffer。长按只调用公开的 `terminal.link(at:)`。清单不走 buffer，走下面的 PTY 剥离器。

### 2.2 `NSDataDetector`

用，只开 `.link`。没有人名类型；人名是 `NLTagger`，终端日志误报太多，不用。

`NSDataDetector` 不跨 `\n`。软换行的拼接已经在 SwiftTerm `link(at:)` 里，我们不在 HerdrKit 再实现一套 wrap join。

兜底 detector **必须绑在按下的格子上**：对逻辑行跑 detector 之后，只有 range 覆盖按点的那条才算。整行 `firstWebURL` 会在空白字上弹出别人的 URL，并挡住 Select。

---

## 3. 交互

### 3.1 长按（主路径，第一版交付）

按在链接上：`UIContextMenuInteraction`。

- 预览：一行 URL，不要抬起整块终端。
- 动作：打开 / 复制 / 分享。
- 按在空白：返回 `nil`，SwiftTerm 的 Select 气泡还在。
- 手指一滑：现有单指滚动继续。不要让 pan `require(toFail:)` context menu，否则每次滚动都要等 ~0.5s。

`requestOpenLink` 改为空操作。打开只从菜单。

### 3.2 选区（第二版）

不要往 SwiftTerm 的 `UIMenuController` 里塞 item：`showContextMenu` 非 public，并且每次把 `menuItems` 设成 `[]`；`canPerformAction` 只放行内置 selector。

第二版用 iOS 18 的 `UIEditMenuInteraction`，选区文本经 `firstWebURL` 有 http(s) 再出同样三个动作。半截选区构不成 URL 就没有链接项。

### 3.3 会话清单（第二版）

key bar 带数字的链接 chip → sheet。`MobileAttachSession` 活着就保留（含重连）；`onDisappear` / `stop` 清空。

---

## 4. 检测管线（长按）

触摸点是视口坐标。滚动手势里的 `row = location.y / rowHeight` 是 **screen row**（0..<rows）。`link(at: .buffer)` 把 row 当绝对 buffer 行，滚过 scrollback 会指错行。

```
location
  → col/row 用 cell 尺寸（与现有 pan 相同），这是 screen 坐标
  → terminal.link(at: .screen(Position(col, row)), .explicitAndImplicit)
      ├─ OSC 8 payload
      └─ 隐式 match.text（已拼 isWrapped）
  → 一律 firstWebURL / http(s) 过滤（含 OSC 8）
  → 若空：不能对「整行 firstWebURL」交差。只有能把 detector range 映回格子、且包含按点时才兜底
  → 第一版兜底可省略：SwiftTerm 隐式正则已经覆盖常见 URL；错行打开比漏检更糟
  → 否则 configuration = nil
```

`getTerminal()`、`link(at:)`、`LinkLookupLocation`、`LinkLookupMode` 都是 public。`calculateTapHit` 不是，不要调用。

---

## 5. 手势

| 手势 | 谁 | 规则 |
|---|---|---|
| 单指 pan | `MobileTerminalUIView` | 保持 `shouldRecognizeSimultaneously = false`。位移则滚动 |
| 0.7s long press | SwiftTerm `setupGestures`，recognizer **没有存成属性** | 空白 Select |
| context menu | 我们加 | 链接上赢 |

`UIContextMenuInteraction` 没有拿去 `require(toFail:)` 的公开 stored recognizer。用：

```swift
let menuGR = interaction.gestureRecognizerForFailureRelationship
// super.init 已经装上 SwiftTerm long press
for case let lp as UILongPressGestureRecognizer in gestureRecognizers ?? []
    where lp !== menuGR {
    lp.require(toFail: menuGR)
}
```

不要在菜单已经出来之后 `hideMenu()`——太晚，Select 已经开始。

真机必须验：链接长按只有 context menu；空白长按只有 Select；快速滑动能滚。

---

## 6. 会话收集（第二版，禁止扫 raw PTY、禁止扫 displayBuffer）

PTY 块会在任意字节切开，中间夹 CSI / OSC。对 chunk 直接 `NSDataDetector` 会漏检或误检。

在 `MobileAttachSession.feed` 里做 **有状态的剥离器**（纯逻辑放 HerdrKit，可测）：

1. 累积字节，剥 CSI、剥 OSC（含 OSC 8：记下 payload URL）。
2. 按真实 `\n` 切成可见行（软换行不在字节里，一行里的 URL 是完整的）。
3. 完整行才跑 `NSDataDetector(.link)` + http(s)。
4. 半行留在 buffer，等后续字节。
5. OSC 8 payload 同样过滤后进清单。
6. URL 字符串去重、保序、上限 50，满了丢掉**最旧**。

硬换行切开的 URL 清单会漏；长按也只有右缘折行才能拼。第一版清单不承诺硬换行。

---

## 7. 落点

- `Packages/HerdrKit/Sources/HerdrKit/TerminalLink.swift`
  - `firstWebURL(in:)`：`NSDataDetector(.link)` + `http`/`https`（从 macOS `TerminalView.firstURL` 抽出，Foundation only）
  - `WebLinkCollector`：去重 / 上限 50 丢最旧
  - `VisibleTextExtractor`：有状态剥 CSI/OSC，完整行回调（第二版）
- `Sources/HerdrMobile/MobileTerminalView.swift`
  - `requestOpenLink` 空操作
  - `MobileTerminalUIView`：`UIContextMenuInteraction` + failure 关系 + `.screen` hit-test
- 第二版：`UIEditMenuInteraction`；collector 接到 `feed`；key bar chip + sheet
- macOS：`firstURL` 改调 HerdrKit

不改 SwiftTerm。不换 libghostty。

---

## 8. 测试（HerdrKit，接线前先绿）

1. `https://example.com/path?q=1` → 检出
2. `http://` 同样
3. `ftp://`、`file://`、`mailto:`、`javascript:`、`data:`、`/usr/bin/ls`、相对路径 → 丢弃
4. 去重：同一 URL 两次 → 一条
5. 上限 50：第 51 条挤掉最旧
6. 只开 `.link`：电话/地址字符串不进清单
7. 剥离器：URL 被 CSI 色码切开仍检出
8. 剥离器：OSC 8 payload `https://…`、显示文字 `docs` → 收集 payload 不是显示文字
9. 剥离器：chunk 切在 URL 中间 → 等完整行再检出，不产出半截
10. 剥离器：软换行不存在于输入（无 `\n` 的长 URL）→ 一条

不在 HerdrKit 测 SwiftTerm 的 `isWrapped` 拼接（那是引擎内部）。软换行长按靠 QA。

---

## 9. 不做

- 单击打开（含 iPad 指针单击）
- 人名、电话、地址、日期
- 遍历 `displayBuffer` / `isWrapped`
- 对 raw PTY chunk 直接 detector
- 整行 `firstWebURL` 当长按兜底
- 往 SwiftTerm `UIMenuController` 塞 item
- `file://`、本地路径、localhost 端口转发
- 换引擎
- SwiftUI `.contextMenu` 包整个终端
- 常驻下划线
- 离开详情后持久化链接

---

## 10. QA

1. 短 `https://…` 长按 → 打开 / 复制 / 分享。
2. 缩窄终端让 GitHub URL 软换行两行 → 按第一行或第二行都是**完整** URL。
3. 硬换行：右缘折开的尽量完整；屏中折开允许半截或不出菜单，不崩溃。空白长按仍是 Select。
4. OSC 8 显示 `changelog` → 打开 payload；`javascript:` payload → 不出菜单。
5. 长按空白 → 只有 Select / Copy / Paste。
6. 滚动、composer、key bar 不受影响。快速滑动不要被菜单拖住。
7. iPad 指针：悬停可高亮，**单击不打开**；长按或右键出菜单。
8. 第二版：chip 数字增加；离开再进清零。选中整段 URL 有链接项，半截没有。

---

## 11. 实现顺序

1. HerdrKit `firstWebURL` + 过滤测试。
2. **最小可交付：** `requestOpenLink` 空操作 + context menu + `.screen` hit-test + long-press failure 关系。真机 QA 1–7。
3. macOS `firstURL` 改调 HerdrKit。
4. 第二版：剥离器 + collector + chip。
5. 第二版：`UIEditMenuInteraction` 选区动作。

第 2 步就是「长按软换行 URL → 打开或复制」。清单和选区菜单不挡。

---

## 12. 评审记录

三路只读评审（acpx Codex、acpx Claude、sol Azure `gpt-5.6-sol`），对照源码后的处理。

| 来源 | 级别 | 结论 | 处理 |
|---|---|---|---|
| acpx Codex + Claude | P1/P2 | `require(toFail:)` 没有 stored recognizer；`hideMenu()` 太晚 | **接受。** 改用 `gestureRecognizerForFailureRelationship`，扫描已有 `UILongPressGestureRecognizer` |
| acpx Codex + Claude | P2 | 触摸 row 是 screen，`.buffer` 会指错 scrollback | **接受。** 改 `.screen` |
| acpx Codex + Claude | P2 | `displayBuffer` / `lines` / `isWrapped` 非 public | **接受。** 清单不扫 buffer |
| acpx Codex | P2 | 选区菜单塞不进 SwiftTerm `UIMenuController` | **接受。** 选区改第二版 `UIEditMenuInteraction` |
| acpx Codex | P2 | 原「1–4 步就能交付」做不到 | **接受。** 最小交付缩到 hit-test + context menu |
| sol | P2 | 整行 `firstWebURL` 会在非链接格子上弹出菜单 | **接受。** 第一版不做该兜底 |
| sol | P2 | iPad `.hover` 单击仍 `requestOpenLink` | **接受。** delegate 空操作 |
| sol | P2 | 禁止对 raw PTY chunk 做 detector | **接受。** 有状态剥离器，完整行才检 |
| Claude | P3 | 硬换行有右缘阈值，不是「看起来像续写就拼」 | **接受。** §2.1 已改 |
| Claude | P3 | OSC 8 无 scheme 检查 | **接受。** 全部分支走白名单 |
| Claude | P3 | 问题陈述夸大了单击抢手势 | **接受。** §1 已改 |
| — | — | HerdrKit 抽 `firstURL` 无 AppKit 耦合 | 保留。`NSDataDetector` 是 Foundation |
