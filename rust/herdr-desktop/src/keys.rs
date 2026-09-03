//! Keystroke → terminal byte encoding.
//!
//! Kept free of any GPUI type so it can be unit tested without opening a
//! window; the render layer converts a `gpui::Keystroke` into [`KeyPress`] at
//! the boundary.

/// A key event, reduced to what terminal encoding actually depends on.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeyPress {
    /// The key as printed on the keycap: `"a"`, `"enter"`, `"left"`.
    pub key: String,
    /// The character this keystroke would type, when there is one.
    pub key_char: Option<String>,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
}

/// Constructors used by the tests below.
#[cfg(test)]
impl KeyPress {
    pub fn key(key: &str) -> Self {
        Self {
            key: key.to_string(),
            ..Default::default()
        }
    }

    pub fn ctrl(key: &str) -> Self {
        Self {
            key: key.to_string(),
            ctrl: true,
            ..Default::default()
        }
    }

    pub fn typed(key: &str, key_char: &str) -> Self {
        Self {
            key: key.to_string(),
            key_char: Some(key_char.to_string()),
            ..Default::default()
        }
    }
}

/// Encodes a keystroke as the bytes a PTY expects, or `None` when the key has
/// no terminal meaning (a bare modifier, say).
///
/// The sequences are the xterm defaults, which is what ConPTY speaks on Windows
/// and what every agent TUI expects on both platforms.
pub fn encode_key(press: &KeyPress) -> Option<Vec<u8>> {
    // Ctrl+key first: Ctrl+C must win over the "c" character.
    if press.ctrl {
        if let Some(bytes) = encode_ctrl(&press.key) {
            return Some(bytes);
        }
    }

    let base: Vec<u8> = match press.key.as_str() {
        "enter" | "return" => vec![b'\r'],
        "backspace" => vec![0x7f],
        "tab" if press.shift => b"\x1b[Z".to_vec(),
        "tab" => vec![b'\t'],
        "escape" => vec![0x1b],
        "space" => vec![b' '],
        "up" => b"\x1b[A".to_vec(),
        "down" => b"\x1b[B".to_vec(),
        "right" => b"\x1b[C".to_vec(),
        "left" => b"\x1b[D".to_vec(),
        "home" => b"\x1b[H".to_vec(),
        "end" => b"\x1b[F".to_vec(),
        "pageup" => b"\x1b[5~".to_vec(),
        "pagedown" => b"\x1b[6~".to_vec(),
        "delete" => b"\x1b[3~".to_vec(),
        "insert" => b"\x1b[2~".to_vec(),
        _ => {
            // A printable key: prefer what the layout says was typed, so
            // non-US keyboards and IME output survive.
            let text = press.key_char.as_deref().unwrap_or(&press.key);
            // Multi-character names like "fn" or "shift" are not text.
            if text.chars().count() != 1 {
                return None;
            }
            text.as_bytes().to_vec()
        }
    };

    // Alt/Meta prefixes with ESC, which is how agent TUIs read Alt chords.
    if press.alt {
        let mut bytes = vec![0x1b];
        bytes.extend_from_slice(&base);
        return Some(bytes);
    }

    Some(base)
}

/// Maps Ctrl chords to their C0 control codes.
fn encode_ctrl(key: &str) -> Option<Vec<u8>> {
    let mut chars = key.chars();
    let (first, rest) = (chars.next()?, chars.next());
    if rest.is_some() {
        // Named keys (Ctrl+left, …) fall through to the normal table.
        return None;
    }

    let byte = match first {
        // Ctrl+A..Ctrl+Z
        'a'..='z' => (first as u8) - b'a' + 1,
        'A'..='Z' => (first as u8) - b'A' + 1,
        '@' | ' ' => 0, // NUL
        '[' => 0x1b,    // ESC
        '\\' => 0x1c,
        ']' => 0x1d,
        '^' => 0x1e,
        '_' | '?' => 0x1f,
        _ => return None,
    };

    Some(vec![byte])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enter_sends_carriage_return_not_newline() {
        // A PTY line discipline expects CR; sending LF breaks agent TUIs.
        assert_eq!(encode_key(&KeyPress::key("enter")), Some(vec![b'\r']));
    }

    #[test]
    fn backspace_sends_del() {
        assert_eq!(encode_key(&KeyPress::key("backspace")), Some(vec![0x7f]));
    }

    #[test]
    fn arrow_keys_send_xterm_cursor_sequences() {
        assert_eq!(encode_key(&KeyPress::key("up")), Some(b"\x1b[A".to_vec()));
        assert_eq!(encode_key(&KeyPress::key("down")), Some(b"\x1b[B".to_vec()));
        assert_eq!(
            encode_key(&KeyPress::key("right")),
            Some(b"\x1b[C".to_vec())
        );
        assert_eq!(encode_key(&KeyPress::key("left")), Some(b"\x1b[D".to_vec()));
    }

    #[test]
    fn ctrl_c_sends_etx() {
        assert_eq!(encode_key(&KeyPress::ctrl("c")), Some(vec![0x03]));
    }

    #[test]
    fn ctrl_d_sends_eot() {
        assert_eq!(encode_key(&KeyPress::ctrl("d")), Some(vec![0x04]));
    }

    #[test]
    fn ctrl_is_case_insensitive() {
        assert_eq!(
            encode_key(&KeyPress::ctrl("C")),
            encode_key(&KeyPress::ctrl("c"))
        );
    }

    #[test]
    fn ctrl_bracket_sends_escape() {
        assert_eq!(encode_key(&KeyPress::ctrl("[")), Some(vec![0x1b]));
    }

    #[test]
    fn ctrl_with_a_named_key_falls_through_to_the_normal_sequence() {
        let press = KeyPress {
            key: "left".to_string(),
            ctrl: true,
            ..Default::default()
        };
        assert_eq!(encode_key(&press), Some(b"\x1b[D".to_vec()));
    }

    #[test]
    fn alt_prefixes_with_escape() {
        let press = KeyPress {
            key: "b".to_string(),
            key_char: Some("b".to_string()),
            alt: true,
            ..Default::default()
        };
        assert_eq!(encode_key(&press), Some(vec![0x1b, b'b']));
    }

    #[test]
    fn shift_tab_sends_back_tab() {
        let press = KeyPress {
            key: "tab".to_string(),
            shift: true,
            ..Default::default()
        };
        assert_eq!(encode_key(&press), Some(b"\x1b[Z".to_vec()));
    }

    #[test]
    fn printable_keys_prefer_the_typed_character() {
        // Shift+2 on a US layout: key is "2", the typed char is "@".
        assert_eq!(encode_key(&KeyPress::typed("2", "@")), Some(b"@".to_vec()));
    }

    #[test]
    fn multibyte_characters_are_encoded_as_utf8() {
        assert_eq!(
            encode_key(&KeyPress::typed("y", "中")),
            Some("中".as_bytes().to_vec())
        );
    }

    #[test]
    fn bare_modifiers_produce_nothing() {
        assert_eq!(encode_key(&KeyPress::key("shift")), None);
        assert_eq!(encode_key(&KeyPress::key("fn")), None);
    }

    #[test]
    fn space_is_a_real_character() {
        assert_eq!(encode_key(&KeyPress::key("space")), Some(vec![b' ']));
    }
}
