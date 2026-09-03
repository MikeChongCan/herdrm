//! Design tokens, tracking the HerdrM canvas (waku-style sidebar, dark).

use gpui::{rgb, Rgba};

pub const BG: u32 = 0x14161a;
pub const SIDEBAR_BG: u32 = 0x1a1d23;
pub const HEADER_BG: u32 = 0x181b21;
pub const BORDER: u32 = 0x272b33;
pub const ROW_HOVER: u32 = 0x22262e;
pub const ROW_SELECTED: u32 = 0x2b303a;

pub const TEXT: u32 = 0xe6e8eb;
pub const TEXT_MUTED: u32 = 0x8b929e;
pub const TEXT_FAINT: u32 = 0x5c636e;
pub const ACCENT: u32 = 0x7aa2f7;

pub const STATUS_BLOCKED: u32 = 0xf7768e;
pub const STATUS_DONE: u32 = 0x9ece6a;
pub const STATUS_WORKING: u32 = 0xe0af68;
pub const STATUS_IDLE: u32 = 0x565f89;

pub fn color(value: u32) -> Rgba {
    rgb(value)
}

/// The dot color for a status bucket.
pub fn status_color(status: herdr_bridge_core::AgentStatus) -> Rgba {
    use herdr_bridge_core::AgentStatus::*;
    rgb(match status {
        Blocked => STATUS_BLOCKED,
        Done => STATUS_DONE,
        Working => STATUS_WORKING,
        Idle => STATUS_IDLE,
    })
}
