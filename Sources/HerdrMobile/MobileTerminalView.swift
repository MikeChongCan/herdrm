import HerdrKit
import HerdrSSH
import SwiftTerm
import SwiftUI
import UIKit

/// One live attach: a PTY channel running `herdr … attach` on the device,
/// pumped into a SwiftTerm view. The session outlives view updates; it ends
/// when the channel EOFs (takeover by another client, pane closed, network).
/// macOS already draws this attach with libghostty-vt (herdr's pane engine);
/// iOS stays on SwiftTerm until a Ghostty + UITextInput host lands.
///
/// Mobile terminals are display-first (Heeler's ADR 0013 insight): the live
/// pane renders through this attach, composer prompts use `agent.prompt`, and
/// TUI typing while the PTY has focus uses `pane.send_input`. Agent panes do
/// not write typed bytes to the attach PTY. Mouse-wheel and PageUp/PageDown
/// CSI still go to `herdr agent attach`, which owns pane scrollback.
@MainActor
final class MobileAttachSession: ObservableObject {
    enum Status: Equatable {
        case connecting
        case running
        case ended(String)
    }

    @Published var status: Status = .connecting
    @Published private(set) var collectedLinks: [URL] = []
    @Published var isFetchingPreview = false
    @Published var isStagingAttachment = false
    @Published var previewAlert: String?
    /// Resolved on every use rather than held: the device's transport is
    /// replaced wholesale by a reconnect, and this session outlives that.
    let provider: any MobileTransportProvider
    let cwdProvider: () -> String?
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

    init(
        provider: any MobileTransportProvider,
        cwdProvider: @escaping () -> String?,
        target: TerminalAttachTarget,
        paneID: String
    ) {
        self.provider = provider
        self.cwdProvider = cwdProvider
        self.target = target
        self.paneID = paneID
    }

    func liveCwd() -> String? { cwdProvider() }

    var remoteHome: String { provider.remoteHome }

    func previewHostFile(_ path: String, from view: UIView) {
        Task {
            await self.runPreview(path, from: view)
        }
    }

    private func runPreview(_ path: String, from view: UIView) async {
        isFetchingPreview = true
        defer { isFetchingPreview = false }
        do {
            let transport = try await provider.currentTransport()
            let snapshot = try await HostFilePreview.fetch(path: path, using: transport)
            guard let presenter = Self.nearestViewController(from: view) else { return }
            HostFilePreview.present(
                fileURL: snapshot.fileURL,
                directoryURL: snapshot.directoryURL,
                from: presenter
            )
        } catch let error as HostFilePreviewError {
            previewAlert = error.errorDescription
        } catch SSHError.responseTooLarge {
            previewAlert = HostFilePreviewError.tooLarge.errorDescription
        } catch {
            previewAlert = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private static func nearestViewController(from view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return view.window?.rootViewController
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

    /// Types into the pane without submitting (no trailing Enter).
    func sendText(_ text: String) {
        Task {
            guard let transport = try? await self.provider.currentTransport() else { return }
            _ = try? await transport.request(
                method: "pane.send_input",
                params: .object([
                    "pane_id": .string(self.paneID),
                    "text": .string(text),
                ])
            )
        }
    }

    func stageClipboardPaths() async -> String? {
        guard !isStagingAttachment else { return nil }
        isStagingAttachment = true
        defer { isStagingAttachment = false }
        do {
            return try await MobileAttachmentStager.stageQuotedPaths(using: provider)
        } catch {
            previewAlert = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }

    func stageLocalURLs(_ urls: [URL]) async -> String? {
        guard !isStagingAttachment else { return nil }
        isStagingAttachment = true
        defer { isStagingAttachment = false }
        do {
            return try await MobileAttachmentStager.stageLocalURLs(urls, using: provider)
        } catch {
            previewAlert = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }

    func pageUp() {
        if agentPaneID != nil {
            sendAttachCSI("\u{1b}[5~")
            return
        }
        if let terminalView {
            terminalView.pageUp()
        } else {
            sendKeys(["page_up"])
        }
    }

    func pageDown() {
        if agentPaneID != nil {
            sendAttachCSI("\u{1b}[6~")
            return
        }
        if let terminalView {
            terminalView.pageDown()
        } else {
            sendKeys(["page_down"])
        }
    }

    /// Bytes for `herdr agent attach` itself (wheel / PgUp), not `pane.send_input`.
    func sendAttachCSI(_ text: String) {
        send(ArraySlice(text.utf8))
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
        HostFilePreview.removeAllCachedPreviews()
    }
}

@MainActor
final class TerminalInputChrome: ObservableObject {
    enum IMEItem {
        case partial(String)
        case final(String)
    }

    let dictation = VoiceDictationController()
    let compactBar = HerdrInputAccessory()
    let agentAccessory = HerdrInputAccessory()
    let shellAccessory = HerdrInputAccessory()
    weak var composerView: VoiceComposerTextView?
    private var queue: [IMEItem] = []
    @Published var isRecording = false
    @Published var statusCaption = ""

    init() {
        dictation.onRecordingChange = { [weak self] recording in
            self?.isRecording = recording
            self?.compactBar.setRecording(recording)
            self?.agentAccessory.setRecording(recording)
            self?.shellAccessory.setRecording(recording)
        }
        dictation.onStatus = { [weak self] text in
            self?.statusCaption = text
            self?.compactBar.setStatusCaption(text)
            self?.agentAccessory.setStatusCaption(text)
            self?.shellAccessory.setStatusCaption(text)
        }
        dictation.onPartial = { [weak self] text in
            self?.enqueue(.partial(text))
        }
        dictation.onFinal = { [weak self] text in
            self?.enqueue(.final(text))
        }
    }

    func enqueue(_ item: IMEItem) {
        queue.append(item)
        flush()
    }

    func flush() {
        guard let view = composerView, view.window != nil, view.isFirstResponder else { return }
        let items = queue
        queue.removeAll()
        for item in items {
            switch item {
            case .partial(let text): view.applyIMEPartial(text)
            case .final(let text): view.applyIMEFinal(text)
            }
        }
    }

    func applyLeftover(_ text: String) {
        enqueue(.final(text))
    }
}

struct MobileTerminalScreen: View {
    @StateObject private var session: MobileAttachSession
    @StateObject private var chrome = TerminalInputChrome()
    @State private var composerText: String
    @State private var keyboardShown = false
    @State private var ptyIsTypingTarget = false
    @State private var composerIsFirstResponder = false
    @State private var softwareKeyboardVisible = false
    @State private var showingLinks = false
    @State private var showingTranscriptionHistory = false
    @State private var clipboardHasAttachment = MobileAttachmentStager.clipboardHasAttachment()
    @Environment(\.scenePhase) private var scenePhase
    private let title: String
    private let draftKey: String
    private let onOpenVoiceSettings: () -> Void

    init(
        provider: any MobileTransportProvider,
        cwdProvider: @escaping () -> String?,
        target: TerminalAttachTarget,
        paneID: String,
        title: String,
        draftKey: String,
        onOpenVoiceSettings: @escaping () -> Void = {}
    ) {
        // `StateObject` keeps the first value it is given, so the session must
        // hold the provider (stable per device) rather than a transport (which
        // a reconnect replaces underneath this view).
        _session = StateObject(
            wrappedValue: MobileAttachSession(
                provider: provider,
                cwdProvider: cwdProvider,
                target: target,
                paneID: paneID
            )
        )
        self.title = title
        self.draftKey = draftKey
        self.onOpenVoiceSettings = onOpenVoiceSettings
        _composerText = State(initialValue: ComposerDraftStore.load(draftKey))
    }

    var body: some View {
        ZStack {
            terminalBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                MobileTerminalHost(
                    session: session,
                    keyboardShown: $keyboardShown,
                    ptyIsTypingTarget: $ptyIsTypingTarget,
                    herdrAccessory: chrome.shellAccessory
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                controls
            }
            if session.isFetchingPreview || session.isStagingAttachment {
                ProgressView()
                    .tint(.white)
                    .padding(20)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            if case .ended(let reason) = session.status {
                endedOverlay(reason)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(terminalBackground, for: .navigationBar)
        .alert(
            String(localized: "Couldn’t Preview File"),
            isPresented: Binding(
                get: { session.previewAlert != nil },
                set: { if !$0 { session.previewAlert = nil } }
            ),
            actions: {
                Button(String(localized: "OK"), role: .cancel) { session.previewAlert = nil }
            },
            message: {
                Text(session.previewAlert ?? "")
            }
        )
        .onAppear { wireChrome() }
        .onChange(of: keyboardShown) { _, _ in
            updateKeyboardChrome()
            relayoutTerminal()
        }
        .onChange(of: ptyIsTypingTarget) { _, _ in
            updateKeyboardChrome()
            relayoutTerminal()
        }
        .onChange(of: hideCompactRow) { _, _ in
            relayoutTerminal()
        }
        .onChange(of: showsDraft) { _, _ in
            relayoutTerminal()
        }
        .onChange(of: clipboardHasAttachment) { _, has in
            chrome.compactBar.setPasteEnabled(has)
            chrome.agentAccessory.setPasteEnabled(has)
            chrome.shellAccessory.setPasteEnabled(has)
        }
        .onDisappear {
            chrome.dictation.cancel()
            ComposerDraftStore.save(draftKey, text: composerText)
            session.stop()
            session.discardCollectedLinks()
        }
        .onChange(of: composerText) { _, text in
            ComposerDraftStore.save(draftKey, text: text)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            let terminalFR = session.terminalView?.isFirstResponder == true
            QALog.add("keyboardWillShow terminalFR=\(terminalFR) composerFR=\(composerIsFirstResponder) keyboardShown=\(keyboardShown)")
            if isAgent, terminalFR, !ptyIsTypingTarget {
                return
            }
            softwareKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            QALog.add("keyboardWillHide composerFR=\(composerIsFirstResponder) keyboardShown=\(keyboardShown)")
            softwareKeyboardVisible = false
            // Do not clear `ptyIsTypingTarget` here. Composer → PTY handoff
            // fires willHide while the terminal is already (or about to be)
            // first responder; resigning would abort TUI typing. Swipe-down
            // resigns SwiftTerm, and `onPTYFocusEnded` drops the flag.
            if !ptyIsTypingTarget, !composerIsFirstResponder {
                keyboardShown = false
            }
            relayoutTerminal()
        }
        .sheet(isPresented: $showingLinks) {
            collectedLinksSheet
        }
        .sheet(isPresented: $showingTranscriptionHistory) {
            TranscriptionHistorySheet(onPick: pasteTranscription)
        }
        .onChange(of: scenePhase) { _, phase in
            // The attach cannot outlive a suspension: re-prove the transport
            // and re-attach (`--takeover`) when the session behind it is gone.
            if phase == .active {
                session.resumeAfterForeground()
                clipboardHasAttachment = MobileAttachmentStager.clipboardHasAttachment()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            clipboardHasAttachment = MobileAttachmentStager.clipboardHasAttachment()
        }
    }

    private var terminalBackground: SwiftUI.Color {
        SwiftUI.Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255)
    }

    private var isAgent: Bool { session.agentPaneID != nil }

    private var showsDraft: Bool {
        isAgent && (keyboardShown || (chrome.isRecording && !agentPTYIsTyping) || !composerText.isEmpty)
    }

    private var hideCompactRow: Bool {
        softwareKeyboardVisible && typingTargetIsFirstResponder
    }

    private var agentPTYIsTyping: Bool {
        isAgent && ptyIsTypingTarget && session.terminalView?.isFirstResponder == true
    }

    private var typingTargetIsFirstResponder: Bool {
        if isAgent {
            return agentPTYIsTyping || (!ptyIsTypingTarget && composerIsFirstResponder)
        }
        return session.terminalView?.isFirstResponder == true
    }

    private var keyboardTargetRequested: Bool {
        keyboardShown || ptyIsTypingTarget
    }

    private func updateKeyboardChrome() {
        chrome.compactBar.setKeyboardVisible(keyboardTargetRequested)
        chrome.agentAccessory.setKeyboardVisible(keyboardTargetRequested)
        chrome.shellAccessory.setKeyboardVisible(keyboardTargetRequested)
    }

    private func relayoutTerminal() {
        DispatchQueue.main.async {
            guard let view = session.terminalView else { return }
            view.setNeedsLayout()
            view.layoutIfNeeded()
            QALog.add("relayout terminal bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height)) cols=\(view.getTerminal().cols) rows=\(view.getTerminal().rows)")
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            if isAgent {
                composer
                    .frame(minHeight: showsDraft ? 36 : 0, maxHeight: showsDraft ? 88 : 0)
                    .clipped()
                    .opacity(showsDraft ? 1 : 0)
                    .accessibilityHidden(!showsDraft)
            }
            if !hideCompactRow {
                HerdrToolbarHost(bar: chrome.compactBar)
                    .frame(height: HerdrInputAccessory.barHeight)
                    .accessibilityIdentifier("chrome.toolbar")
            }
            if !hideCompactRow,
               !chrome.statusCaption.isEmpty,
               chrome.statusCaption != String(localized: "Tap to dictate")
            {
                Text(chrome.statusCaption)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { onOpenVoiceSettings() }
                    .accessibilityIdentifier("voice.status")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, hideCompactRow ? 4 : 8)
        .padding(.bottom, hideCompactRow ? 4 : 6)
        .background(.black.opacity(0.35))
        .fixedSize(horizontal: false, vertical: true)
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
                    InAppBrowser.open(url, from: session.terminalView)
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
        HStack(alignment: .bottom, spacing: 8) {
            VoiceComposerField(
                text: $composerText,
                isEditable: showsDraft,
                wantsKeyboard: keyboardShown,
                accessory: chrome.agentAccessory,
                onSubmit: { sendPrompt(submit: true) },
                onPasteAttachments: pasteClipboardAttachment,
                onBeginEditing: {
                    composerIsFirstResponder = true
                    ptyIsTypingTarget = false
                    keyboardShown = true
                    QALog.add("composer beginEditing")
                },
                onEndEditing: {
                    composerIsFirstResponder = false
                    if !ptyIsTypingTarget {
                        keyboardShown = false
                    }
                    QALog.add("composer endEditing")
                },
                onAttach: { view in
                    chrome.composerView = view
                    chrome.flush()
                }
            )
            .padding(.horizontal, 4)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            if showsDraft {
                ComposerSendButton(
                    isEnabled: true,
                    onSend: { sendPrompt(submit: true) },
                    onSendWithoutNewline: { sendPrompt(submit: false) }
                )
                .frame(width: 32, height: 32)
            }
        }
    }

    private func wireChrome() {
        chrome.dictation.contextProvider = {
            DictationContext.capture(
                cwd: session.liveCwd(),
                title: title,
                terminal: session.terminalView
            )
        }
        chrome.dictation.onNeedsSettings = onOpenVoiceSettings
        chrome.dictation.onPartial = { [chrome, session] text in
            if session.agentPaneID != nil {
                if let terminal = session.terminalView as? MobileTerminalUIView,
                   terminal.isPTYTypingTarget, terminal.isFirstResponder
                {
                    // SwiftTerm's marked-text implementation writes to the
                    // attach channel. PTY dictation keeps partials in chrome.
                    chrome.statusCaption = text
                } else {
                    chrome.enqueue(.partial(text))
                }
            } else {
                chrome.statusCaption = text
            }
        }
        chrome.dictation.onFinal = { [chrome, session] text in
            if session.agentPaneID != nil {
                if let terminal = session.terminalView as? MobileTerminalUIView,
                   terminal.isPTYTypingTarget, terminal.isFirstResponder
                {
                    session.sendText(text)
                } else {
                    chrome.enqueue(.final(text))
                }
            } else {
                session.terminalView?.insertText(text)
            }
        }
        let wire: (HerdrInputAccessory) -> Void = { accessory in
            accessory.onMicToggle = { toggleDictation() }
            accessory.onMicHoldStart = { Task { await startDictation() } }
            accessory.onMicHoldStop = { Task { await stopDictation(waitForTrailing: true) } }
            accessory.onPasteTranscription = { pasteTranscription($0) }
            accessory.onShowTranscriptionHistory = { showingTranscriptionHistory = true }
            accessory.onSendKeys = { keys in
                if keys == ["page_up"] {
                    session.pageUp()
                } else if keys == ["page_down"] {
                    session.pageDown()
                } else {
                    session.sendKeys(keys)
                }
            }
            accessory.onPaste = { pasteClipboardAttachment() }
            accessory.onShareLogs = { presentQALog() }
            accessory.onToggleKeyboard = {
                if isAgent, ptyIsTypingTarget {
                    ptyIsTypingTarget = false
                    keyboardShown = false
                    _ = session.terminalView?.resignFirstResponder()
                } else {
                    keyboardShown.toggle()
                }
                QALog.add("keyboardShown -> \(keyboardShown)")
                if !keyboardShown {
                    _ = chrome.composerView?.resignFirstResponder()
                    if !isAgent {
                        _ = session.terminalView?.resignFirstResponder()
                    }
                }
            }
            accessory.setKeyboardVisible(keyboardTargetRequested)
            accessory.setPasteEnabled(clipboardHasAttachment)
        }
        wire(chrome.compactBar)
        wire(chrome.agentAccessory)
        wire(chrome.shellAccessory)
    }

    private func presentQALog() {
        Task {
            do {
                let url = try QALog.fileURL()
                defer { try? FileManager.default.removeItem(at: url) }
                guard let paths = await session.stageLocalURLs([url]) else { return }
                insertComposerText(paths)
                QALog.add("attached log \(paths)")
            } catch {
                session.previewAlert = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    private func toggleDictation() {
        if chrome.dictation.isRecording {
            Task { await stopDictation(waitForTrailing: true) }
        } else {
            Task { await startDictation() }
        }
    }

    private func startDictation() async {
        if isAgent {
            if !agentPTYIsTyping {
                ptyIsTypingTarget = false
                keyboardShown = true
            }
        } else {
            keyboardShown = true
        }
        await chrome.dictation.start()
        if !agentPTYIsTyping {
            chrome.flush()
        }
    }

    private func stopDictation(waitForTrailing: Bool) async {
        let leftover = await chrome.dictation.stop(waitForTrailingFinal: waitForTrailing)
        if agentPTYIsTyping {
            if !leftover.isEmpty {
                session.sendText(leftover)
            }
        } else if isAgent {
            chrome.composerView?.commitMarkedIfNeeded()
            if !leftover.isEmpty {
                chrome.applyLeftover(leftover)
            }
        } else if !leftover.isEmpty {
            session.terminalView?.insertText(leftover)
        }
    }

    private func pasteTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if agentPTYIsTyping {
            session.sendText(trimmed)
        } else if isAgent {
            insertComposerText(trimmed)
            keyboardShown = true
        } else {
            session.terminalView?.insertText(trimmed)
        }
    }

    private func sendPrompt(submit: Bool) {
        Task { @MainActor in
            if chrome.dictation.isRecording {
                await stopDictation(waitForTrailing: false)
            }
            chrome.composerView?.commitMarkedIfNeeded()
            let text = (chrome.composerView?.unmarkedText ?? composerText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                guard submit else { return }
                session.sendKeys(["enter"])
                return
            }
            if submit {
                session.prompt(text)
            } else {
                session.sendText(text)
            }
            InputHistoryStore.append(text: text, paneID: session.paneID, title: title)
            composerText = ""
            chrome.composerView?.text = ""
            ComposerDraftStore.save(draftKey, text: "")
        }
    }

    private func pasteClipboardAttachment() {
        Task {
            guard let paths = await session.stageClipboardPaths() else { return }
            if session.agentPaneID != nil {
                insertComposerText(paths)
            } else {
                session.send(Array(paths.utf8)[...])
            }
        }
    }

    private func insertComposerText(_ chunk: String) {
        if let view = chrome.composerView, view.isFirstResponder {
            if !(view.unmarkedText.isEmpty || view.unmarkedText.hasSuffix(" ") || view.unmarkedText.hasSuffix("\n")) {
                view.insertText(" ")
            }
            view.insertText(chunk)
            view.republishUnmarked()
            return
        }
        if composerText.isEmpty || composerText.hasSuffix(" ") || composerText.hasSuffix("\n") {
            composerText += chunk
        } else {
            composerText += " " + chunk
        }
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
/// into terminal scrolling. Agent panes send wheel / page CSI to the attach
/// PTY so `herdr agent attach` can scroll pane history or forward mouse to a
/// TUI. Shell panes still use SGR mouse wheel when tracking is on.
final class MobileTerminalUIView: TerminalView, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate, UIEditMenuInteractionDelegate {
    private struct LinkHit {
        let link: DetectedLink
        let displayText: String
        let rects: [CGRect]

        var rect: CGRect {
            rects.reduce(CGRect.null) { $0.union($1) }
        }
    }

    private var scrollPanGesture: UIPanGestureRecognizer?
    private var accumulatedScrollDelta: CGFloat = 0
    /// `numberOfTouches` is 0 in `.ended`; remember two-finger from the drag.
    private var panIsTwoFinger = false
    weak var attachSession: MobileAttachSession?
    var isAgentPane = false
    var isPTYTypingTarget = false
    var herdrAccessory: UIView?
    var onRequestPTYFocus: (() -> Void)?
    var onPTYFocusEnded: (() -> Void)?
    private var lastLinkHit: LinkHit?
    private var highlightOverlay: UIView?
    private var focusTap: UITapGestureRecognizer?
    private var presentingContextMenu = false

    private static let dummyKeyboard: UIInputView = {
        let view = UIInputView(
            frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 0),
            inputViewStyle: .keyboard
        )
        view.allowsSelfSizing = true
        return view
    }()

    func applyInputChrome() {
        if isAgentPane {
            inputAccessoryView = isPTYTypingTarget ? herdrAccessory : nil
            inputView = isFirstResponder && !isPTYTypingTarget ? Self.dummyKeyboard : nil
        } else {
            inputAccessoryView = herdrAccessory
            inputView = nil
        }
        if isFirstResponder {
            reloadInputViews()
        }
    }

    override func insertText(_ text: String) {
        if isAgentPane {
            guard isPTYTypingTarget else { return }
            sendAgentTyping(text)
            return
        }
        super.insertText(text)
    }

    /// Claude Code (Ink `useInput`) matches number/y/n pickers on real
    /// keypresses. herdr's `text` path is bracketed paste, so `sendText("1")`
    /// never selects option 1.
    private func sendAgentTyping(_ text: String) {
        if text == "\n" || text == "\r" || text == "\r\n" {
            attachSession?.sendKeys(["enter"])
            return
        }
        if text == " " || text == "\u{00A0}" {
            attachSession?.sendKeys(["space"])
            return
        }
        let keys = text.compactMap { Self.herdrTypingKey(for: $0) }
        if !keys.isEmpty, keys.count == text.count {
            attachSession?.sendKeys(keys)
            return
        }
        attachSession?.sendText(text)
    }

    private static func herdrTypingKey(for character: Character) -> String? {
        if character == "\n" || character == "\r" { return "enter" }
        if character == "\t" { return "tab" }
        if character == " " || character == "\u{00A0}" { return "space" }
        if character.unicodeScalars.count == 1,
           let scalar = character.unicodeScalars.first
        {
            if scalar.isASCII, scalar.value >= 32, scalar.value < 127 {
                return String(character)
            }
            // iOS Chinese keyboards often emit fullwidth digits.
            if scalar.value >= 0xFF10, scalar.value <= 0xFF19 {
                return String(UnicodeScalar(UInt32(scalar.value - 0xFF10 + 48))!)
            }
        }
        return nil
    }

    override func deleteBackward() {
        if isAgentPane {
            guard isPTYTypingTarget else { return }
            attachSession?.sendKeys(["backspace"])
            return
        }
        super.deleteBackward()
    }

    override func paste(_ sender: Any?) {
        if isAgentPane {
            guard isPTYTypingTarget else { return }
            if let text = UIPasteboard.general.string, !text.isEmpty {
                attachSession?.sendText(text)
            }
            return
        }
        super.paste(sender)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTouchScrolling()
        installLinkMenus()
        installFocusTap()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTouchScrolling()
        installLinkMenus()
        installFocusTap()
    }

    private func installFocusTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        focusTap = tap
        preferScrollOverTaps()
    }

    @objc private func handleFocusTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard !isSelectionOrMenuActive else { return }
        let location = gesture.location(in: self)
        if isAgentPane, let key = optionKey(at: location) {
            attachSession?.sendKeys([key])
            QALog.add("terminal tap option=\(key)")
        }
        QALog.add("terminal tap requestPTYFocus agent=\(isAgentPane)")
        onRequestPTYFocus?()
    }

    /// Claude Code / Ink numbered pickers listen for keypresses 1-9 (and
    /// mouse, which we cannot inject through pane.send_input). A tap that
    /// is not a scroll hits the visible row and sends that option's key.
    private func optionKey(at location: CGPoint) -> String? {
        let terminal = getTerminal()
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        let cellW = max(1, bounds.width / CGFloat(cols))
        let cellH = max(12, bounds.height / CGFloat(rows))
        let col = max(0, min(cols - 1, Int(location.x / cellW)))
        let row = max(0, min(rows - 1, Int(location.y / cellH)))
        var line = ""
        line.reserveCapacity(cols)
        for c in 0..<cols {
            line.append(terminal.getCharacter(col: c, row: row) ?? " ")
        }
        return Self.tuiOptionKey(in: line, tappedColumn: col)
    }

    static func tuiOptionKey(in line: String, tappedColumn: Int) -> String? {
        let chars = Array(line)
        if tappedColumn >= 0, tappedColumn < chars.count,
           let key = asciiOptionDigit(chars[tappedColumn]),
           isOptionMarker(chars: chars, at: tappedColumn)
        {
            return key
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let start = trimmed.startIndex
        var i = start
        while i < trimmed.endIndex, "❯▸>●*- \t".contains(trimmed[i]) {
            i = trimmed.index(after: i)
        }
        guard i < trimmed.endIndex else { return nil }
        if trimmed[i] == "[" {
            let next = trimmed.index(after: i)
            guard next < trimmed.endIndex, let key = asciiOptionDigit(trimmed[next]) else { return nil }
            let after = trimmed.index(after: next)
            if after < trimmed.endIndex, trimmed[after] == "]" { return key }
            return key
        }
        guard let key = asciiOptionDigit(trimmed[i]) else { return nil }
        let after = trimmed.index(after: i)
        if after == trimmed.endIndex { return key }
        let mark = trimmed[after]
        if ".):] \t".contains(mark) { return key }
        return nil
    }

    private static func asciiOptionDigit(_ character: Character) -> String? {
        if character >= "1", character <= "9" { return String(character) }
        if let scalar = character.unicodeScalars.first,
           scalar.value >= 0xFF11, scalar.value <= 0xFF19
        {
            return String(UnicodeScalar(UInt32(scalar.value - 0xFF10 + 48))!)
        }
        return nil
    }

    private static func isOptionMarker(chars: [Character], at index: Int) -> Bool {
        let next = index + 1
        if next < chars.count, ".):]".contains(chars[next]) { return true }
        if index > 0, chars[index - 1] == "[" { return true }
        return false
    }

    override func becomeFirstResponder() -> Bool {
        if isAgentPane, !isPTYTypingTarget {
            // Long-press copy/select may make SwiftTerm first responder before
            // SwiftUI has a chance to update. Keep its zero-height input view
            // only for that non-typing state.
            inputAccessoryView = nil
            inputView = Self.dummyKeyboard
        }
        let ok = super.becomeFirstResponder()
        if ok, isAgentPane, isPTYTypingTarget {
            applyInputChrome()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isAgentPane {
            onPTYFocusEnded?()
        }
        return resigned
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isAgentPane, isPTYTypingTarget else {
            super.pressesBegan(presses, with: event)
            return
        }

        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key,
                  !key.modifierFlags.contains(.command),
                  let namedKey = Self.herdrKey(for: key)
            else {
                unhandled.insert(press)
                continue
            }
            attachSession?.sendKeys([namedKey])
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    private static func herdrKey(for key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardReturnOrEnter:
            return "enter"
        case .keyboardDeleteOrBackspace:
            return "backspace"
        case .keyboardUpArrow:
            return "up"
        case .keyboardDownArrow:
            return "down"
        case .keyboardLeftArrow:
            return "left"
        case .keyboardRightArrow:
            return "right"
        case .keyboardPageUp:
            return "page_up"
        case .keyboardPageDown:
            return "page_down"
        case .keyboardHome:
            return "home"
        case .keyboardEnd:
            return "end"
        case .keyboardDeleteForward:
            return "delete"
        case .keyboardEscape:
            return "esc"
        case .keyboardTab:
            return "tab"
        case .keyboardSpacebar:
            return "space"
        case .keyboardF1:
            return "f1"
        case .keyboardF2:
            return "f2"
        case .keyboardF3:
            return "f3"
        case .keyboardF4:
            return "f4"
        case .keyboardF5:
            return "f5"
        case .keyboardF6:
            return "f6"
        case .keyboardF7:
            return "f7"
        case .keyboardF8:
            return "f8"
        case .keyboardF9:
            return "f9"
        case .keyboardF10:
            return "f10"
        default:
            guard key.modifierFlags.contains(.control) else { return nil }
            let character = key.charactersIgnoringModifiers.lowercased()
            guard character.utf8.count == 1,
                  let scalar = character.unicodeScalars.first,
                  scalar.isASCII, scalar.properties.isAlphabetic
            else { return nil }
            return "ctrl+\(character)"
        }
    }

    var isSelectionOrMenuActive: Bool {
        selection.active || presentingContextMenu
    }

    private func installLinkMenus() {
        addInteraction(UIEditMenuInteraction(delegate: self))
        addInteraction(UIContextMenuInteraction(delegate: self))
        // UIContextMenuInteraction does not expose its recognizer. After it
        // attaches, pick the shortest long-press (the system menu, ~0.5s) and
        // make SwiftTerm's 0.7s Select press wait for it.
        let longPresses = (gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer }
        guard let menuPress = longPresses.min(by: { $0.minimumPressDuration < $1.minimumPressDuration }) else {
            return
        }
        for lp in longPresses where lp !== menuPress {
            lp.require(toFail: menuPress)
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let hit = linkHit(at: location) else {
            lastLinkHit = nil
            presentingContextMenu = false
            return nil
        }
        lastLinkHit = hit
        presentingContextMenu = true
        let link = hit.link
        let display = hit.displayText
        return UIContextMenuConfiguration(
            identifier: display as NSString,
            previewProvider: { LinkPreviewCardController(link: link) },
            actionProvider: { [weak self] _ in
                self?.menu(for: link)
            }
        )
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        highlightPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        liftedLinkPreview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemWithIdentifier identifier: any NSCopying
    ) -> UITargetedPreview? {
        liftedLinkPreview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        animator?.addCompletion { [weak self] in
            self?.highlightOverlay?.removeFromSuperview()
            self?.highlightOverlay = nil
            self?.lastLinkHit = nil
            self?.presentingContextMenu = false
        }
    }

    private func parseLink(_ raw: String) -> DetectedLink? {
        DetectedLink.parse(
            raw,
            cwd: attachSession?.liveCwd(),
            home: attachSession?.remoteHome
        )
    }

    private func linkHit(at location: CGPoint) -> LinkHit? {
        let terminal = getTerminal()
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        let cellW = max(1, bounds.width / CGFloat(cols))
        let cellH = max(1, bounds.height / CGFloat(rows))
        let col = max(0, min(cols - 1, Int(location.x / cellW)))
        let row = max(0, min(rows - 1, Int(location.y / cellH)))

        if let raw = terminal.link(
            at: .screen(Position(col: col, row: row)),
            mode: .explicitAndImplicit
        ), let link = parseLink(raw) {
            let display = previewString(for: link, fallback: raw)
            let rects = wrappedRects(
                covering: raw,
                tapRow: row,
                tapCol: col,
                cols: cols,
                rows: rows,
                terminal: terminal,
                cellW: cellW,
                cellH: cellH
            )
            return LinkHit(link: link, displayText: display, rects: rects)
        }
        if selection.active, let link = parseLink(selection.getSelectedText()) {
            let display = previewString(for: link, fallback: selection.getSelectedText())
            guard !display.isEmpty else { return nil }
            let yDisp = terminal.buffer.yDisp
            let startRow = selection.start.row - yDisp
            let endRow = selection.end.row - yDisp
            var rects: [CGRect] = []
            if startRow == row || endRow == row || (min(startRow, endRow)...max(startRow, endRow)).contains(row) {
                let lo = min(startRow, endRow)
                let hi = max(startRow, endRow)
                for r in lo...hi where r >= 0 && r < rows {
                    let startCol = r == startRow ? selection.start.col : 0
                    let endCol = r == endRow ? selection.end.col + 1 : cols
                    rects.append(cellRect(startCol: startCol, endCol: endCol, row: r, cellW: cellW, cellH: cellH))
                }
            }
            if rects.isEmpty {
                let span = columnSpan(of: display, inScreenRow: row, tapCol: col, cols: cols, terminal: terminal)
                rects = [cellRect(startCol: span.start, endCol: span.end, row: row, cellW: cellW, cellH: cellH)]
            }
            return LinkHit(link: link, displayText: display, rects: rects)
        }
        return nil
    }

    private func previewString(for link: DetectedLink, fallback: String) -> String {
        let value: String
        switch link {
        case .web(let url):
            value = url.absoluteString
        case .hostFile(let path):
            value = path
        }
        return value.isEmpty ? fallback : value
    }

    private func wrappedRects(
        covering raw: String,
        tapRow: Int,
        tapCol: Int,
        cols: Int,
        rows: Int,
        terminal: Terminal,
        cellW: CGFloat,
        cellH: CGFloat
    ) -> [CGRect] {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = (0..<rows).map { screenLine(row: $0, cols: cols, terminal: terminal) }
        let visible = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) as NSString }
        var offsets: [Int] = []
        var total = 0
        for s in visible {
            offsets.append(total)
            total += s.length
        }
        let joined = visible.reduce(into: "") { $0 += $1 as String } as NSString
        var search = NSRange(location: 0, length: joined.length)
        var chosen: NSRange?
        let tapOffset = offsets.indices.contains(tapRow)
            ? offsets[tapRow] + min(max(0, tapCol), max(0, visible[tapRow].length))
            : 0
        while !needle.isEmpty {
            let found = joined.range(of: needle, options: [], range: search)
            if found.location == NSNotFound { break }
            if NSLocationInRange(tapOffset, found)
                || abs(Int(found.location) - tapOffset)
                < abs(Int((chosen ?? NSRange(location: Int.max, length: 0)).location) - tapOffset)
            {
                chosen = found
                if NSLocationInRange(tapOffset, found) { break }
            }
            let next = found.location + max(1, found.length)
            if next >= joined.length { break }
            search = NSRange(location: next, length: joined.length - next)
        }

        if let match = chosen {
            var rects: [CGRect] = []
            for (row, text) in visible.enumerated() {
                let start = offsets[row]
                let end = start + text.length
                let overlapStart = max(match.location, start)
                let overlapEnd = min(match.location + match.length, end)
                if overlapStart < overlapEnd {
                    rects.append(
                        cellRect(
                            startCol: overlapStart - start,
                            endCol: overlapEnd - start,
                            row: row,
                            cellW: cellW,
                            cellH: cellH
                        )
                    )
                }
            }
            if !rects.isEmpty { return rects }
        }

        let token = onScreenToken(raw: raw, screenRow: tapRow, tapCol: tapCol, cols: cols, terminal: terminal)
        let span = columnSpan(of: token, inScreenRow: tapRow, tapCol: tapCol, cols: cols, terminal: terminal)
        return [cellRect(startCol: span.start, endCol: span.end, row: tapRow, cellW: cellW, cellH: cellH)]
    }

    private func screenLine(row: Int, cols: Int, terminal: Terminal) -> String {
        let y = terminal.buffer.yDisp + row
        return terminal.getText(
            start: Position(col: 0, row: y),
            end: Position(col: max(0, cols - 1), row: y)
        ).trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
    }

    /// Text actually visible at the press, not the resolved absolute path.
    private func onScreenToken(raw: String, screenRow: Int, tapCol: Int, cols: Int, terminal: Terminal) -> String {
        let line = screenLine(row: screenRow, cols: cols, terminal: terminal)
        if line.contains(raw) { return raw }
        let base = (raw as NSString).lastPathComponent
        if !base.isEmpty, line.contains(base) { return base }
        return tokenAt(column: tapCol, in: line) ?? base
    }

    private func columnSpan(of token: String, inScreenRow row: Int, tapCol: Int, cols: Int, terminal: Terminal) -> (start: Int, end: Int) {
        let line = screenLine(row: row, cols: cols, terminal: terminal)
        let ns = line as NSString
        let tap = min(max(0, tapCol), max(0, ns.length - 1))
        var found = NSRange(location: NSNotFound, length: 0)
        if !token.isEmpty {
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: token, options: [], range: search)
                if r.location == NSNotFound { break }
                if NSLocationInRange(tap, r) || abs(Int(r.location) - tapCol) < abs(Int(found.location == NSNotFound ? Int.max : found.location) - tapCol) {
                    found = r
                    if NSLocationInRange(tap, r) { break }
                }
                let next = r.location + max(1, r.length)
                if next >= ns.length { break }
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        if found.location != NSNotFound {
            let start = max(0, found.location)
            let end = min(cols, found.location + found.length)
            if start < end { return (start, end) }
        }
        let width = min(cols, max(1, (token as NSString).length))
        let start = max(0, min(tapCol, cols - width))
        return (start, start + width)
    }

    private func tokenAt(column: Int, in line: String) -> String? {
        let ns = line as NSString
        guard ns.length > 0 else { return nil }
        let i = min(max(0, column), ns.length - 1)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+/@~"))
        var start = i
        var end = i
        while start > 0 {
            let ch = ns.character(at: start - 1)
            guard let scalar = UnicodeScalar(ch), allowed.contains(scalar) else { break }
            start -= 1
        }
        while end < ns.length {
            let ch = ns.character(at: end)
            guard let scalar = UnicodeScalar(ch), allowed.contains(scalar) else { break }
            end += 1
        }
        guard start < end else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private func cellRect(startCol: Int, endCol: Int, row: Int, cellW: CGFloat, cellH: CGFloat) -> CGRect {
        let start = max(0, startCol)
        let end = max(start + 1, endCol)
        return CGRect(
            x: CGFloat(start) * cellW,
            y: CGFloat(row) * cellH,
            width: CGFloat(end - start) * cellW,
            height: cellH
        ).insetBy(dx: -2, dy: -1)
    }

    /// Lift a blue highlight over every wrapped URL cell; the card is previewProvider.
    private func liftedLinkPreview() -> UITargetedPreview? {
        guard let hit = lastLinkHit else { return nil }
        let overlay = installHighlight(for: hit)
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        params.visiblePath = UIBezierPath(roundedRect: overlay.bounds, cornerRadius: 6)
        return UITargetedPreview(view: overlay, parameters: params)
    }

    private func installHighlight(for hit: LinkHit) -> UIView {
        highlightOverlay?.removeFromSuperview()
        let union = hit.rect.integral
        let overlay = UIView(frame: union)
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        let path = UIBezierPath()
        for rect in hit.rects {
            path.append(UIBezierPath(roundedRect: overlay.convert(rect, from: self), cornerRadius: 4))
        }
        let fill = CAShapeLayer()
        fill.path = path.cgPath
        fill.fillColor = UIColor.systemBlue.withAlphaComponent(0.28).cgColor
        overlay.layer.addSublayer(fill)
        let stroke = CAShapeLayer()
        stroke.path = path.cgPath
        stroke.fillColor = UIColor.clear.cgColor
        stroke.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85).cgColor
        stroke.lineWidth = 1.5
        overlay.layer.addSublayer(stroke)
        addSubview(overlay)
        highlightOverlay = overlay
        return overlay
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        var actions = suggestedActions
        if selection.active, let link = parseLink(selection.getSelectedText()) {
            actions.append(contentsOf: menu(for: link).children)
        }
        return UIMenu(children: actions)
    }

    private func menu(for link: DetectedLink) -> UIMenu {
        switch link {
        case .web(let url):
            return linkMenu(for: url)
        case .hostFile(let path):
            return hostFileMenu(for: path)
        }
    }

    private func hostFileMenu(for path: String) -> UIMenu {
        let preview = UIAction(
            title: String(localized: "Preview"),
            image: UIImage(systemName: "eye")
        ) { [weak self] _ in
            guard let self else { return }
            self.attachSession?.previewHostFile(path, from: self)
        }
        let copy = UIAction(
            title: String(localized: "Copy Path"),
            image: UIImage(systemName: "doc.on.doc")
        ) { _ in
            UIPasteboard.general.string = path
        }
        return UIMenu(children: [preview, copy])
    }

    private func linkMenu(for url: URL) -> UIMenu {
        let open = UIAction(title: String(localized: "Open"), image: UIImage(systemName: "safari")) { [weak self] _ in
            InAppBrowser.open(url, from: self)
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
        preferScrollOverTaps()
    }

    /// SwiftTerm's 1-finger tap and the PTY-focus tap must wait for a pan to
    /// fail, otherwise a two-finger drag is eaten as a tap / first-responder hop.
    private func preferScrollOverTaps() {
        guard let pan = scrollPanGesture else { return }
        for recognizer in gestureRecognizers ?? [] {
            guard let tap = recognizer as? UITapGestureRecognizer else { continue }
            tap.require(toFail: pan)
        }
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
        gestureRecognizer == focusTap || otherGestureRecognizer == focusTap
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            accumulatedScrollDelta = 0
            panIsTwoFinger = gesture.numberOfTouches >= 2

        case .changed:
            if gesture.numberOfTouches >= 2 {
                panIsTwoFinger = true
            }
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            accumulatedScrollDelta += translation.y

            let terminal = getTerminal()
            let rowHeight = max(12, bounds.height / CGFloat(max(1, terminal.rows)))
            let reportsMouse = allowMouseReporting && terminal.mouseMode != .off
            let isAgent = attachSession?.agentPaneID != nil

            // In herdr and tmux, each mouse wheel event typically moves 3 rows.
            // A threshold of ~24pt gives a natural 1:1 feel under the user's thumb.
            let threshold = (!isAgent && reportsMouse) ? max(20, rowHeight * 1.5) : max(12, rowHeight)

            if abs(accumulatedScrollDelta) >= threshold {
                let steps = Int(accumulatedScrollDelta / threshold)
                accumulatedScrollDelta -= CGFloat(steps) * threshold
                let scrollingUp = steps > 0
                applyScroll(
                    up: scrollingUp,
                    steps: abs(steps),
                    twoFinger: panIsTwoFinger,
                    at: gesture.location(in: self)
                )
            }

        case .ended:
            // Momentum: if user flicked with noticeable velocity, send a small burst of scroll steps
            let velocity = gesture.velocity(in: self).y
            if abs(velocity) > 800 {
                let extraSteps = min(8, Int(abs(velocity) / 400))
                applyScroll(
                    up: velocity > 0,
                    steps: extraSteps,
                    twoFinger: panIsTwoFinger,
                    at: gesture.location(in: self)
                )
            }
            accumulatedScrollDelta = 0
            panIsTwoFinger = false

        case .cancelled:
            accumulatedScrollDelta = 0
            panIsTwoFinger = false

        default:
            break
        }
    }

    /// Finger dragging down (positive translation.y) shows earlier content.
    private func applyScroll(up: Bool, steps: Int, twoFinger: Bool, at location: CGPoint) {
        let magnitude = max(1, steps)
        let terminal = getTerminal()
        let reportsMouse = allowMouseReporting && terminal.mouseMode != .off
        let isAgent = attachSession?.agentPaneID != nil
        let alternate = scrollThumbsize == 0
        QALog.add("scroll up=\(up) steps=\(magnitude) twoFinger=\(twoFinger) mouse=\(reportsMouse) alt=\(alternate) thumb=\(scrollThumbsize)")

        // herdr agent attach owns scrollback. Local SwiftTerm only has the
        // painted viewport, so scrollUp is a no-op. Wheel and PgUp/PgDn CSI
        // on the attach PTY let herdr scroll — or forward mouse to a TUI.
        if isAgent {
            if reportsMouse {
                sendMouseWheel(up: up, times: twoFinger ? max(3, magnitude) : magnitude, at: location)
            } else {
                attachSession?.sendAttachCSI(up ? "\u{1b}[5~" : "\u{1b}[6~")
            }
            return
        }

        if reportsMouse {
            sendMouseWheel(up: up, times: twoFinger ? max(3, magnitude) : magnitude, at: location)
            return
        }
        if twoFinger || alternate {
            send(txt: up ? "\u{1b}[5~" : "\u{1b}[6~")
            return
        }
        if up {
            scrollUp(lines: magnitude)
        } else {
            scrollDown(lines: magnitude)
        }
    }

    private func sendMouseWheel(up: Bool, times: Int, at location: CGPoint) {
        let terminal = getTerminal()
        let colWidth = max(1, bounds.width / CGFloat(max(1, terminal.cols)))
        let rowHeight = max(12, bounds.height / CGFloat(max(1, terminal.rows)))
        let col = max(0, min(terminal.cols - 1, Int(location.x / colWidth)))
        let row = max(0, min(terminal.rows - 1, Int(location.y / rowHeight)))
        let buttonFlags = terminal.encodeButton(
            button: up ? 4 : 5,
            release: false,
            shift: false,
            meta: false,
            control: false
        )
        for _ in 0..<times {
            terminal.sendEvent(
                buttonFlags: buttonFlags,
                x: col,
                y: row,
                pixelX: Int(location.x),
                pixelY: Int(location.y)
            )
        }
    }
}

/// UIKit host for SwiftTerm's iOS TerminalView, wired to the attach session.
private struct MobileTerminalHost: UIViewRepresentable {
    let session: MobileAttachSession
    @Binding var keyboardShown: Bool
    @Binding var ptyIsTypingTarget: Bool
    var herdrAccessory: UIView?

    func makeUIView(context: Context) -> TerminalView {
        let view = MobileTerminalUIView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.backgroundColor = UIColor(red: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255, alpha: 1)
        view.nativeBackgroundColor = view.backgroundColor ?? .black
        view.nativeForegroundColor = UIColor(red: 0xD6 / 255, green: 0xD6 / 255, blue: 0xD6 / 255, alpha: 1)
        session.terminalView = view
        let mobile = view
        mobile.attachSession = session
        mobile.isAgentPane = session.agentPaneID != nil
        mobile.isPTYTypingTarget = ptyIsTypingTarget
        mobile.herdrAccessory = herdrAccessory
        mobile.onRequestPTYFocus = {
            if session.agentPaneID != nil {
                ptyIsTypingTarget = true
                keyboardShown = false
            } else {
                keyboardShown = true
            }
            QALog.add("onRequestPTYFocus agent=\(session.agentPaneID != nil)")
        }
        mobile.onPTYFocusEnded = {
            if ptyIsTypingTarget {
                ptyIsTypingTarget = false
            }
        }
        mobile.applyInputChrome()
        let terminal = view.getTerminal()
        session.start(columns: terminal.cols, rows: terminal.rows)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        if let mobile = uiView as? MobileTerminalUIView {
            mobile.attachSession = session
            mobile.isAgentPane = session.agentPaneID != nil
            mobile.isPTYTypingTarget = ptyIsTypingTarget
            mobile.herdrAccessory = herdrAccessory
            mobile.onRequestPTYFocus = {
                if session.agentPaneID != nil {
                    ptyIsTypingTarget = true
                    keyboardShown = false
                } else {
                    keyboardShown = true
                }
                QALog.add("onRequestPTYFocus agent=\(session.agentPaneID != nil)")
            }
            mobile.onPTYFocusEnded = {
                if ptyIsTypingTarget {
                    ptyIsTypingTarget = false
                }
            }
            mobile.applyInputChrome()
        }
        let isAgent = session.agentPaneID != nil
        if isAgent {
            if ptyIsTypingTarget,
               !uiView.isFirstResponder,
               (uiView as? MobileTerminalUIView)?.isSelectionOrMenuActive != true
            {
                _ = uiView.becomeFirstResponder()
            }
            return
        }
        if keyboardShown, !uiView.isFirstResponder {
            _ = uiView.becomeFirstResponder()
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
            Task { @MainActor in
                // Agent typing uses pane.send_input. ESC sequences (SGR wheel,
                // PgUp/PgDn) still belong on the attach PTY.
                if self.session.agentPaneID != nil, bytes.first != 0x1b { return }
                self.session.send(bytes[...])
            }
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
