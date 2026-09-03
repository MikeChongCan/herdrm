//! A minimal VT escape-sequence filter.
//!
//! Scope: this strips escape sequences so PTY output can be shown as plain
//! text. It is deliberately **not** a terminal emulator — no cursor
//! addressing, no attributes, no alternate screen. The prototype renders a
//! scrollback of lines; a production pane would hand these bytes to
//! `alacritty_terminal` (which is what Zed's terminal does) instead.
//!
//! It is a resumable state machine because PTY reads split escape sequences at
//! arbitrary byte boundaries — an `ESC [` can land at the end of one chunk and
//! its final byte at the start of the next.

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Ground,
    /// Saw ESC, waiting to learn which kind of sequence this is.
    Escape,
    /// Inside `ESC [ … final`, where final is 0x40..=0x7e.
    Csi,
    /// Inside `ESC ] … (BEL | ESC \)` — window titles, and the APC-style
    /// markers herdr uses for attach bootstrap.
    Osc,
    /// Saw ESC while inside an OSC string: either the ST terminator or a
    /// stray ESC restarting a sequence.
    OscEscape,
    /// A two-byte sequence such as `ESC (B`; consume one more byte.
    EscapeIntermediate,
}

/// Strips escape sequences from a byte stream, preserving everything else.
#[derive(Debug, Clone)]
pub struct AnsiFilter {
    state: State,
}

impl Default for AnsiFilter {
    fn default() -> Self {
        Self::new()
    }
}

impl AnsiFilter {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
        }
    }

    /// Feeds `input`, appending the printable remainder to `out`.
    pub fn feed(&mut self, input: &[u8], out: &mut Vec<u8>) {
        for &byte in input {
            match self.state {
                State::Ground => match byte {
                    ESC => self.state = State::Escape,
                    // Drop the other C0 controls, but keep the ones that carry
                    // line structure plus tab.
                    b'\n' | b'\r' | b'\t' => out.push(byte),
                    0x00..=0x1f | 0x7f => {}
                    _ => out.push(byte),
                },
                State::Escape => match byte {
                    b'[' => self.state = State::Csi,
                    b']' => self.state = State::Osc,
                    // Intermediates: charset selection and friends.
                    b'(' | b')' | b'*' | b'+' | b'#' | b'%' => {
                        self.state = State::EscapeIntermediate
                    }
                    // ESC ESC — treat the second as the start of a new sequence.
                    ESC => self.state = State::Escape,
                    // Everything else is a complete two-byte escape.
                    _ => self.state = State::Ground,
                },
                State::EscapeIntermediate => self.state = State::Ground,
                State::Csi => {
                    // Parameter and intermediate bytes are 0x20..=0x3f;
                    // the sequence ends at the first byte in 0x40..=0x7e.
                    if (0x40..=0x7e).contains(&byte) {
                        self.state = State::Ground;
                    }
                }
                State::Osc => match byte {
                    BEL => self.state = State::Ground,
                    ESC => self.state = State::OscEscape,
                    _ => {}
                },
                State::OscEscape => {
                    // `ESC \` is ST and ends the string; anything else means
                    // the ESC began a fresh sequence.
                    if byte == b'\\' {
                        self.state = State::Ground;
                    } else {
                        self.state = State::Escape;
                    }
                }
            }
        }
    }

    /// Convenience wrapper for one-shot use.
    pub fn strip(input: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(input.len());
        AnsiFilter::new().feed(input, &mut out);
        out
    }

    /// Whether the filter is mid-sequence, i.e. waiting for more bytes.
    pub fn is_idle(&self) -> bool {
        self.state == State::Ground
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strip_str(input: &str) -> String {
        String::from_utf8(AnsiFilter::strip(input.as_bytes())).expect("utf-8")
    }

    #[test]
    fn strips_sgr_color_sequences() {
        assert_eq!(strip_str("\x1b[31mred\x1b[0m done"), "red done");
    }

    #[test]
    fn strips_cursor_hide_show_used_by_agent_spinners() {
        assert_eq!(strip_str("\x1b[?25lthinking\x1b[?25h"), "thinking");
    }

    #[test]
    fn keeps_newlines_tabs_and_carriage_returns() {
        assert_eq!(strip_str("a\tb\r\nc\n"), "a\tb\r\nc\n");
    }

    #[test]
    fn strips_osc_window_title_terminated_by_bel() {
        assert_eq!(strip_str("\x1b]0;my title\x07prompt$ "), "prompt$ ");
    }

    #[test]
    fn strips_osc_terminated_by_st() {
        assert_eq!(strip_str("\x1b]0;title\x1b\\after"), "after");
    }

    #[test]
    fn resumes_across_a_chunk_boundary_mid_csi() {
        // The PTY handed us "\x1b[3" and "1mred" in separate reads.
        let mut filter = AnsiFilter::new();
        let mut out = Vec::new();
        filter.feed(b"\x1b[3", &mut out);
        assert!(!filter.is_idle());
        filter.feed(b"1mred", &mut out);
        assert_eq!(out, b"red");
        assert!(filter.is_idle());
    }

    #[test]
    fn resumes_across_a_chunk_boundary_mid_osc() {
        let mut filter = AnsiFilter::new();
        let mut out = Vec::new();
        filter.feed(b"\x1b]0;ti", &mut out);
        filter.feed(b"tle\x07ok", &mut out);
        assert_eq!(out, b"ok");
    }

    #[test]
    fn strips_charset_selection() {
        assert_eq!(strip_str("\x1b(Btext"), "text");
    }

    #[test]
    fn drops_other_control_bytes_but_keeps_utf8() {
        // BEL alone is dropped; multi-byte UTF-8 must survive untouched.
        assert_eq!(strip_str("\x07中文 ok"), "中文 ok");
    }
}
