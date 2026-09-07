# HerdrMobile：把按键直接打进 SwiftTerm（已实施）

| 字段 | 值 |
|---|---|
| **日期** | 2026-09-07 |
| **状态** | 已决定并实施 |
| **范围** | `HerdrMobile`（`Sources/HerdrMobile`）。macOS `HerdrM` 不需要这件事 |
| **相关** | 未提交的输入条改造（`docs/ios-mobile-input-chrome.md`）、Gemini 听写 IME |

---

## 结论（先看这个）

**已实施。** SwiftTerm 的 iOS `TerminalView` 本身就是 `UITextInput` /
first responder。Shell pane 保持点终端 → 系统键盘 → 字进 PTY；agent pane
现在可在 composer 和 PTY 两个目标之间切换。

你要的是第二种输入，不是替换现在的 composer：

| 模式 | 焦点 | 回车 / 发送后发生什么 |
|---|---|---|
| **Composer（现有）** | 底下语音/文本框 | `agent.prompt`：当作一条发给 agent 的 prompt |
| **PTY（新需求）** | 上面的 SwiftTerm | 字符、`/command`、`y`/`n` 进 agent 自己的 TUI，**不自动当 prompt 提交** |

这两条路使用已有 RPC：`session.prompt` → `agent.prompt`；
`session.sendText` / `session.sendKeys` → `pane.send_input`。本次实现让
agent SwiftTerm 可以成为打字焦点，并把键盘事件接到第二条路。

---

## 已实施的输入模型

仓库里 **macOS `HerdrM` 没有 composer、没有语音条**。右侧就是完整可打字的 SwiftTerm（`herdr agent attach`）。这次需求对应的是 **iOS HerdrMobile**。

已提交的 iOS 线（`git log`）：首版 SSH 客户端、前后台重连、触控滚动、终端路径长按 / Quick Look。

实现保留 display-first composer，同时恢复 agent TUI 的直接输入：

- `MobileTerminalView.swift` 以 `ptyIsTypingTarget` 表示 agent 的 PTY
  typing focus；点 PTY 会成为 SwiftTerm first responder。
- Agent PTY 的 `insertText` 发 `pane.send_input` text；Return 与 Backspace
  分别发 named `enter` / `backspace` keys；delegate 不会将 agent bytes 写进
  attach channel。
- PTY focus 使用 `HerdrInputAccessory`，composer 在 PTY 输入时保持收起。
- 空 composer 高度 0；🎤 在 compact / accessory 上；听写按 first responder
  路由。
- 发送：点发送 = `agent.prompt`；长按「Send without newline」= `pane.send_input` `text`（**不带回车**）

`docs/ios-mobile-input-chrome.md` D3 现已记录双焦点模型。

---

## 现状：三条进终端的管道

```
┌ 系统键盘 / 听写 ─────────────────────────────────────────┐
│                                                          │
│  [A] VoiceComposerField          [B] SwiftTerm           │
│      first responder                 first responder     │
│           │                               │              │
│           ├─ Send  → agent.prompt         ├─ insertText  │
│           └─ Send w/o ⏎ → pane.send_input │   → delegate │
│                              text         │     send()   │
└───────────────────────────────────────────┼──────────────┘
                                            │
                     [C] 工具条 esc/tab/⏎/^C → pane.send_input keys
                                            │
                                            ▼
                              herdr 0.8 / protocol 19
```

- **`agent.prompt`**：herdr 替你把整段提交给 agent。适合「说完一段再发」。`/compact`、`y`、agent TUI 里的 slash 菜单 **不该走这条**，否则会变成一条普通 prompt。
- **`pane.send_input` `keys`**：已经在用。服务端按 pane 的键盘协议编码，客户端不用猜 CSI。
- **`pane.send_input` `text`**：`sendText` 已实现；composer 长按发送会走它。适合把 `/help` 打进 TUI **且不按回车**。
- **PTY `channel.write`**（`session.send`）：SwiftTerm `TerminalViewDelegate.send` 的默认路径。Shell 用这条。Agent attach 的 PTY 理论上也能写，但注释明确说 agent **不要**往 attach 频道打裸字节，交给 herdr RPC。**新模式应继续用 `pane.send_input`，不要改走 PTY write。**

技术上 SwiftTerm 的光标（PTY 光标）一直在画；你要的「光标能 focus 在上面」是 **UIKit first responder + 系统键盘**，让输入进 TUI，而不是换一套渲染。

---

## 变更前为什么点上面打不进去

`MobileTerminalUIView`（SwiftTerm 子类）：

```swift
override func becomeFirstResponder() -> Bool {
    if isAgentPane {
        // … 复制手势进行中才放行
        onRequestKeyboard?()   // 打开的是底下 composer
        if !copying { return false }
    }
    return super.becomeFirstResponder()
}

override func insertText(_ text: String) {
    if isAgentPane { return }
    super.insertText(text)
}
```

Agent 上还挂了高度 0 的 dummy `inputView`，故意不弹出系统键盘。`MobileTerminalHost.updateUIView` 对 agent **从不** `becomeFirstResponder()`。

所以：**不是 SwiftTerm 弱，是产品锁。** 解开锁就能 focus。

---

## 已实施的产品模型：双焦点，而不是二选一

不要拆掉 composer / 听写。默认仍是「说完再发」。加一条 **TUI 直打**。

### 焦点怎么切

| 用户动作 | 结果 |
|---|---|
| 点 **PTY** | SwiftTerm first responder；系统键盘起来；字符走 `pane.send_input` |
| 点 **composer** / ⌨️ 打开草稿 / 开始听写（默认） | composer first responder；发送仍是 `agent.prompt` |
| 键盘收起 / 点空白收键盘 | 两边都 resign；compact 条回来 |
| 长按 PTY | 继续复制 / 链接菜单（现有） |

视觉上同一时刻只有一个 typing target。Accessory 跟焦点走：composer 焦点用 `agentAccessory`，PTY 焦点用和 shell 同一套 `shellAccessory`（🎤 + esc/tab/方向/⏎/^C）。**不要**再叠 SwiftTerm 自带 `TerminalAccessory`。

### 字符、`/command`、回车

- 普通键、`/`、字母：`pane.send_input` `text`（或逐字符 `keys`，见风险）。
- 特殊键：继续 `sendKeys`（和现在工具条一样）。
- **回车**：在 PTY 焦点下发 `enter`（`pane.send_input` keys），**不要**调 `agent.prompt`。这样 `/compact` + 回车是 TUI 命令；composer 里回车仍是发 prompt。
- Composer 长按「不带换行发送」可以留着，给「先在底下写一长串再灌进 TUI、自己决定要不要回车」的人。

### 听写跟谁

跟 first responder，不要再写死「agent 一定进 composer」：

- Composer 焦点：保持现在的 marked-text IME + undo。
- PTY 焦点：final `sendText`；partial **不要**对 SwiftTerm `setMarkedText`（上游 IME 会和 PTY 打架，input-chrome 文档已经否过）。partial 只显示在 accessory 字幕。

PTY focus 的 🎤 已按此模型实施：partial 留在 accessory caption，final
调用 `sendText`。

---

## 已解决的 chrome 计划冲突

`docs/ios-mobile-input-chrome.md` 已更新为以下行为：

- **D3 / A5**：点 PTY 可以成为 typing target。Dummy `inputView` 只在
  **复制选区 / 不要键盘** 时保留，PTY 打字时清掉以显示系统键盘。
- **Typing targets**：同一时刻一个，agent pane 内可在 composer ↔ PTY 切换。
- **听写路由**：按 first responder。
- **QA**：PTY tap = TUI 键盘；composer tap = prompt 键盘。

Display-first **作为默认发送路径**仍然对：长消息走 `agent.prompt`。Display-first **禁止 TUI 键盘** 不再对。Agent 的 slash / 确认键必须打进 TUI。

---

## 实现要点

只动 `Sources/HerdrMobile`，主要是 `MobileTerminalView.swift`、`TerminalInputChrome`、必要时 `HerdrInputAccessory`。不 vendor SwiftTerm。

1. **Agent allows `becomeFirstResponder`.** The dummy `inputView` is used only
   while SwiftTerm is first responder for copy/select; active PTY typing has a
   nil input view and the shell accessory.
2. **Tap PTY does not open composer.** It sets `ptyIsTypingTarget`; the host
   makes SwiftTerm first responder unless a selection/menu is active.
3. **Text and specials use RPC.** Agent `insertText` calls `sendText`,
   `deleteBackward` calls `sendKeys(["backspace"])`, and Return calls
   `sendKeys(["enter"])`. Hardware specials map to named keys.
4. **Raw attach bytes are shell-only.** The coordinator discards all agent
   `TerminalViewDelegate.send` data. Shell panes retain `session.send`.
5. **Composer presentation is independent.** PTY focus does not set the
   composer keyboard state, so an empty composer remains collapsed.
6. **Dictation follows focus.** Composer focus retains its marked-text IME;
   agent PTY focus keeps partials as an accessory caption and sends finals with
   `sendText`.
7. **Documentation records the decision.** `MobileAttachSession` now states
   that rendering remains attach, prompts use composer, and TUI input uses PTY
   focus plus `pane.send_input`. `CHANGELOG.md` is intentionally untouched.

不改：SSH、sidebar、macOS、`agent.prompt` 语义、链接长按、Gemini 协议。

---

## 风险

| 风险 | 说明 | 处理 |
|---|---|---|
| 又叠一层键盘条 | 正是上周截图的问题：composer + SwiftTerm accessory + compact | PTY 焦点时 accessory **只**用 `HerdrInputAccessory`，继续盖掉 `TerminalAccessory`；composer 高度 0 除非用户点框 / 听写 |
| `text` vs 逐键 | 有的 TUI 对整段 `text` 和逐字符行为不同 | 第一刀用 `sendText`；若 slash 菜单不弹出，再改成按 UTF-8 标量拆 `keys` |
| PTY write vs RPC | 混用会和 attach 状态打架 | Agent 打字只用 `pane.send_input` |
| 硬件键盘 | 焦点在 PTY 时外接键盘应进 TUI | 解开 FR 后 UIKit 会送 `insertText`；用同一拦截 |
| 复制 vs 打字 | 选区时弹出键盘会很难用 | 有 active selection / 菜单时不要 `becomeFirstResponder` 去打字；菜单结束再点一下 |
| 听写 marked text × PTY | 文档已否 | PTY 不要 `setMarkedText` |
| `agent.prompt` 误伤 | 用户以为在 TUI 里，其实发了一条 prompt | 焦点要看得出来：PTY 焦点时 composer 保持收起，不要同时亮两个光标 |

---

## 完成情况

1. **FR + `sendText` routing:** complete.
2. **Return, Backspace, hardware specials, and the shared accessory:** complete.
3. **Focus-based dictation:** complete.
4. **Chrome documentation:** updated. `CHANGELOG.md` remains outside scope.

### 手动 QA（第一刀）

- Agent：点 PTY → 系统键盘 → `y` / `n` / `/` 出现在 **上面的 TUI**，底下框仍是空的。
- `/foo` 再按键盘回车：TUI 执行命令，**没有**多一条 `agent.prompt`。
- 点底下框 → 听写或打字 → 发送：行为与现在相同（`agent.prompt`）。
- 长按 PTY：复制 / 路径菜单仍在。
- Shell：焦点和现在一样，仍走 PTY write。
- 键盘收起后 compact 🎤 / ^C 还在。

---

## 已决定的默认行为

1. **Tap PTY = TUI keyboard.** Swipe down or dismiss the keyboard exits PTY
   typing mode; no second toolbar button is needed.
2. **Dictation follows first responder.** Composer uses the existing IME. PTY
   uses only finals through `pane.send_input` text, with partials in the
   accessory caption.

实施结论：SwiftTerm 支持此行为；agent input continues to use the existing
`pane.send_input` RPC, without a protocol change or SwiftTerm fork.
