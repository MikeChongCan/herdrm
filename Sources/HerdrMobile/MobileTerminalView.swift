import HerdrKit
import HerdrSSH
import SwiftTerm
import SwiftUI
import UIKit

/// One live attach: a PTY channel running `herdr … attach` on the device,
/// pumped into a SwiftTerm view. The session outlives view updates; it ends
/// when the channel EOFs (takeover by another client, pane closed, network).
///
/// Mobile terminals are display-first (Heeler's ADR 0013 insight): the live
/// pane renders, but typing goes through the composer (`agent.prompt`) and a
/// key bar (`pane.send_input` keys), which herdr encodes properly server-side.
/// A keyboard toggle still allows raw typing for TUI menus that need it.
@MainActor
final class MobileAttachSession: ObservableObject {
    enum Status: Equatable {
        case connecting
        case running
        case ended(String)
    }

    @Published var status: Status = .connecting
    let transport: MobileTransport
    let target: TerminalAttachTarget
    private var channel: SSHPTYChannel?
    private var readTask: Task<Void, Never>?
    /// Bytes before the bootstrap marker are shell rc chatter, not pane output.
    private var sawBootstrapMarker = false
    private var bootstrapBuffer = Data()
    weak var terminalView: TerminalView?

    /// The herdr pane behind this attach, for key/prompt RPCs.
    let paneID: String

    init(transport: MobileTransport, target: TerminalAttachTarget, paneID: String) {
        self.transport = transport
        self.target = target
        self.paneID = paneID
    }

    var agentPaneID: String? {
        if case .agent(let paneID) = target { return paneID }
        return nil
    }

    func start(columns: Int, rows: Int) {
        guard channel == nil else { return }
        status = .connecting
        sawBootstrapMarker = false
        bootstrapBuffer.removeAll()
        Task {
            do {
                let channel = try await transport.openTerminal(
                    command: MobileAttach.command(target: target),
                    columns: max(columns, 20),
                    rows: max(rows, 5)
                )
                self.channel = channel
                self.status = .running
                self.pump(channel)
            } catch {
                self.status = .ended(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        }
    }

    private func pump(_ channel: SSHPTYChannel) {
        readTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let data = try await channel.read(timeout: .seconds(3600)) else { break }
                    guard !data.isEmpty else { continue }
                    self?.ingest(data)
                }
            } catch {}
            guard let self, !Task.isCancelled else { return }
            if case .running = self.status {
                self.status = .ended(String(localized: "Session ended"))
            }
        }
    }

    private func ingest(_ data: Data) {
        guard !sawBootstrapMarker else {
            feed(data)
            return
        }
        bootstrapBuffer.append(data)
        guard let range = bootstrapBuffer.firstRange(of: MobileAttach.bootstrapMarker) else {
            // Cap the gate so a herdr that never prints the marker (old
            // binary, exec failure output) still shows its error text.
            if bootstrapBuffer.count > 8192 {
                sawBootstrapMarker = true
                feed(bootstrapBuffer)
                bootstrapBuffer.removeAll()
            }
            return
        }
        sawBootstrapMarker = true
        let payload = bootstrapBuffer.suffix(from: range.upperBound)
        bootstrapBuffer.removeAll()
        if !payload.isEmpty { feed(Data(payload)) }
    }

    private func feed(_ data: Data) {
        terminalView?.feed(byteArray: ArraySlice([UInt8](data)))
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let channel else { return }
        let data = Data(bytes)
        Task { try? await channel.write(data, timeout: .seconds(10)) }
    }

    /// Sends named keys through herdr's RPC — proper terminal encoding without
    /// this client knowing the pane's keyboard protocol state.
    func sendKeys(_ keys: [String]) {
        Task {
            _ = try? await transport.request(
                method: "pane.send_input",
                params: .object([
                    "pane_id": .string(paneID),
                    "keys": .array(keys.map { .string($0) }),
                ])
            )
        }
    }

    /// Sends a prompt to the agent; herdr delivers and submits it.
    func prompt(_ text: String) {
        guard let agentPaneID else { return }
        Task {
            _ = try? await transport.request(
                method: "agent.prompt",
                params: .object([
                    "target": .string(agentPaneID),
                    "text": .string(text),
                ])
            )
        }
    }

    func pageUp() {
        if let terminalView {
            terminalView.pageUp()
        } else {
            sendKeys(["page_up"])
        }
    }

    func pageDown() {
        if let terminalView {
            terminalView.pageDown()
        } else {
            sendKeys(["page_down"])
        }
    }

    func resize(columns: Int, rows: Int) {
        guard let channel, columns > 0, rows > 0 else { return }
        Task { try? await channel.resize(columns: columns, rows: rows, timeout: .seconds(5)) }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        if let channel {
            Task { try? await channel.close(timeout: .seconds(2)) }
        }
        channel = nil
    }
}

struct MobileTerminalScreen: View {
    @StateObject private var session: MobileAttachSession
    @State private var composerText = ""
    @State private var keyboardShown = false
    private let title: String

    init(transport: MobileTransport, target: TerminalAttachTarget, paneID: String, title: String) {
        _session = StateObject(
            wrappedValue: MobileAttachSession(transport: transport, target: target, paneID: paneID)
        )
        self.title = title
    }

    var body: some View {
        ZStack {
            terminalBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                MobileTerminalHost(session: session, keyboardShown: $keyboardShown)
                controls
            }
            if case .ended(let reason) = session.status {
                endedOverlay(reason)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(terminalBackground, for: .navigationBar)
        .onDisappear { session.stop() }
    }

    private var terminalBackground: SwiftUI.Color {
        SwiftUI.Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            keyBar
            if session.agentPaneID != nil {
                composer
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.black.opacity(0.35))
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                KeyChip("esc") { session.sendKeys(["esc"]) }
                KeyChip("tab") { session.sendKeys(["tab"]) }
                KeyChip("↑") { session.sendKeys(["up"]) }
                KeyChip("↓") { session.sendKeys(["down"]) }
                KeyChip("⇞") { session.pageUp() }
                KeyChip("⇟") { session.pageDown() }
                KeyChip("⏎") { session.sendKeys(["enter"]) }
                KeyChip("^C") { session.sendKeys(["ctrl+c"]) }
                Button {
                    keyboardShown.toggle()
                } label: {
                    Image(systemName: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 34, height: 30)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "Message the agent…"),
                text: $composerText,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
            .tint(.white)
            .onSubmit(sendPrompt)

            Button(action: sendPrompt) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? SwiftUI.Color.white.opacity(0.25) : SwiftUI.Color.accentColor
                    )
            }
            .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sendPrompt() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.prompt(text)
        composerText = ""
    }

    private func endedOverlay(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Text(reason)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
            Button(String(localized: "Reconnect")) {
                session.stop()
                session.start(columns: 80, rows: 24)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// TerminalView subclass for iOS that translates single- and two-finger touch dragging
/// into terminal scrolling (SGR mouse wheel for mouse-tracking sessions like herdr / tmux /
/// agents, cursor arrow keys for alternate screen buffers, and local scrollback for normal buffers).
final class MobileTerminalUIView: TerminalView, UIGestureRecognizerDelegate {
    private var scrollPanGesture: UIPanGestureRecognizer?
    private var accumulatedScrollDelta: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTouchScrolling()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTouchScrolling()
    }

    private func setupTouchScrolling() {
        // Disable UIScrollView's internal contentOffset tracking which assumes a content size
        // larger than the viewport and conflicts with terminal layer rendering.
        isScrollEnabled = false
        alwaysBounceVertical = false
        showsVerticalScrollIndicator = false

        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        gesture.delegate = self
        gesture.cancelsTouchesInView = true
        gesture.minimumNumberOfTouches = 1
        gesture.maximumNumberOfTouches = 2
        addGestureRecognizer(gesture)
        self.scrollPanGesture = gesture
    }

    override func mouseModeChanged(source: Terminal) {
        // Prevent SwiftTerm from installing panMouseGesture, which hijacks single-touch
        // pan gestures into virtual mouse button 1 selection drags rather than scrolling.
        // Our custom scrollPanGesture handles mouse-mode scrolling via SGR mouse wheel events.
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == scrollPanGesture {
            // When text selection is active, let selection gestures handle touch drags
            if selection.active {
                return false
            }
            // Require vertical dominance so system edge gestures (like swipe-to-pop) still work
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: self)
                if abs(velocity.x) > abs(velocity.y) {
                    return false
                }
            }
            return true
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return false
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            accumulatedScrollDelta = 0

        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            accumulatedScrollDelta += translation.y

            let terminal = getTerminal()
            let rowHeight = max(12, bounds.height / CGFloat(max(1, terminal.rows)))
            let reportsMouse = allowMouseReporting && terminal.mouseMode != .off

            // In herdr and tmux, each mouse wheel event typically moves 3 rows.
            // A threshold of ~24pt gives a natural 1:1 feel under the user's thumb.
            let threshold = reportsMouse ? max(20, rowHeight * 1.5) : max(12, rowHeight)

            if abs(accumulatedScrollDelta) >= threshold {
                let steps = Int(accumulatedScrollDelta / threshold)
                accumulatedScrollDelta -= CGFloat(steps) * threshold

                let scrollingUp = steps > 0 // finger dragging downward -> scroll up (view earlier content)
                let magnitude = abs(steps)

                if reportsMouse {
                    // SGR mouse wheel reporting: Button 4 = wheel up, Button 5 = wheel down
                    let location = gesture.location(in: self)
                    let colWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
                    let col = max(0, min(terminal.cols - 1, Int(location.x / colWidth)))
                    let row = max(0, min(terminal.rows - 1, Int(location.y / rowHeight)))
                    let button = scrollingUp ? 4 : 5
                    let buttonFlags = terminal.encodeButton(
                        button: button,
                        release: false,
                        shift: false,
                        meta: false,
                        control: false
                    )
                    for _ in 0..<magnitude {
                        // sendEvent sends the SGR sequence \x1b[<64;col;rowM / \x1b[<65;col;rowM
                        // (Do NOT use sendMotion, which adds +32 to flags and corrupts wheel events)
                        terminal.sendEvent(
                            buttonFlags: buttonFlags,
                            x: col,
                            y: row,
                            pixelX: Int(location.x),
                            pixelY: Int(location.y)
                        )
                    }
                } else if scrollThumbsize == 0 {
                    // Alternate screen buffer without mouse reporting (e.g. less, nano)
                    let key = scrollingUp
                        ? (terminal.applicationCursor ? "\u{1b}OA" : "\u{1b}[A")
                        : (terminal.applicationCursor ? "\u{1b}OB" : "\u{1b}[B")
                    for _ in 0..<magnitude {
                        send(txt: key)
                    }
                } else {
                    // Normal buffer with local scrollback
                    if scrollingUp {
                        scrollUp(lines: magnitude)
                    } else {
                        scrollDown(lines: magnitude)
                    }
                }
            }

        case .ended:
            // Momentum: if user flicked with noticeable velocity, send a small burst of scroll steps
            let velocity = gesture.velocity(in: self).y
            if abs(velocity) > 800 {
                let extraSteps = min(8, Int(abs(velocity) / 400))
                let scrollingUp = velocity > 0
                let terminal = getTerminal()
                let reportsMouse = allowMouseReporting && terminal.mouseMode != .off

                if reportsMouse {
                    let location = gesture.location(in: self)
                    let colWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
                    let rowHeight = max(12, bounds.height / CGFloat(max(1, terminal.rows)))
                    let col = max(0, min(terminal.cols - 1, Int(location.x / colWidth)))
                    let row = max(0, min(terminal.rows - 1, Int(location.y / rowHeight)))
                    let button = scrollingUp ? 4 : 5
                    let buttonFlags = terminal.encodeButton(
                        button: button,
                        release: false,
                        shift: false,
                        meta: false,
                        control: false
                    )
                    for _ in 0..<extraSteps {
                        terminal.sendEvent(
                            buttonFlags: buttonFlags,
                            x: col,
                            y: row,
                            pixelX: Int(location.x),
                            pixelY: Int(location.y)
                        )
                    }
                } else if scrollThumbsize == 0 {
                    let key = scrollingUp
                        ? (terminal.applicationCursor ? "\u{1b}OA" : "\u{1b}[A")
                        : (terminal.applicationCursor ? "\u{1b}OB" : "\u{1b}[B")
                    for _ in 0..<extraSteps {
                        send(txt: key)
                    }
                } else {
                    if scrollingUp {
                        scrollUp(lines: extraSteps)
                    } else {
                        scrollDown(lines: extraSteps)
                    }
                }
            }
            accumulatedScrollDelta = 0

        case .cancelled:
            accumulatedScrollDelta = 0

        default:
            break
        }
    }
}

/// UIKit host for SwiftTerm's iOS TerminalView, wired to the attach session.
private struct MobileTerminalHost: UIViewRepresentable {
    let session: MobileAttachSession
    @Binding var keyboardShown: Bool

    func makeUIView(context: Context) -> TerminalView {
        let view = MobileTerminalUIView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.backgroundColor = UIColor(red: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
        view.nativeBackgroundColor = view.backgroundColor ?? .black
        view.nativeForegroundColor = UIColor(red: 0xD6 / 255, green: 0xD6 / 255, blue: 0xD6 / 255, alpha: 1)
        session.terminalView = view
        let terminal = view.getTerminal()
        session.start(columns: terminal.cols, rows: terminal.rows)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        if keyboardShown, !uiView.isFirstResponder {
            _ = uiView.becomeFirstResponder()
        } else if !keyboardShown, uiView.isFirstResponder {
            _ = uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: MobileAttachSession
        init(session: MobileAttachSession) { self.session = session }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in self.session.resize(columns: newCols, rows: newRows) }
        }
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in self.session.send(bytes[...]) }
        }
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else { return }
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        nonisolated func bell(source: TerminalView) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                Task { @MainActor in UIPasteboard.general.string = text }
            }
        }
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private struct KeyChip: View {
    let label: String
    let action: () -> Void

    init(_ label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 34)
                .frame(height: 30)
                .padding(.horizontal, 4)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
