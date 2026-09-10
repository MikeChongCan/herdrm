#if os(macOS)
import AppKit
import GhosttyVt

public final class GhosttyTerminalView: NSView, NSTextInputClient {
    public var font: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular) {
        didSet { invalidateMetrics(); needsDisplay = true; resizeEngine() }
    }
    public var lineSpacing: CGFloat = 1 {
        didSet { invalidateMetrics(); needsDisplay = true; resizeEngine() }
    }
    public var usesLightColors = false {
        didSet { needsDisplay = true }
    }
    public var allowMouseReporting = true
    public var onExit: ((Int32?) -> Void)?
    public var shellProcessID: pid_t { pty.processID }

    private let engine = GhosttyEngine()
    private let pty = LocalPTY()
    private var frameCache: GhosttyFrame?
    private var cellSize = NSSize(width: 7, height: 16)
    private var markedTextStorage = NSMutableAttributedString()
    private var dragOrigin: (x: Int, y: Int)?
    private var lastIMECaret = NSRect.zero

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        engine.onPtyWrite = { [weak self] data in self?.pty.write(data) }
        engine.onNeedsDisplay = { [weak self] in
            self?.frameCache = nil
            self?.needsDisplay = true
        }
        pty.onData = { [weak self] data in self?.engine.feed(data) }
        pty.onExit = { [weak self] code in self?.onExit?(code) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func applyAppearance(
        font: NSFont,
        lineSpacing: CGFloat,
        dark: Bool,
        mouseReporting: Bool
    ) {
        if self.font != font {
            self.font = font
        }
        if self.lineSpacing != lineSpacing {
            self.lineSpacing = lineSpacing
        }
        usesLightColors = !dark
        allowMouseReporting = mouseReporting
        layer?.backgroundColor = (dark
            ? NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
            : NSColor.white).cgColor
        needsDisplay = true
    }

    public func startProcess(executable: String, args: [String], environment: [String]) {
        let size = engine.size
        do {
            try pty.start(
                executable: executable,
                args: args,
                environment: environment,
                cols: size.cols,
                rows: size.rows
            )
        } catch {
            onExit?(127)
        }
    }

    public func terminate() {
        pty.terminate()
    }

    public override func layout() {
        super.layout()
        resizeEngine()
    }

    public override func draw(_ dirtyRect: NSRect) {
        let frame = frameCache ?? engine.captureFrame()
        frameCache = frame
        let bg = nsColor(frame.background, light: usesLightColors)
        bg.setFill()
        bounds.fill()

        let cell = cellSize
        for (rowIndex, row) in frame.cells.enumerated() {
            for (colIndex, cellData) in row.enumerated() {
                var background = nsColor(cellData.background, light: usesLightColors)
                var foreground = nsColor(cellData.foreground, light: usesLightColors)
                if cellData.selected {
                    swap(&background, &foreground)
                }
                let rect = NSRect(
                    x: CGFloat(colIndex) * cell.width,
                    y: CGFloat(rowIndex) * cell.height,
                    width: cell.width,
                    height: cell.height
                )
                background.setFill()
                rect.fill()
                if !cellData.text.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: cellData.bold
                            ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                            : font,
                        .foregroundColor: foreground,
                    ]
                    (cellData.text as NSString).draw(in: rect, withAttributes: attrs)
                }
            }
        }

        if frame.cursorVisible, let cursor = frame.cursor {
            let rect = NSRect(
                x: CGFloat(cursor.x) * cell.width,
                y: CGFloat(cursor.y) * cell.height,
                width: max(1, cell.width * 0.15),
                height: cell.height
            )
            NSColor.controlAccentColor.setFill()
            rect.fill()
            lastIMECaret = rect
        }
    }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            interpretKeyEvents([event])
            return
        }
        if inputContext?.handleEvent(event) == true {
            return
        }
        guard let payload = MacKeys.payload(from: event) else { return }
        pty.write(engine.encodeKey(event: payload))
    }

    @objc public func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            engine.pasteText(text)
        }
    }

    @objc public func copy(_ sender: Any?) {
        guard let text = engine.copySelection() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public override func selectAll(_ sender: Any?) {
        engine.select(from: (0, 0), to: (max(0, engine.size.cols - 1), max(0, engine.size.rows - 1)))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let cell = cellAt(event)
        if event.modifierFlags.contains(.shift) || event.clickCount > 1 {
            dragOrigin = dragOrigin ?? cell
            engine.select(from: dragOrigin ?? cell, to: cell)
            return
        }
        engine.clearSelection()
        dragOrigin = cell
    }

    public override func mouseDragged(with event: NSEvent) {
        let cell = cellAt(event)
        if let origin = dragOrigin {
            engine.select(from: origin, to: cell)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        super.mouseUp(with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        let steps = Int((event.scrollingDeltaY / max(1, cellSize.height)).rounded(.towardZero))
        guard steps != 0 else { return }
        let key: GhosttyKey = steps > 0 ? GHOSTTY_KEY_PAGE_UP : GHOSTTY_KEY_PAGE_DOWN
        let payload = NSEventKeyPayload(key: key, mods: 0, utf8: nil, repeat: false)
        for _ in 0..<min(8, abs(steps)) {
            pty.write(engine.encodeKey(event: payload))
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Paste"), action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: NSTextInputClient

    public func hasMarkedText() -> Bool { markedTextStorage.length > 0 }

    public func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedTextStorage.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = attributed(from: string)
        markedTextStorage = NSMutableAttributedString(attributedString: text)
        needsDisplay = true
    }

    public func unmarkText() {
        markedTextStorage = NSMutableAttributedString()
        needsDisplay = true
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local = lastIMECaret.width > 0 ? lastIMECaret : NSRect(origin: .zero, size: cellSize)
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        unmarkText()
        let text = attributed(from: string).string
        guard !text.isEmpty else { return }
        engine.pasteText(text)
    }

    public override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            let payload = NSEventKeyPayload(key: GHOSTTY_KEY_ENTER, mods: 0, utf8: nil, repeat: false)
            pty.write(engine.encodeKey(event: payload))
        }
    }

    private func attributed(from value: Any) -> NSAttributedString {
        switch value {
        case let text as NSAttributedString: return text
        case let text as String: return NSAttributedString(string: text)
        case let text as NSString: return NSAttributedString(string: text as String)
        default: return NSAttributedString()
        }
    }

    private func cellAt(_ event: NSEvent) -> (x: Int, y: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let x = max(0, min(engine.size.cols - 1, Int(point.x / max(1, cellSize.width))))
        let y = max(0, min(engine.size.rows - 1, Int(point.y / max(1, cellSize.height))))
        return (x, y)
    }

    private func invalidateMetrics() {
        let glyph = font.glyph(withName: "W")
        var width = font.advancement(forGlyph: glyph).width
        if width < 1 {
            width = ("W" as NSString).size(withAttributes: [.font: font]).width
        }
        let height = font.ascender - font.descender + font.leading
        cellSize = NSSize(width: max(1, width), height: max(1, height * lineSpacing))
    }

    private func resizeEngine() {
        invalidateMetrics()
        let cols = max(1, Int(bounds.width / cellSize.width))
        let rows = max(1, Int(bounds.height / cellSize.height))
        engine.resize(
            cols: cols,
            rows: rows,
            cellWidth: Int(cellSize.width.rounded()),
            cellHeight: Int(cellSize.height.rounded())
        )
        pty.resize(
            cols: cols,
            rows: rows,
            cellWidth: Int(cellSize.width.rounded()),
            cellHeight: Int(cellSize.height.rounded())
        )
    }

    private func nsColor(_ rgb: GhosttyRGB, light: Bool) -> NSColor {
        var color = rgb
        if light {
            let luminance = 0.2126 * Double(rgb.r) + 0.7152 * Double(rgb.g) + 0.0722 * Double(rgb.b)
            if luminance > 140 {
                let offset = 255 - 2 * luminance
                color = GhosttyRGB(
                    r: UInt8(min(255, max(0, Double(rgb.r) + offset))),
                    g: UInt8(min(255, max(0, Double(rgb.g) + offset))),
                    b: UInt8(min(255, max(0, Double(rgb.b) + offset)))
                )
            }
        }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }
}
#endif
