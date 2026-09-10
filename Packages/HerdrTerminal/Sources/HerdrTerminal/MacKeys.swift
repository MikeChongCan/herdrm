#if os(macOS)
import AppKit
import GhosttyVt

enum MacKeys {
    static func payload(from event: NSEvent) -> NSEventKeyPayload? {
        let key = ghosttyKey(for: event.keyCode)
        var mods: GhosttyMods = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        if flags.contains(.capsLock) { mods |= GhosttyMods(GHOSTTY_MODS_CAPS_LOCK) }

        var utf8: String?
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            let scalar = characters.unicodeScalars.first?.value ?? 0
            if scalar >= 32, scalar < 127 {
                utf8 = characters
            }
        }
        return NSEventKeyPayload(key: key, mods: mods, utf8: utf8, repeat: event.isARepeat)
    }

    static func ghosttyKey(for keyCode: UInt16) -> GhosttyKey {
        switch keyCode {
        case 0: return GHOSTTY_KEY_A
        case 1: return GHOSTTY_KEY_S
        case 2: return GHOSTTY_KEY_D
        case 3: return GHOSTTY_KEY_F
        case 4: return GHOSTTY_KEY_H
        case 5: return GHOSTTY_KEY_G
        case 6: return GHOSTTY_KEY_Z
        case 7: return GHOSTTY_KEY_X
        case 8: return GHOSTTY_KEY_C
        case 9: return GHOSTTY_KEY_V
        case 11: return GHOSTTY_KEY_B
        case 12: return GHOSTTY_KEY_Q
        case 13: return GHOSTTY_KEY_W
        case 14: return GHOSTTY_KEY_E
        case 15: return GHOSTTY_KEY_R
        case 16: return GHOSTTY_KEY_Y
        case 17: return GHOSTTY_KEY_T
        case 18: return GHOSTTY_KEY_DIGIT_1
        case 19: return GHOSTTY_KEY_DIGIT_2
        case 20: return GHOSTTY_KEY_DIGIT_3
        case 21: return GHOSTTY_KEY_DIGIT_4
        case 22: return GHOSTTY_KEY_DIGIT_6
        case 23: return GHOSTTY_KEY_DIGIT_5
        case 24: return GHOSTTY_KEY_EQUAL
        case 25: return GHOSTTY_KEY_DIGIT_9
        case 26: return GHOSTTY_KEY_DIGIT_7
        case 27: return GHOSTTY_KEY_MINUS
        case 28: return GHOSTTY_KEY_DIGIT_8
        case 29: return GHOSTTY_KEY_DIGIT_0
        case 30: return GHOSTTY_KEY_BRACKET_RIGHT
        case 31: return GHOSTTY_KEY_O
        case 32: return GHOSTTY_KEY_U
        case 33: return GHOSTTY_KEY_BRACKET_LEFT
        case 34: return GHOSTTY_KEY_I
        case 35: return GHOSTTY_KEY_P
        case 36: return GHOSTTY_KEY_ENTER
        case 37: return GHOSTTY_KEY_L
        case 38: return GHOSTTY_KEY_J
        case 39: return GHOSTTY_KEY_QUOTE
        case 40: return GHOSTTY_KEY_K
        case 41: return GHOSTTY_KEY_SEMICOLON
        case 42: return GHOSTTY_KEY_BACKSLASH
        case 43: return GHOSTTY_KEY_COMMA
        case 44: return GHOSTTY_KEY_SLASH
        case 45: return GHOSTTY_KEY_N
        case 46: return GHOSTTY_KEY_M
        case 47: return GHOSTTY_KEY_PERIOD
        case 48: return GHOSTTY_KEY_TAB
        case 49: return GHOSTTY_KEY_SPACE
        case 50: return GHOSTTY_KEY_BACKQUOTE
        case 51: return GHOSTTY_KEY_BACKSPACE
        case 53: return GHOSTTY_KEY_ESCAPE
        case 76: return GHOSTTY_KEY_NUMPAD_ENTER
        case 96: return GHOSTTY_KEY_F5
        case 97: return GHOSTTY_KEY_F6
        case 98: return GHOSTTY_KEY_F7
        case 99: return GHOSTTY_KEY_F3
        case 100: return GHOSTTY_KEY_F8
        case 101: return GHOSTTY_KEY_F9
        case 103: return GHOSTTY_KEY_F11
        case 109: return GHOSTTY_KEY_F10
        case 111: return GHOSTTY_KEY_F12
        case 118: return GHOSTTY_KEY_F4
        case 120: return GHOSTTY_KEY_F2
        case 122: return GHOSTTY_KEY_F1
        case 123: return GHOSTTY_KEY_ARROW_LEFT
        case 124: return GHOSTTY_KEY_ARROW_RIGHT
        case 125: return GHOSTTY_KEY_ARROW_DOWN
        case 126: return GHOSTTY_KEY_ARROW_UP
        case 115: return GHOSTTY_KEY_HOME
        case 119: return GHOSTTY_KEY_END
        case 116: return GHOSTTY_KEY_PAGE_UP
        case 121: return GHOSTTY_KEY_PAGE_DOWN
        case 117: return GHOSTTY_KEY_DELETE
        default: return GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}
#endif
