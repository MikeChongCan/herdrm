#if os(macOS)
import Darwin
import Foundation
import GhosttyVt

private func ghosttyWritePtyTrampoline(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ len: Int
) {
    guard let userdata, let bytes, len > 0 else { return }
    let engine = Unmanaged<GhosttyEngine>.fromOpaque(userdata).takeUnretainedValue()
    engine.onPtyWrite?(Data(bytes: bytes, count: len))
}

struct GhosttyRGB {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

struct GhosttyCell {
    var text: String
    var foreground: GhosttyRGB
    var background: GhosttyRGB
    var selected: Bool
    var bold: Bool
}

struct GhosttyFrame {
    var cols: Int
    var rows: Int
    var background: GhosttyRGB
    var foreground: GhosttyRGB
    var cells: [[GhosttyCell]]
    var cursor: (x: Int, y: Int)?
    var cursorVisible: Bool
}

/// Owns a libghostty-vt terminal, key encoder, and render snapshot.
final class GhosttyEngine {
    private(set) var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?
    private var keyEncoder: GhosttyKeyEncoder?
    private var keyEvent: GhosttyKeyEvent?
    private var cols: UInt16
    private var rows: UInt16

    var onPtyWrite: ((Data) -> Void)?
    var onNeedsDisplay: (() -> Void)?

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = UInt16(max(1, cols))
        self.rows = UInt16(max(1, rows))
        var terminal: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &terminal, self.cols, self.rows) == GHOSTTY_SUCCESS,
              let terminal
        else { return }
        self.terminal = terminal

        let userdata = Unmanaged.passUnretained(self).toOpaque()
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)
        _ = ghostty_terminal_set(
            terminal,
            GHOSTTY_TERMINAL_OPT_WRITE_PTY,
            unsafeBitCast(ghosttyWritePtyTrampoline as GhosttyTerminalWritePtyFn, to: UnsafeRawPointer.self)
        )

        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &mode)

        var state: GhosttyRenderState?
        if ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS {
            renderState = state
        }
        var iterator: GhosttyRenderStateRowIterator?
        if ghostty_render_state_row_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS {
            rowIterator = iterator
        }
        var cells: GhosttyRenderStateRowCells?
        if ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS {
            rowCells = cells
        }
        var encoder: GhosttyKeyEncoder?
        if ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS {
            keyEncoder = encoder
        }
        var event: GhosttyKeyEvent?
        if ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS {
            keyEvent = event
        }
    }

    deinit {
        if let keyEvent { ghostty_key_event_free(keyEvent) }
        if let keyEncoder { ghostty_key_encoder_free(keyEncoder) }
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
    }

    var size: (cols: Int, rows: Int) { (Int(cols), Int(rows)) }

    func feed(_ data: Data) {
        guard let terminal, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base, raw.count)
        }
        if let encoder = keyEncoder {
            ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
        }
        onNeedsDisplay?()
    }

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        let nextCols = UInt16(max(1, cols))
        let nextRows = UInt16(max(1, rows))
        guard let terminal else { return }
        guard nextCols != self.cols || nextRows != self.rows else { return }
        _ = ghostty_terminal_resize(
            terminal,
            nextCols,
            nextRows,
            UInt32(max(1, cellWidth)),
            UInt32(max(1, cellHeight))
        )
        self.cols = nextCols
        self.rows = nextRows
        onNeedsDisplay?()
    }

    func encodeKey(event: NSEventKeyPayload) -> Data {
        guard let terminal, let keyEncoder, let keyEvent else { return Data() }
        ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)
        ghostty_key_event_set_action(keyEvent, event.repeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(keyEvent, event.key)
        ghostty_key_event_set_mods(keyEvent, event.mods)
        if let utf8 = event.utf8, !utf8.isEmpty {
            utf8.withCString { ghostty_key_event_set_utf8(keyEvent, $0, strlen($0)) }
        } else {
            ghostty_key_event_set_utf8(keyEvent, nil, 0)
        }
        var buffer = [CChar](repeating: 0, count: 256)
        var written = 0
        let result = buffer.withUnsafeMutableBufferPointer { ptr in
            ghostty_key_encoder_encode(keyEncoder, keyEvent, ptr.baseAddress, ptr.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return Data() }
        return Data(bytes: buffer, count: written)
    }

    func pasteText(_ text: String) {
        guard let terminal else { return }
        let payload = text.replacingOccurrences(of: "\n", with: "\r")
        var bytes = Array(payload.utf8)
        var written = 0
        var encoded = [CChar](repeating: 0, count: max(64, bytes.count * 2 + 16))
        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2004, false), value: false)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode)
        let result = bytes.withUnsafeMutableBufferPointer { src in
            encoded.withUnsafeMutableBufferPointer { dst in
                ghostty_paste_encode(
                    src.baseAddress.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    src.count,
                    mode.value,
                    dst.baseAddress,
                    dst.count,
                    &written
                )
            }
        }
        if result == GHOSTTY_SUCCESS, written > 0 {
            onPtyWrite?(Data(bytes: encoded, count: written))
            return
        }
        onPtyWrite?(Data(bytes))
        _ = terminal
    }

    func copySelection() -> String? {
        guard let terminal else { return nil }
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        options.selection = nil
        var pointer: UnsafeMutablePointer<UInt8>?
        var length: Int = 0
        let result = ghostty_terminal_selection_format_alloc(terminal, nil, options, &pointer, &length)
        defer {
            if let pointer {
                ghostty_free(nil, pointer, length)
            }
        }
        guard result == GHOSTTY_SUCCESS, let pointer, length > 0 else { return nil }
        return String(bytes: UnsafeBufferPointer(start: pointer, count: length), encoding: .utf8)
    }

    func select(from start: (x: Int, y: Int), to end: (x: Int, y: Int)) {
        guard let terminal else { return }
        var startRef = GhosttyGridRef()
        startRef.size = MemoryLayout<GhosttyGridRef>.size
        let startPoint = ghosttyPoint(tag: GHOSTTY_POINT_TAG_VIEWPORT, x: start.x, y: start.y)
        guard ghostty_terminal_grid_ref(terminal, startPoint, &startRef) == GHOSTTY_SUCCESS else { return }

        var endRef = GhosttyGridRef()
        endRef.size = MemoryLayout<GhosttyGridRef>.size
        let endPoint = ghosttyPoint(tag: GHOSTTY_POINT_TAG_VIEWPORT, x: end.x, y: end.y)
        guard ghostty_terminal_grid_ref(terminal, endPoint, &endRef) == GHOSTTY_SUCCESS else { return }

        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = startRef
        selection.end = endRef
        selection.rectangle = false
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        onNeedsDisplay?()
    }

    func clearSelection() {
        guard let terminal else { return }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        onNeedsDisplay?()
    }

    func captureFrame() -> GhosttyFrame {
        let empty = GhosttyRGB(r: 16, g: 16, b: 18)
        let fallbackFG = GhosttyRGB(r: 214, g: 214, b: 214)
        var frame = GhosttyFrame(
            cols: Int(cols),
            rows: Int(rows),
            background: empty,
            foreground: fallbackFG,
            cells: [],
            cursor: nil,
            cursorVisible: false
        )
        guard let terminal, let renderState, let rowIterator, let cellsHandle = rowCells else { return frame }
        _ = ghostty_render_state_update(renderState, terminal)

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        if ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors) == GHOSTTY_SUCCESS {
            frame.background = GhosttyRGB(r: colors.background.r, g: colors.background.g, b: colors.background.b)
            frame.foreground = GhosttyRGB(r: colors.foreground.r, g: colors.foreground.g, b: colors.foreground.b)
        }

        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        if ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor) == GHOSTTY_SUCCESS,
           cursor.viewport_has_value
        {
            frame.cursor = (Int(cursor.viewport_x), Int(cursor.viewport_y))
            frame.cursorVisible = cursor.visible
        }

        var iterator = rowIterator
        if ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) != GHOSTTY_SUCCESS {
            return frame
        }

        var rows: [[GhosttyCell]] = []
        rows.reserveCapacity(Int(self.rows))
        while ghostty_render_state_row_iterator_next(iterator) {
            var row: [GhosttyCell] = []
            row.reserveCapacity(Int(self.cols))
            var cells = cellsHandle
            if ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) != GHOSTTY_SUCCESS {
                continue
            }
            while ghostty_render_state_row_cells_next(cells) {
                var selected = false
                _ = ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED,
                    &selected
                )
                var fg = GhosttyColorRgb(r: frame.foreground.r, g: frame.foreground.g, b: frame.foreground.b)
                if ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                    &fg
                ) != GHOSTTY_SUCCESS {
                    fg = GhosttyColorRgb(r: frame.foreground.r, g: frame.foreground.g, b: frame.foreground.b)
                }
                var bg = GhosttyColorRgb(r: frame.background.r, g: frame.background.g, b: frame.background.b)
                if ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                    &bg
                ) != GHOSTTY_SUCCESS {
                    bg = GhosttyColorRgb(r: frame.background.r, g: frame.background.g, b: frame.background.b)
                }
                var utf8 = GhosttyBuffer()
                var storage = [UInt8](repeating: 0, count: 64)
                let text: String = storage.withUnsafeMutableBufferPointer { ptr in
                    utf8.ptr = ptr.baseAddress
                    utf8.cap = ptr.count
                    utf8.len = 0
                    let result = ghostty_render_state_row_cells_get(
                        cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                        &utf8
                    )
                    if result == GHOSTTY_SUCCESS, utf8.len > 0 {
                        return String(bytes: UnsafeBufferPointer(start: ptr.baseAddress, count: utf8.len), encoding: .utf8) ?? ""
                    }
                    return ""
                }
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                _ = ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                    &style
                )
                row.append(
                    GhosttyCell(
                        text: text,
                        foreground: GhosttyRGB(r: fg.r, g: fg.g, b: fg.b),
                        background: GhosttyRGB(r: bg.r, g: bg.g, b: bg.b),
                        selected: selected,
                        bold: style.bold
                    )
                )
            }
            rows.append(row)
        }
        _ = ghostty_render_state_clean(renderState)
        frame.cells = rows
        return frame
    }

    private func ghosttyPoint(tag: GhosttyPointTag, x: Int, y: Int) -> GhosttyPoint {
        var point = GhosttyPoint()
        point.tag = tag
        point.value.coordinate.x = UInt16(max(0, x))
        point.value.coordinate.y = UInt32(max(0, y))
        return point
    }
}

struct NSEventKeyPayload {
    var key: GhosttyKey
    var mods: GhosttyMods
    var utf8: String?
    var `repeat`: Bool
}
#endif
