//! Platform-agnostic core for the herdr bridge.
//!
//! # The one invariant
//!
//! This crate contains **no** `#[cfg(unix)]` / `#[cfg(windows)]` and no direct
//! syscalls. Everything the operating system disagrees about lives behind the
//! traits in [`platform`], implemented by `herdr-bridge-sys-unix` and
//! `herdr-bridge-sys-windows`.
//!
//! That is what lets the Windows build be developed and debugged on macOS: the
//! logic that can actually be wrong — protocol framing, pane multiplexing,
//! scrollback, agent status inference — is exercised by `cargo test` on any
//! host. See `docs/WINDOWS_SUPPORT_PLAN.md` §3.6.

pub mod agent;
pub mod pane;
pub mod platform;
pub mod protocol;
pub mod scrollback;
pub mod status;
pub mod vt;

pub use agent::{sort_agents, Agent, AgentKind, AgentStatus};
pub use pane::{Pane, PaneId, PaneRegistry};
pub use platform::{
    descendants_of, PlatformProfile, ProcessInfo, ProcessInspector, PtyBackend, PtySession,
    PtySize, SpawnSpec, SpawnedPty,
};
pub use protocol::{Event, LineDecoder, Request, Response, RpcError};
pub use scrollback::Scrollback;
pub use status::{ActivityDetector, ActivityThresholds};
pub use vt::AnsiFilter;
