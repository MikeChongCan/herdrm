# Competitive research: iOS AI composer + voice (2026)

Researched 2026-09-06 for HerdrMobile input-chrome redesign.
HerdrMobile is a **remote agent terminal**, not a chat app. Closest analog is ChatGPT Codex Remote (iOS controlling a Mac agent), not ChatGPT Chat.

## Industry consensus (ChatGPT, Claude, Grok, Gemini)

Every major AI iOS app now splits **two different voice jobs**:

| Job | Affordance | What happens | Output |
|---|---|---|---|
| **Dictation** | Mic in the message box | Speech → editable text in the same composer | User reviews, then Send |
| **Voice conversation** | Waveform / Live, separate from mic | Spoken back-and-forth; often transforms the bar | Audio (+ transcript in the same thread) |

They do **not** stack: system keyboard + custom keybar + empty extra text box + a third dictation strip.

### ChatGPT iOS (primary reference)

- One composer pill at the bottom. Mic (dictation) and waveform (Voice) are distinct.
- Widgets and Codex Remote shortcuts list **Dictation** and **Voice** as separate actions (Chat / Work / Remote).
- Nov 2025: Voice is no longer a separate orb screen; it stays inside the chat so you can see answers, images, history. You still tap End to leave Voice.
- Long-press mic → instant Voice conversation (hidden shortcut). Tap mic → dictation into the box.
- Codex Remote (MacStories, Aug 2026): iPhone dictation/voice can drive a **remote Mac agent**. This is the closest product analog to HerdrMobile. Federico notes icon collision between cloud Voice and Remote Voice is already confusing — do not copy that mistake.
- 2026 complaint: some mobile dictation auto-sends on pause. We must keep **edit-before-send**.

### Claude iOS (clearest product language)

Anthropic's own tutorial: *dictation is typing with your voice; voice mode is a conversation*.

- Dictation: mic **in the message box**. On phone: **hold while talking, release to send** (desktop: tap, speak, send when ready).
- Voice mode: **separate waveform** next to the mic. Spoken conversation, interrupt, optional push-to-talk.
- Speech becomes text in the box so you can look it over before send.
- Widget: chat / dictation-mode / camera. Dictation opens the app already listening.

### Grok composer teardown (AI UX Playground, Jun 2026)

- Default bar: `+` left, mic + waveform right. Calm, one pill.
- **Inline dictation**: listening replaces the right rail with waveform + checkmark. Stay on the same page. No full-screen handoff for a short utterance.
- **Voice session**: bar transforms (Stop, persona). Lesson: differentiate mic vs conversation **on the default state**, not only after tap.
- Send appears as a filled arrow once there is content. Ready-to-send state is explicit.

### Gemini iOS

- Mic in the text field = speech-to-text into the composer (turn-based).
- Live is a separate conversation mode (stronger on Android with camera).
- Same split: dictation vs Live. Do not mix them.

## What this means for HerdrMobile

HerdrMobile should implement **dictation**, not ChatGPT/Claude **voice conversation**. The agent already talks in the PTY. Bidirectional phone voice would fight the agent's TUI.

Copy these patterns:

1. **One composer.** Never two text boxes (native + empty + agent's TUI is already one too many; we cannot hide the PTY composer, so we must not add a second always-visible native box).
2. **Dictation is a state of the composer**, not a sibling strip. Mic lives in the same pill. Listening replaces the right-side controls (Grok pattern).
3. **Hold-to-talk on phone** (Claude mobile) plus tap-to-toggle (already in our VoiceInputBar). Edit before send. Never auto-send on pause.
4. **System keyboard belongs to that composer only.** Special keys (esc, tab, arrows, ^C) become that field's `inputAccessoryView`, not a second always-on bar plus SwiftTerm's accessory.
5. **Do not ship Voice Mode** in this redesign (waveform / spoken agent). If we ever do, it is a separate control with a different icon, never the same mic.
6. **One keyboard toggle.** ChatGPT does not have a keyboard button in the chrome; the composer focus shows the system keyboard. We still need an explicit keyboard button because the terminal is display-first and we currently hide the keyboard on purpose.

## Current HerdrMobile stacking (from screenshot + code)

`Sources/HerdrMobile/MobileTerminalView.swift` `controls`:

```
keyBar (esc tab ↑↓ ⏎ ^C paste keyboard)
composer (VoiceComposerField, always shown for agent panes)
VoiceBarHost ("Tap to dictate" + another keyboard button)
[+ SwiftTerm TerminalAccessory when TerminalView is first responder]
[+ iOS system keyboard]
[+ agent TUI composer inside the PTY]
```

CHANGELOG Unreleased already tried: docked mic strip, not custom `inputView`; finals go to focused terminal else composer; keyboard button force-shows/hides. That created the stack.

SwiftTerm accessory: `iOSAccessoryView.swift` `TerminalAccessory` (esc, ctrl, ~, |, /, -, F1, arrows, touch, keyboard). Appears as `inputAccessoryView` of `TerminalView`.

Send path: `agent.prompt` for composer; `pane.send_input` for key chips; raw PTY if SwiftTerm is first responder.

## Recommended interaction model (for the design doc to refine)

**Agent pane default** (no keyboard, no empty box):

```
[ terminal — display-first ]
[ compact chrome:  ^C  esc  ⋯keys |  🎤  ⌨️  📎 ]
```

- 🎤 tap = start/stop dictation; hold = talk until release. Draft line appears only with partials or unsent text. Send via `agent.prompt`.
- ⌨️ = focus the (same) draft field, show system keyboard, move key chips into that field's accessory, hide SwiftTerm accessory (`inputAccessoryView = nil` on agent panes).
- Empty draft + keyboard dismissed = chrome collapses to the compact bar.
- Dictation finals always insert into the native draft, never into SwiftTerm, for agent panes. (Avoid dual destination.)

**Bare shell pane:** no `agent.prompt`. SwiftTerm + its accessory is the input. Mic inserts into the PTY. No native composer.

## Non-goals drawn from competitors

- Do not build duplex Voice Mode / Live Activities / spoken agent replies.
- Do not replace the system keyboard with a custom `inputView`.
- Do not auto-send on silence (ChatGPT 2026 regression).
- Do not use the same icon for dictation and a future voice conversation.
