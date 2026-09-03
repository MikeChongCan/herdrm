//! Herdr desktop client prototype, in Rust GPUI.
//!
//! This is the Windows client being built on macOS. Everything below is
//! platform-neutral: the sidebar, the pane multiplexing and the PTY plumbing
//! are the same code on both hosts, and only the adapter chosen in
//! [`platform_profile`] differs. See `docs/WINDOWS_SUPPORT_PLAN.md` §3.6.
//!
//! Prototype scope: panes are spawned locally rather than over the bridge RPC,
//! and output is rendered as stripped plain text rather than through a full VT
//! emulator.

mod keys;
mod theme;

use std::sync::Arc;
use std::time::{Duration, Instant};

use gpui::{
    div, prelude::*, px, uniform_list, App, Bounds, Context, FocusHandle, Focusable, KeyDownEvent,
    ScrollStrategy, SharedString, UniformListScrollHandle, Window, WindowBounds, WindowOptions,
};
use gpui_platform::application;

use herdr_bridge_core::platform::{PlatformProfile, PtyBackend, PtySize};
use herdr_bridge_core::{AgentStatus, PaneId, PaneRegistry};
use herdr_bridge_pty::PortablePtyBackend;

use keys::{encode_key, KeyPress};

/// How often panes are drained. 60fps would spend more time waking than
/// drawing; ~30fps keeps agent output feeling live.
const PUMP_INTERVAL: Duration = Duration::from_millis(33);

/// Returns the adapter for the host we were compiled for.
///
/// This function is the only place in the desktop client that knows which OS it
/// is running on.
fn platform_profile() -> Box<dyn PlatformProfile> {
    #[cfg(unix)]
    {
        Box::new(herdr_bridge_sys_unix::UnixPlatform::new())
    }
    #[cfg(windows)]
    {
        Box::new(herdr_bridge_sys_windows::WindowsPlatform::new())
    }
}

struct HerdrDesktop {
    registry: PaneRegistry,
    selected: Option<PaneId>,
    platform: Box<dyn PlatformProfile>,
    focus_handle: FocusHandle,
    scroll_handle: UniformListScrollHandle,
    started_at: Instant,
    /// Set when a spawn fails, so the window shows the reason instead of
    /// silently doing nothing.
    last_error: Option<SharedString>,
}

impl HerdrDesktop {
    fn new(cx: &mut Context<Self>) -> Self {
        let backend: Arc<dyn PtyBackend> = Arc::new(PortablePtyBackend::new());
        let platform = platform_profile();

        let mut this = Self {
            registry: PaneRegistry::new(backend),
            selected: None,
            platform,
            focus_handle: cx.focus_handle(),
            scroll_handle: UniformListScrollHandle::new(),
            started_at: Instant::now(),
            last_error: None,
        };

        // Open one shell so the window is useful the moment it appears.
        this.spawn_shell("local");

        // Drain PTYs on a timer and redraw only when something changed.
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(PUMP_INTERVAL).await;
                let keep_going = this
                    .update(cx, |this, cx| {
                        if this.registry.pump_all(this.now_ms()) {
                            this.follow_output();
                            cx.notify();
                        }
                    })
                    .is_ok();
                if !keep_going {
                    // The window is gone.
                    break;
                }
            }
        })
        .detach();

        this
    }

    /// Milliseconds since start. A monotonic reading is all the status machine
    /// needs, and it keeps wall-clock changes from perturbing transitions.
    fn now_ms(&self) -> u64 {
        self.started_at.elapsed().as_millis() as u64
    }

    fn spawn_shell(&mut self, space: &str) {
        let spec = self
            .platform
            .default_shell()
            .size(PtySize::new(40, 120))
            .env("TERM", "xterm-256color");

        let title = spec
            .program
            .rsplit(['/', '\\'])
            .next()
            .unwrap_or(&spec.program)
            .to_string();

        match self.registry.create(space, title, &spec) {
            Ok(id) => {
                self.selected = Some(id);
                self.last_error = None;
            }
            Err(error) => {
                self.last_error = Some(format!("spawn failed: {error}").into());
            }
        }
    }

    /// Keeps the newest line in view.
    fn follow_output(&mut self) {
        let Some(pane) = self.selected_pane() else {
            return;
        };
        let count = pane.scrollback().visible_lines().len();
        if count > 0 {
            self.scroll_handle
                .scroll_to_item(count - 1, ScrollStrategy::Top);
        }
    }

    fn selected_pane(&self) -> Option<&herdr_bridge_core::Pane> {
        self.selected.as_ref().and_then(|id| self.registry.get(id))
    }

    fn on_new_shell(&mut self, _: &gpui::ClickEvent, window: &mut Window, cx: &mut Context<Self>) {
        self.spawn_shell("local");
        window.focus(&self.focus_handle, cx);
        cx.notify();
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        let press = KeyPress {
            key: keystroke.key.clone(),
            key_char: keystroke.key_char.clone(),
            ctrl: keystroke.modifiers.control,
            alt: keystroke.modifiers.alt,
            shift: keystroke.modifiers.shift,
        };

        let Some(bytes) = encode_key(&press) else {
            return;
        };
        let Some(id) = self.selected.clone() else {
            return;
        };

        let now = self.now_ms();
        if let Some(pane) = self.registry.get_mut(&id) {
            if let Err(error) = pane.write_input(&bytes, now) {
                self.last_error = Some(format!("write failed: {error}").into());
            }
        }
        cx.notify();
    }

    fn render_sidebar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let spaces = self.registry.spaces();
        let agents = self.registry.agents();
        let selected = self.selected.clone();

        div()
            .flex()
            .flex_col()
            .w(px(260.))
            .h_full()
            .bg(theme::color(theme::SIDEBAR_BG))
            .border_r_1()
            .border_color(theme::color(theme::BORDER))
            .child(
                div()
                    .flex()
                    .items_center()
                    .h(px(52.))
                    .px_4()
                    .border_b_1()
                    .border_color(theme::color(theme::BORDER))
                    .text_color(theme::color(theme::TEXT))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .child("Herdr"),
            )
            .child(section_label("SPACES"))
            .children(spaces.into_iter().map(|space| {
                div()
                    .px_4()
                    .py_1()
                    .text_sm()
                    .text_color(theme::color(theme::TEXT_MUTED))
                    .child(space)
            }))
            .child(section_label("AGENTS"))
            .child(div().flex().flex_col().flex_1().overflow_hidden().children(
                agents.into_iter().map(|agent| {
                    let pane_id = PaneId::new(agent.pane_id.clone());
                    let is_selected = selected.as_ref() == Some(&pane_id);

                    div()
                        .id(SharedString::from(agent.pane_id.clone()))
                        .flex()
                        .items_center()
                        .gap_2()
                        .mx_2()
                        .px_2()
                        .py_1p5()
                        .rounded_md()
                        .cursor_pointer()
                        .when(is_selected, |row| row.bg(theme::color(theme::ROW_SELECTED)))
                        .when(!is_selected, |row| {
                            row.hover(|row| row.bg(theme::color(theme::ROW_HOVER)))
                        })
                        .on_click(cx.listener(move |this, _event, window, cx| {
                            this.selected = Some(pane_id.clone());
                            this.follow_output();
                            window.focus(&this.focus_handle, cx);
                            cx.notify();
                        }))
                        .child(
                            div()
                                .size(px(7.))
                                .rounded_full()
                                .bg(theme::status_color(agent.status)),
                        )
                        .child(
                            div()
                                .flex_1()
                                .text_sm()
                                .text_color(theme::color(theme::TEXT))
                                .child(agent.name.clone()),
                        )
                        .child(
                            div()
                                .text_xs()
                                .text_color(theme::color(theme::TEXT_FAINT))
                                .child(agent.status.label()),
                        )
                }),
            ))
            .child(
                // Device footer, matching HerdrM's device switcher.
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .h(px(44.))
                    .px_4()
                    .border_t_1()
                    .border_color(theme::color(theme::BORDER))
                    .child(
                        div()
                            .size(px(7.))
                            .rounded_full()
                            .bg(theme::color(theme::STATUS_DONE)),
                    )
                    .child(
                        div()
                            .text_sm()
                            .text_color(theme::color(theme::TEXT_MUTED))
                            .child(format!("Local · {}", self.platform.name())),
                    ),
            )
    }

    fn render_terminal(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let (title, status, lines, exited) = match self.selected_pane() {
            Some(pane) => (
                pane.title.clone(),
                pane.status(),
                pane.scrollback()
                    .visible_lines()
                    .into_iter()
                    .map(SharedString::from)
                    .collect::<Vec<_>>(),
                pane.has_exited(),
            ),
            None => ("No pane".to_string(), AgentStatus::Idle, Vec::new(), false),
        };

        let line_count = lines.len();
        let monospace = self.platform.monospace_family();

        div()
            .flex()
            .flex_col()
            .flex_1()
            .h_full()
            .bg(theme::color(theme::BG))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .h(px(52.))
                    .px_4()
                    .bg(theme::color(theme::HEADER_BG))
                    .border_b_1()
                    .border_color(theme::color(theme::BORDER))
                    .child(
                        div()
                            .size(px(7.))
                            .rounded_full()
                            .bg(theme::status_color(status)),
                    )
                    .child(
                        div()
                            .text_color(theme::color(theme::TEXT))
                            .child(title.clone()),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(theme::color(theme::TEXT_FAINT))
                            .child(if exited {
                                "exited".to_string()
                            } else {
                                status.label().to_lowercase()
                            }),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .id("new-shell")
                            .px_3()
                            .py_1()
                            .rounded_md()
                            .cursor_pointer()
                            .text_sm()
                            .text_color(theme::color(theme::ACCENT))
                            .hover(|button| button.bg(theme::color(theme::ROW_HOVER)))
                            .on_click(cx.listener(Self::on_new_shell))
                            .child("New shell"),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .overflow_hidden()
                    .px_4()
                    .py_2()
                    .font_family(monospace)
                    .text_sm()
                    .text_color(theme::color(theme::TEXT))
                    .child(
                        uniform_list(
                            "terminal-lines",
                            line_count,
                            cx.processor(
                                move |_this, range: std::ops::Range<usize>, _window, _cx| {
                                    range
                                        .map(|ix| {
                                            div().child(lines.get(ix).cloned().unwrap_or_default())
                                        })
                                        .collect::<Vec<_>>()
                                },
                            ),
                        )
                        .track_scroll(&self.scroll_handle)
                        .h_full(),
                    ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .h(px(28.))
                    .px_4()
                    .border_t_1()
                    .border_color(theme::color(theme::BORDER))
                    .text_xs()
                    .text_color(theme::color(if self.last_error.is_some() {
                        theme::STATUS_BLOCKED
                    } else {
                        theme::TEXT_FAINT
                    }))
                    .child(match &self.last_error {
                        Some(error) => error.clone(),
                        None => SharedString::from("type to send input · ⌃C interrupts"),
                    }),
            )
    }
}

fn section_label(text: &'static str) -> impl IntoElement {
    div()
        .px_4()
        .pt_3()
        .pb_1()
        .text_xs()
        .text_color(theme::color(theme::TEXT_FAINT))
        .child(text)
}

impl Focusable for HerdrDesktop {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Render for HerdrDesktop {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .key_context("HerdrDesktop")
            .track_focus(&self.focus_handle)
            .on_key_down(cx.listener(Self::on_key_down))
            .flex()
            .flex_row()
            .size_full()
            .bg(theme::color(theme::BG))
            .text_color(theme::color(theme::TEXT))
            .child(self.render_sidebar(cx))
            .child(self.render_terminal(cx))
    }
}

fn main() {
    application().run(|cx: &mut App| {
        let bounds = Bounds::centered(None, gpui::size(px(1100.), px(720.)), cx);
        let window = cx
            .open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    titlebar: Some(gpui::TitlebarOptions {
                        title: Some("Herdr Desktop".into()),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
                |window, cx| {
                    let view = cx.new(HerdrDesktop::new);
                    window.focus(&view.read(cx).focus_handle.clone(), cx);
                    view
                },
            )
            .expect("open window");

        // Quit when the last window closes, which is what a single-window
        // desktop client should do on Windows and Linux.
        cx.on_window_closed(|cx, _window_id| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();

        let _ = window;
        cx.activate(true);
    });
}
