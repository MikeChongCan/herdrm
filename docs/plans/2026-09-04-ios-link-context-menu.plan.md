# Implement iOS terminal link context menu

Read `docs/ios-link-context-menu.md` for product decisions. This file is the executable spec. Do every item. Do not stop early. Phase 1 and phase 2 are both in scope.

Branch: `review/ios-link-context-menu` (already checked out). Commit here. Never push.

## Rules for the implementer

- Code only. Targeted tests only. One or two commits on the current branch. Never push.
- Do not modify SwiftTerm sources, `project.yml` lockfiles, `xcstrings`, `design/`, `rust/`, or the resume `.txt` in the repo root.
- Comments: short, factual, only for non-obvious constraints. No narration.
- Match surrounding Swift style. `String(localized:)` for user-visible strings.
- HerdrKit is Foundation-only. No UIKit/AppKit in HerdrKit.
- Apple self-check: only `cd Packages/HerdrKit && swift test --filter TerminalLinkTests`. Do not run `make build` / xcodebuild.
- Commit message must end with a line `cosigned by OpenAI Codex at M1 Max`.

## Files to touch

Create:

- `Packages/HerdrKit/Sources/HerdrKit/TerminalLink.swift`
- `Packages/HerdrKit/Tests/HerdrKitTests/TerminalLinkTests.swift`

Edit:

- `Sources/HerdrMobile/MobileTerminalView.swift`
- `Sources/HerdrM/TerminalView.swift` (`firstURL` only)
- `CHANGELOG.md` — add `## [Unreleased]` with an Added bullet for iOS long-press link menu + collected links

Do not add wrap-join logic that walks SwiftTerm buffers. Those APIs are internal.

## 1. HerdrKit — `TerminalLink.swift`

```swift
import Foundation

public enum WebURL {
    /// First http/https URL in `text` via NSDataDetector(.link).
    public static func first(in text: String) -> URL?
}

public struct WebLinkCollector: Equatable {
    public static let limit = 50
    public private(set) var urls: [URL]
    public init(urls: [URL] = [])
    /// Dedup by absoluteString. Append. If count > limit, drop the oldest.
    public mutating func add(_ url: URL)
}

public struct VisibleTextExtractor {
    public enum Event: Equatable {
        case line(String)   // a complete visible line (newline consumed, not included)
        case osc8(String)   // OSC 8 payload URI (the part after the second `;`)
    }
    public init()
    /// Feed a PTY chunk. Return events for completed lines and OSC 8 payloads.
    /// Hold a partial visible line until `\n` / `\r\n`. Do not emit mid-URL fragments.
    public mutating func consume(_ data: Data) -> [Event]
}
```

`WebURL.first`:

- `NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)`
- First match whose `url.scheme` is `http` or `https` (case-insensitive)
- Reject `ftp`, `file`, `mailto`, `javascript`, `data`, paths, phone numbers
- Empty string → nil

`VisibleTextExtractor` state machine (keep small):

- Pass through printable UTF-8
- On `0x1B`:
  - `ESC [` CSI: skip until a final byte in `@`...`~` (0x40...0x7E)
  - `ESC ]` OSC: read until BEL (`0x07`) or ST (`ESC \`)
    - If OSC body starts with `8;` parse `8;<params>;<uri>` and emit `.osc8(uri)` when uri is non-empty
    - Other OSC: discard
  - Other ESC: skip the next byte (or CSI-like if needed)
- `\n` emits `.line` of current visible buffer (even if empty skip empty lines)
- `\r` alone: treat as line start (reset current line) or ignore if followed by `\n`
- CSI color codes in the middle of a URL must not appear in the visible line

Do not detect links inside `consume`. Callers run `WebURL.first` on `.line` and `.osc8`.

## 2. Tests — `TerminalLinkTests.swift`

`@testable import HerdrKit`. Cover:

1. `https://example.com/path?q=1` → that URL
2. `http://example.com` → kept
3. `ftp://x`, `file:///tmp`, `mailto:a@b.c`, `javascript:alert(1)`, `data:text/html,x`, `/usr/bin/ls`, `foo/bar` → nil
4. Collector: add same URL twice → one entry
5. Collector: add 51 distinct https URLs → 50, first dropped, last present
6. Phone `+1 415-555-0100` and an address-like string → `WebURL.first` nil (link detector only; if NSDataDetector returns a tel: link, still reject by scheme)
7. Extractor: `"see \u{1b}[31mhttps://ex.com/a\u{1b}[0m now\n"` → one `.line` containing `https://ex.com/a` without CSI, and `WebURL.first` finds it
8. Extractor: OSC 8 `ESC ]8;;https://ex.com/doc BEL docs ESC ]8;; BEL \n` → `.osc8("https://ex.com/doc")` and visible line `docs`
9. Extractor: feed `"https://ex.com/ab"` then `"cd\n"` in two consume calls → no event after first; after second one `.line("https://ex.com/abcd")`
10. Extractor: long URL with no newline stays unpublished until `\n`

## 3. macOS `Sources/HerdrM/TerminalView.swift`

Replace `static func firstURL(in:)` body with `WebURL.first(in: text)`. Keep the method so call sites stay. Import HerdrKit if not already imported (it is).

## 4. iOS `MobileTerminalView.swift`

### 4.1 `requestOpenLink`

Empty body. Do not open URLs here. iPad pointer tap must not open.

### 4.2 `MobileTerminalUIView`

After `super.init` / `setupTouchScrolling`, install context menu:

```swift
let interaction = UIContextMenuInteraction(delegate: self)
addInteraction(interaction)
if let menuGR = interaction.gestureRecognizerForFailureRelationship {
    for case let lp as UILongPressGestureRecognizer in gestureRecognizers ?? []
    where lp !== menuGR {
        lp.require(toFail: menuGR)
    }
}
```

Do not make the pan gesture `require(toFail:)` the menu GR.

Conform to `UIContextMenuInteractionDelegate` in this class (not the SwiftUI coordinator).

Hit-test (screen coordinates, not `.buffer`):

```swift
func webURL(at location: CGPoint) -> URL? {
    let terminal = getTerminal()
    let cols = max(1, terminal.cols)
    let rows = max(1, terminal.rows)
    let col = max(0, min(cols - 1, Int(location.x / max(1, bounds.width / CGFloat(cols)))))
    let row = max(0, min(rows - 1, Int(location.y / max(1, bounds.height / CGFloat(rows)))))
    guard let raw = terminal.link(
        at: .screen(Position(col: col, row: row)),
        mode: .explicitAndImplicit
    ) else { return nil }
    return WebURL.first(in: raw) ?? {
        // OSC 8 payload may already be a full URL string
        URL(string: raw).flatMap { url in
            (url.scheme == "http" || url.scheme == "https") ? url : nil
        }
    }()
}
```

If `WebURL.first(in: raw)` already accepts a bare `https://...` string, skip the extra `URL(string:)` branch. Prefer one helper: `WebURL.first(in: raw)` is enough when `raw` is the URL itself.

`configurationForMenuAtLocation`:

- `webURL(at: location)` nil → return nil (Select long-press still works)
- else `UIContextMenuConfiguration` with a small preview (one-line URL label, not the whole terminal) and actions:
  - Open → `UIApplication.shared.open`
  - Copy → `UIPasteboard.general.string = url.absoluteString`
  - Share → `UIActivityViewController` from the nearest `UIViewController` (`sequence` of next responder) or the window's root; if none, skip Share

Do not fall back to `WebURL.first` on a whole logical line.

### 4.3 Session collector (phase 2)

On `MobileAttachSession`:

```swift
@Published private(set) var collectedLinks: [URL] = []
private var textExtractor = VisibleTextExtractor()
private var linkCollector = WebLinkCollector()
```

In `feed(_:)`: `consume` then `linkCollector.add` for each `.line` / `.osc8` that yields `WebURL.first`. Assign `collectedLinks = linkCollector.urls`. Then existing `terminalView?.feed`.

Reconnect must keep links. `onDisappear` must clear.

Today `restart()` calls `stop()`. Do not clear collector inside `stop()`. Add:

```swift
func discardCollectedLinks() {
    textExtractor = VisibleTextExtractor()
    linkCollector = WebLinkCollector()
    collectedLinks = []
}
```

Call `discardCollectedLinks()` from `MobileTerminalScreen.onDisappear` together with `session.stop()`. Do not call it from `restart()`.

### 4.4 Key bar chip (phase 2)

In `keyBar` HStack, if `!session.collectedLinks.isEmpty`, a chip showing `link` (or `link · N`) that presents a sheet listing URLs. Row tap opens; swipe/context: copy is fine. Use `@State private var showingLinks = false`.

### 4.5 Selection edit menu (phase 2)

Add `UIEditMenuInteraction` to `MobileTerminalUIView`. When `selection.active`, if `WebURL.first(in: selection.getSelectedText())` is non-nil, include Open / Copy / Share in `editMenuInteraction(_:menuFor:suggestedActions:)` (or the iOS 16 configuration API). If the selection is a partial URL and `WebURL.first` is nil, do not add link actions. Do not assign `UIMenuController.shared.menuItems`.

## 5. CHANGELOG

Insert at the top of the version list:

```
## [Unreleased]

### Added
- iOS: long-press a terminal URL for the system context menu (Open / Copy / Share).
  Soft-wrapped links resolve as one URL. Attach sessions also collect http(s) links
  into a key-bar list. Taps no longer open links.
```

## 6. Self-check

```
cd Packages/HerdrKit && swift test --filter TerminalLinkTests
```

Must be green. If compile errors in HerdrMobile/HerdrM, fix them; do not run xcodebuild.

## 7. Commit

```
feat(mobile): long-press terminal links for Open/Copy/Share

cosigned by OpenAI Codex at M1 Max
```

Do not push.
