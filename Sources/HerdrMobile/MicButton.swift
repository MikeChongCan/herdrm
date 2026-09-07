import SwiftUI
import UIKit

/// Dumb mic control. Does not own a `VoiceDictationController`.
/// Tap toggles; hold 350 ms starts, release stops.
final class MicButton: UIButton {
    var onToggle: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldStop: (() -> Void)?

    private var holdArmed = false
    private var holdStartTask: Task<Void, Never>?

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
        setRecording(false)
        accessibilityIdentifier = "voice.record"
    }

    required init?(coder: NSCoder) { nil }

    func setRecording(_ recording: Bool) {
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
    }

    func setChrome(dark: Bool) {
        if accessibilityIdentifier == "voice.stop" {
            tintColor = .systemRed
        } else {
            tintColor = dark ? .white : .label
        }
    }

    @objc private func touchDown() {
        UIView.animate(withDuration: 0.08) { self.alpha = 0.45 }
        holdArmed = false
        holdStartTask?.cancel()
        holdStartTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            holdArmed = true
            onHoldStart?()
        }
    }

    @objc private func touchUp() {
        UIView.animate(withDuration: 0.12) { self.alpha = 1 }
        holdStartTask?.cancel()
        holdStartTask = nil
        if holdArmed {
            holdArmed = false
            onHoldStop?()
        } else {
            onToggle?()
        }
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

    func makeUIView(context: Context) -> MicButton {
        let button = MicButton(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        button.onToggle = onToggle
        button.onHoldStart = onHoldStart
        button.onHoldStop = onHoldStop
        return button
    }

    func updateUIView(_ uiView: MicButton, context: Context) {
        uiView.onToggle = onToggle
        uiView.onHoldStart = onHoldStart
        uiView.onHoldStop = onHoldStop
        uiView.setRecording(recording)
        uiView.setChrome(dark: darkChrome)
    }
}
