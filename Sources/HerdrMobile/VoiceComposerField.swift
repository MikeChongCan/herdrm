import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class VoiceDictationController {
    private let client = GeminiLiveTranscribeClient()
    private let capture = PCM16kCapture()
    private var sendTask: Task<Void, Never>?
    private var chunkStream: AsyncStream<Data>.Continuation?
    private var lastPartial = ""
    private var acceptedFinals: [String] = []
    private var lastEmittedFinal = ""
    private(set) var isRecording = false
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var onNeedsSettings: (() -> Void)?
    var contextProvider: () -> DictationContext = { .empty }

    func toggle() {
        if isRecording {
            Task { _ = await stop(waitForTrailingFinal: true) }
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isRecording else { return }
        guard let apiKey = GeminiAPIKeyStore.load() else {
            onStatus?(String(localized: "Add a Gemini API key in Settings."))
            onNeedsSettings?()
            return
        }

        if AVAudioApplication.shared.recordPermission != .granted {
            let granted = await requestMic()
            guard granted else {
                onStatus?(String(localized: "Microphone access is required."))
                return
            }
        }

        lastPartial = ""
        acceptedFinals = []
        lastEmittedFinal = ""
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true
        RecordHaptics.started()
        onRecordingChange?(true)
        onStatus?(String(localized: "Listening…"))
        QALog.add("dictation start")

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        chunkStream = continuation
        do {
            try capture.start { data in
                continuation.yield(data)
            }
        } catch {
            await abortStart(error.localizedDescription)
            return
        }

        let context = contextProvider()
        sendTask = Task { [client] in
            do {
                try await client.connect(apiKey: apiKey, context: context) { event in
                    Task { @MainActor in
                        self.handle(event)
                    }
                }
                for await chunk in stream {
                    try await client.sendPCM16(chunk)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    self?.onStatus?(error.localizedDescription)
                    Task { _ = await self?.stop(waitForTrailingFinal: false) }
                }
            }
        }
    }

    private func abortStart(_ message: String) async {
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        onRecordingChange?(false)
        capture.stop()
        chunkStream?.finish()
        chunkStream = nil
        sendTask?.cancel()
        sendTask = nil
        await client.disconnect()
        onStatus?(message)
        RecordHaptics.stopped()
        QALog.add("dictation abort: \(message)")
    }

    /// Stops capture. Leftover is returned and is **not** sent through `onFinal`.
    func stop(waitForTrailingFinal: Bool) async -> String {
        guard isRecording else { return "" }
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        onRecordingChange?(false)
        capture.stop()
        chunkStream?.finish()
        chunkStream = nil
        sendTask?.cancel()
        sendTask = nil
        RecordHaptics.stopped()
        QALog.add("dictation stop waitTrailing=\(waitForTrailingFinal)")
        try? await client.endAudioStream()
        if waitForTrailingFinal {
            onStatus?(String(localized: "Transcribing…"))
            try? await Task.sleep(for: .milliseconds(800))
        }
        let leftover = takeLeftover()
        await client.disconnect()
        onStatus?(String(localized: "Tap to dictate"))
        return leftover
    }

    /// Tear down without inserting leftover into the field.
    func cancel() {
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        onRecordingChange?(false)
        capture.stop()
        chunkStream?.finish()
        chunkStream = nil
        sendTask?.cancel()
        sendTask = nil
        lastPartial = ""
        Task { await client.disconnect() }
        onStatus?(String(localized: "Tap to dictate"))
        QALog.add("dictation cancel")
    }

    private func handle(_ event: GeminiLiveTranscriptEvent) {
        switch event {
        case .ready:
            break
        case .partial(let text):
            lastPartial = text
            QALog.add("ime partial \(text.count)c")
            onPartial?(text)
            onStatus?(text)
        case .final(let text):
            if text == lastEmittedFinal { return }
            lastEmittedFinal = text
            acceptedFinals.append(text)
            lastPartial = ""
            QALog.add("ime final \(text.count)c")
            onFinal?(text)
            if isRecording {
                onStatus?(String(localized: "Listening…"))
            }
        case .failed(let message):
            onStatus?(message)
            if isRecording { Task { _ = await stop(waitForTrailingFinal: false) } }
        }
    }

    private func takeLeftover() -> String {
        let leftover = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPartial = ""
        guard !leftover.isEmpty else { return "" }
        if acceptedFinals.contains(where: { leftover.hasPrefix($0) || $0.hasPrefix(leftover) }) {
            return ""
        }
        if leftover == lastEmittedFinal { return "" }
        return leftover
    }

    private func requestMic() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

final class VoiceComposerTextView: UITextView {
    var onSubmit: (() -> Void)?
    var onPasteAttachments: (() -> Void)?
    var onUnmarkedChange: ((String) -> Void)?
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var isEditableWhenVisible = false
    private var leadingSpaceThisComposition = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        keyboardAppearance = .dark
        returnKeyType = .send
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) { nil }

    var unmarkedText: String {
        let full = text ?? ""
        guard let marked = markedTextRange else { return full }
        let start = offset(from: beginningOfDocument, to: marked.start)
        let end = offset(from: beginningOfDocument, to: marked.end)
        guard start >= 0, end >= start else { return full }
        let ns = full as NSString
        guard end <= ns.length else { return full }
        return ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: "")
    }

    func republishUnmarked() {
        onUnmarkedChange?(unmarkedText)
    }

    func applyIMEPartial(_ text: String) {
        insertLeadingSpaceIfNeeded()
        let loc = (text as NSString).length
        setMarkedText(text, selectedRange: NSRange(location: loc, length: 0))
    }

    func applyIMEFinal(_ text: String) {
        insertLeadingSpaceIfNeeded()
        guard !text.isEmpty else {
            leadingSpaceThisComposition = false
            return
        }
        let hadMarked = markedTextRange != nil
        insertText(text)
        if hadMarked, markedTextRange != nil {
            let loc = (text as NSString).length
            setMarkedText(text, selectedRange: NSRange(location: loc, length: 0))
            unmarkText()
        }
        leadingSpaceThisComposition = false
        republishUnmarked()
    }

    func commitMarkedIfNeeded() {
        if markedTextRange != nil {
            unmarkText()
            leadingSpaceThisComposition = false
            republishUnmarked()
        }
    }

    private func insertLeadingSpaceIfNeeded() {
        guard !leadingSpaceThisComposition else { return }
        let prefix = unmarkedText
        if !prefix.isEmpty, !prefix.hasSuffix(" "), !prefix.hasSuffix("\n") {
            insertText(" ")
        }
        leadingSpaceThisComposition = true
    }

    override func paste(_ sender: Any?) {
        if MobileAttachmentStager.clipboardHasAttachment() {
            onPasteAttachments?()
            return
        }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), MobileAttachmentStager.clipboardHasAttachment() {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

struct VoiceComposerField: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var wantsKeyboard: Bool
    var accessory: UIView?
    var onSubmit: () -> Void
    var onPasteAttachments: (() -> Void)?
    var onBeginEditing: () -> Void
    var onEndEditing: () -> Void
    var onAttach: (VoiceComposerTextView) -> Void
    var darkChrome: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> VoiceComposerTextView {
        let view = VoiceComposerTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = darkChrome ? .white : .label
        view.tintColor = darkChrome ? .white : .tintColor
        view.font = .systemFont(ofSize: 16)
        view.isScrollEnabled = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.accessibilityIdentifier = "voice.composer"
        view.accessibilityLabel = String(localized: "Message the agent")
        context.coordinator.view = view
        onAttach(view)
        return view
    }

    func updateUIView(_ uiView: VoiceComposerTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isEditable = isEditable
        context.coordinator.wantsKeyboard = wantsKeyboard
        uiView.onSubmit = onSubmit
        uiView.onPasteAttachments = onPasteAttachments
        uiView.onBeginEditing = onBeginEditing
        uiView.onEndEditing = onEndEditing
        uiView.onUnmarkedChange = { text in
            context.coordinator.text.wrappedValue = text
        }
        uiView.isEditableWhenVisible = isEditable
        uiView.isEditable = isEditable
        uiView.inputAccessoryView = accessory
        if uiView.text != text, !uiView.isFirstResponder {
            uiView.text = text
        }
        if wantsKeyboard {
            if !uiView.isFirstResponder { _ = uiView.becomeFirstResponder() }
        } else if uiView.isFirstResponder {
            _ = uiView.resignFirstResponder()
        }
        onAttach(uiView)
    }

    static func dismantleUIView(_ uiView: VoiceComposerTextView, coordinator: Coordinator) {}

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var isEditable = false
        var wantsKeyboard = false
        weak var view: VoiceComposerTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            isEditable
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            view?.onBeginEditing?()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            view?.onEndEditing?()
        }

        func textViewDidChange(_ textView: UITextView) {
            let unmarked = (textView as? VoiceComposerTextView)?.unmarkedText ?? (textView.text ?? "")
            text.wrappedValue = unmarked
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if replacement == "\n" {
                view?.onSubmit?()
                return false
            }
            return true
        }
    }
}
