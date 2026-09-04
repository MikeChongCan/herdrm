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
    @Published private(set) var collectedLinks: [URL] = []
    /// Resolved on every use rather than held: the device's transport is
    /// replaced wholesale by a reconnect, and this session outlives that.
    let provider: any MobileTransportProvider
    let target: TerminalAttachTarget
    private var channel: SSHPTYChannel?
    private var readTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    /// Bumped by `stop`, so an attach still in flight when the session is torn
    /// down cannot publish its channel into the session that replaced it.
    private var startToken = 0
    /// The transport revision this channel was opened on; `nil` when nothing is
    /// attached. A reconnect bumps the revision and the channel died with the
    /// session it came from.
    private var attachedRevision: Int?
    /// The last geometry the terminal view reported, so a re-attach comes back
    /// at the size the user is looking at.
    private var lastColumns = 80
    private var lastRows = 24
    /// Bytes before the bootstrap marker are shell rc chatter, not pane output.
    private var sawBootstrapMarker = false
    private var bootstrapBuffer = Data()
    weak var terminalView: TerminalView?
    private var textExtractor = VisibleTextExtractor()
    private var linkCollector = WebLinkCollector()

    /// The herdr pane behind this attach, for key/prompt RPCs.
    let paneID: String

    init(provider: any MobileTransportProvider, target: TerminalAttachTarget, paneID: String) {
        self.provider = provider
        self.target = target
        self.paneID = paneID
    }

    var agentPaneID: String? {
        if case .agent(let paneID) = target { return paneID }
        return nil
    }

    func start(columns: Int, rows: Int) {
        guard channel == nil, startTask == nil else { return }
        lastColumns = max(columns, 20)
        lastRows = max(rows, 5)
        status = .connecting
        sawBootstrapMarker = false
        bootstrapBuffer.removeAll()
        let token = startToken
        startTask = Task {
            do {
                let transport = try await self.provider.currentTransport()
                let revision = self.provider.transportRevision
                let channel = try await transport.openTerminal(
                    command: MobileAttach.command(target: self.target),
                    columns: self.lastColumns,
                    rows: self.lastRows
                )
                // A `stop` while this was in flight means the channel belongs
                // to nobody: hand it back rather than leak it into the session
                // that has since replaced this attach.
                guard self.startToken == token else {
                    try? await channel.close(timeout: .seconds(2))
                    return
                }
                self.startTask = nil
                self.channel = channel
                self.attachedRevision = revision
                self.status = .running
                self.pump(channel)
            } catch {
                guard self.startToken == token else { return }
                self.startTask = nil
                self.status = .ended(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        }
    }

    /// Full teardown and a fresh attach on whatever transport the device has
    /// now. `herdr … attach --takeover` makes re-attaching to the same pane
    /// legitimate, so this reclaims the pane rather than competing with the
    /// dead attach still registered on the server.
    func restart() {
        stop()
        start(columns: lastColumns, rows: lastRows)
    }

    /// Returning to the foreground. Resolving the transport runs the device's
    /// own probe-or-rebuild first; after that, a channel whose revision no
    /// longer matches belonged to a session that is gone, so it is re-attached.
    func resumeAfterForeground() {
        guard startTask == nil else { return }
        Task {
            if case .ended = self.status {
                self.restart()
                return
            }
            do {
                _ = try await self.provider.currentTransport()
            } catch {
                self.status = .ended(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
                return
            }
            let stale = ConnectionRecoveryPolicy.attachNeedsRebuild(
                attachedRevision: self.attachedRevision,
                currentRevision: self.provider.transportRevision
            )
            if self.channel == nil || stale {
                self.restart()
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
        for event in textExtractor.consume(data) {
            let text: String
            switch event {
            case .line(let line): text = line
            case .osc8(let uri): text = uri
            }
            if let url = WebURL.first(in: text) {
                linkCollector.add(url)
            }
        }
        collectedLinks = linkCollector.urls
        terminalView?.feed(byteArray: ArraySlice([UInt8](data)))
    }

    func discardCollectedLinks() {
        textExtractor = VisibleTextExtractor()
        linkCollector = WebLinkCollector()
        collectedLinks = []
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
            guard let transport = try? await self.provider.currentTransport() else { return }
            _ = try? await transport.request(
                method: "pane.send_input",
                params: .object([
                    "pane_id": .string(self.paneID),
                    "keys": .array(keys.map { .string($0) }),
                ])
            )
        }
    }

    /// Sends a prompt to the agent; herdr delivers and submits it.
    func prompt(_ text: String) {
        guard let agentPaneID else { return }
        Task {
            guard let transport = try? await self.provider.currentTransport() else { return }
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
        guard columns > 0, rows > 0 else { return }
        lastColumns = columns
        lastRows = rows
        guard let channel else { return }
        Task { try? await channel.resize(columns: columns, rows: rows, timeout: .seconds(5)) }
    }

    /// Drops everything cached on the current SSH session — the read pump, the
    /// pending start, the channel and the revision it was opened on — so a
    /// following `start` cannot reuse a dead handle.
    func stop() {
        startToken += 1
        readTask?.cancel()
        readTask = nil
        startTask?.cancel()
        startTask = nil
        if let channel {
            Task { try? await channel.close(timeout: .seconds(2)) }
        }
        channel = nil
        attachedRevision = nil
    }
}

struct MobileTerminalScreen: View {
    @StateObject private var session: MobileAttachSession
    @State private var composerText = ""
    @State private var keyboardShown = false
    @State private var showingLinks = false
    @Environment(\.scenePhase) private var scenePhase
    private let title: String

    init(
        provider: any MobileTransportProvider,
        target: TerminalAttachTarget,
        paneID: String,
        title: String
    ) {
        // `StateObject` keeps the first value it is given, so the session must
        // hold the provider (stable per device) rather than a transport (which
        // a reconnect replaces underneath this view).
        _session = StateObject(
            wrappedValue: MobileAttachSession(provider: provider, target: target, paneID: paneID)
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
        .onDisappear {
            session.stop()
            session.discardCollectedLinks()
        }
        .sheet(isPresented: $showingLinks) {
            collectedLinksSheet
        }
        .onChange(of: scenePhase) { _, phase in
            // The attach cannot outlive a suspension: re-prove the transport
            // and re-attach (`--takeover`) when the session behind it is gone.
            if phase == .active { session.resumeAfterForeground() }
        }
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
                if !session.collectedLinks.isEmpty {
                    Button {
                        showingLinks = true
                    } label: {
                        Text(linkChipLabel)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(minWidth: 34)
                            .frame(height: 30)
                            .padding(.horizontal, 4)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
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

    private var linkChipLabel: String {
        let count = session.collectedLinks.count
        if count == 1 { return String(localized: "link") }
        return String(localized: "link · \(count)")
    }

    private var collectedLinksSheet: some View {
        NavigationStack {
            List(session.collectedLinks, id: \.absoluteString) { url in
                Button(url.absoluteString) {
                    UIApplication.shared.open(url)
                }
                .swipeActions(edge: .trailing) {
                    Button(String(localized: "Copy")) {
                        UIPasteboard.general.string = url.absoluteString
                    }
                }
                .contextMenu {
                    Button(String(localized: "Copy")) {
                        UIPasteboard.general.string = url.absoluteString
                    }
                }
            }
            .navigationTitle(String(localized: "Links"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { showingLinks = false }
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
                session.restart()
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
final class MobileTerminalUIView: TerminalView, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate, UIEditMenuInteractionDelegate {
    private var scrollPanGesture: UIPanGestureRecognizer?
    private var accumulatedScrollDelta: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTouchScrolling()
        installLinkMenus()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTouchScrolling()
        installLinkMenus()
    }

    private func installLinkMenus() {
        let interaction = UIContextMenuInteraction(delegate: self)
        addInteraction(interaction)
        if let menuGR = interaction.gestureRecognizerForFailureRelationship {
            for case let lp as UILongPressGestureRecognizer in gestureRecognizers ?? []
            where lp !== menuGR {
                lp.require(toFail: menuGR)
            }
        }
        addInteraction(UIEditMenuInteraction(delegate: self))
    }

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
        return WebURL.first(in: raw)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let url = webURL(at: location) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: {
            let label = UILabel()
            label.text = url.absoluteString
            label.font = .preferredFont(forTextStyle: .body)
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            label.textAlignment = .center
            let vc = UIViewController()
            vc.view = label
            vc.preferredContentSize = CGSize(width: 280, height: 44)
            return vc
        }, actionProvider: { [weak self] _ in
            self?.linkMenu(for: url)
        })
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        var actions = suggestedActions
        if selection.active, let url = WebURL.first(in: selection.getSelectedText()) {
            actions.append(contentsOf: linkMenu(for: url).children)
        }
        return UIMenu(children: actions)
    }

    private func linkMenu(for url: URL) -> UIMenu {
        let open = UIAction(title: String(localized: "Open"), image: UIImage(systemName: "safari")) { _ in
            UIApplication.shared.open(url)
        }
        let copy = UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = url.absoluteString
        }
        var children: [UIMenuElement] = [open, copy]
        if nearestViewController() != nil {
            let share = UIAction(title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.share(url)
            }
            children.append(share)
        }
        return UIMenu(children: children)
    }

    private func share(_ url: URL) {
        guard let presenter = nearestViewController() else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        }
        presenter.present(activity, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return window?.rootViewController
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
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
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
