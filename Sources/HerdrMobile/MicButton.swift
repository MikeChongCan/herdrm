import SwiftUI
import UIKit

/// Dumb mic control. Does not own a `VoiceDictationController`.
/// Tap toggles recording. Long-press opens a two-state context menu:
/// idle shows recent transcriptions; recording offers Stop.
final class MicButton: UIButton {
    var onToggle: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldStop: (() -> Void)?
    var onPasteTranscription: ((String) -> Void)?
    var onShowTranscriptionHistory: (() -> Void)?

    private var suppressNextUp = false
    private var recording = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        tintColor = .white
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        layer.cornerRadius = 8
        clipsToBounds = true
        setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold),
            forImageIn: .normal
        )
        addTarget(self, action: #selector(touchDown), for: .touchDown)
        addTarget(
            self,
            action: #selector(touchUp),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        showsMenuAsPrimaryAction = false
        refreshMenu()
        setRecording(false)
        accessibilityIdentifier = "voice.record"
    }

    required init?(coder: NSCoder) { nil }

    func setRecording(_ recording: Bool) {
        self.recording = recording
        let name = recording ? "stop.circle.fill" : "mic.circle.fill"
        setImage(UIImage(systemName: name), for: .normal)
        tintColor = recording ? .systemRed : .white
        backgroundColor = recording
            ? UIColor.systemRed.withAlphaComponent(0.28)
            : UIColor.white.withAlphaComponent(0.08)
        accessibilityIdentifier = recording ? "voice.stop" : "voice.record"
        accessibilityLabel = recording
            ? String(localized: "Stop Recording")
            : String(localized: "Voice input")
        refreshMenu()
    }

    func setChrome(dark: Bool) {
        if recording {
            tintColor = .systemRed
        } else {
            tintColor = dark ? .white : .label
        }
    }

    @objc private func touchDown() {
        UIView.animate(withDuration: 0.08) { self.alpha = 0.45 }
        refreshMenu()
    }

    @objc private func touchUp() {
        UIView.animate(withDuration: 0.12) { self.alpha = 1 }
        if suppressNextUp {
            suppressNextUp = false
            return
        }
        onToggle?()
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        suppressNextUp = true
    }

    private func refreshMenu() {
        menu = historyMenu()
    }

    private func historyMenu() -> UIMenu {
        if recording {
            let stop = UIAction(
                title: String(localized: "Stop Recording"),
                image: UIImage(systemName: "stop.circle"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.onToggle?()
            }
            return UIMenu(title: String(localized: "Recording"), children: [stop])
        }

        let recents = TranscriptionHistoryStore.recent(5)
        var items: [UIMenuElement] = recents.map { entry in
            let title = Self.previewTitle(entry.text)
            return UIAction(title: title, image: UIImage(systemName: "text.quote")) { [weak self] _ in
                self?.onPasteTranscription?(entry.text)
            }
        }
        if recents.isEmpty {
            items.append(
                UIAction(
                    title: String(localized: "No recent transcriptions"),
                    attributes: .disabled
                ) { _ in }
            )
        }
        let all = UIAction(
            title: String(localized: "All Recents…"),
            image: UIImage(systemName: "list.bullet")
        ) { [weak self] _ in
            self?.onShowTranscriptionHistory?()
        }
        items.append(all)
        return UIMenu(title: String(localized: "Voice"), children: items)
    }

    private static func previewTitle(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count <= 42 { return collapsed }
        return String(collapsed.prefix(41)) + "…"
    }
}

enum RecordHaptics {
    static func started() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func stopped() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

struct MicButtonView: UIViewRepresentable {
    var recording: Bool
    var darkChrome: Bool = true
    var onToggle: () -> Void
    var onHoldStart: () -> Void
    var onHoldStop: () -> Void
    var onPasteTranscription: (String) -> Void = { _ in }
    var onShowTranscriptionHistory: () -> Void = {}

    func makeUIView(context: Context) -> MicButton {
        let button = MicButton(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        button.onToggle = onToggle
        button.onHoldStart = onHoldStart
        button.onHoldStop = onHoldStop
        button.onPasteTranscription = onPasteTranscription
        button.onShowTranscriptionHistory = onShowTranscriptionHistory
        return button
    }

    func updateUIView(_ uiView: MicButton, context: Context) {
        uiView.onToggle = onToggle
        uiView.onHoldStart = onHoldStart
        uiView.onHoldStop = onHoldStop
        uiView.onPasteTranscription = onPasteTranscription
        uiView.onShowTranscriptionHistory = onShowTranscriptionHistory
        uiView.setRecording(recording)
        uiView.setChrome(dark: darkChrome)
    }
}
