import SwiftUI
import UIKit

/// One toolbar: keyboard toggle pinned left, mic pinned right, middle keys scroll with edge fades.
final class HerdrInputAccessory: UIInputView, UIScrollViewDelegate {
    var onMicToggle: (() -> Void)?
    var onMicHoldStart: (() -> Void)?
    var onMicHoldStop: (() -> Void)?
    var onPasteTranscription: ((String) -> Void)?
    var onShowTranscriptionHistory: (() -> Void)?
    var onSendKeys: (([String]) -> Void)?
    var onToggleKeyboard: (() -> Void)?
    var onPaste: (() -> Void)?
    var onShareLogs: (() -> Void)?

    private let keyboardButton = UIButton(type: .system)
    private let mic = MicButton()
    private let statusLabel = UILabel()
    private let scroller = UIScrollView()
    private let keys = UIStackView()
    private let leftFade = FadeEdgeView(edge: .leading)
    private let rightFade = FadeEdgeView(edge: .trailing)
    private var pasteButton: UIButton!
    private var logButton: UIButton!
    private var statusWidthConstraint: NSLayoutConstraint!

    static var barHeight: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? 44 : 48
    }

    init() {
        let height = Self.barHeight
        super.init(
            frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: height),
            inputViewStyle: .keyboard
        )
        allowsSelfSizing = true
        backgroundColor = UIColor(white: 0.12, alpha: 1)

        keyboardButton.translatesAutoresizingMaskIntoConstraints = false
        Self.styleIconButton(keyboardButton, highlighted: false)
        keyboardButton.accessibilityIdentifier = "chrome.keyboard"
        keyboardButton.addAction(UIAction { [weak self] _ in
            QALog.add("toolbar keyboard toggle")
            self?.onToggleKeyboard?()
        }, for: .touchUpInside)
        Self.attachPressFade(keyboardButton)
        setKeyboardVisible(false)

        mic.translatesAutoresizingMaskIntoConstraints = false
        mic.onToggle = { [weak self] in
            QALog.add("toolbar mic tap")
            self?.onMicToggle?()
        }
        mic.onHoldStart = { [weak self] in
            QALog.add("toolbar mic hold start")
            self?.onMicHoldStart?()
        }
        mic.onHoldStop = { [weak self] in
            QALog.add("toolbar mic hold stop")
            self?.onMicHoldStop?()
        }
        mic.onPasteTranscription = { [weak self] text in
            QALog.add("toolbar mic paste transcription")
            self?.onPasteTranscription?(text)
        }
        mic.onShowTranscriptionHistory = { [weak self] in
            QALog.add("toolbar mic transcription history")
            self?.onShowTranscriptionHistory?()
        }

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        statusLabel.textAlignment = .natural
        statusLabel.lineBreakMode = .byTruncatingHead
        statusLabel.isHidden = true
        statusLabel.accessibilityIdentifier = "voice.accessoryStatus"

        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = true
        scroller.delegate = self
        scroller.translatesAutoresizingMaskIntoConstraints = false

        keys.axis = .horizontal
        keys.alignment = .fill
        keys.distribution = .fill
        keys.spacing = 6
        keys.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(keys)

        let items: [(title: String, symbol: String?, key: String)] = [
            ("esc", nil, "esc"),
            ("tab", nil, "tab"),
            ("ctrl", nil, "ctrl"),
            ("", "chevron.up", "up"),
            ("", "chevron.down", "down"),
            ("", "chevron.left", "left"),
            ("", "chevron.right", "right"),
            ("⏎", nil, "enter"),
            ("^C", nil, "ctrl+c"),
            ("^D", nil, "ctrl+d"),
            ("^Z", nil, "ctrl+z"),
            ("^L", nil, "ctrl+l"),
            ("⇞", nil, "page_up"),
            ("⇟", nil, "page_down"),
            ("Hom", nil, "home"),
            ("End", nil, "end"),
            ("~", nil, "~"),
            ("|", nil, "|"),
            ("/", nil, "/"),
            ("-", nil, "-"),
            ("F1", nil, "f1"),
            ("F2", nil, "f2"),
            ("F3", nil, "f3"),
            ("F4", nil, "f4"),
            ("F5", nil, "f5"),
            ("F6", nil, "f6"),
            ("F7", nil, "f7"),
            ("F8", nil, "f8"),
            ("F9", nil, "f9"),
            ("F10", nil, "f10"),
        ]
        for item in items {
            let button = Self.makeKey(title: item.title, symbol: item.symbol)
            let key = item.key
            button.addAction(UIAction { [weak self] _ in
                QALog.add("toolbar key \(key)")
                self?.onSendKeys?([key])
            }, for: .touchUpInside)
            Self.attachPressFade(button)
            keys.addArrangedSubview(button)
        }

        pasteButton = Self.makeIconButton("photo.on.rectangle", identifier: "composer.pasteAttachment")
        pasteButton.accessibilityLabel = String(localized: "Paste screenshot")
        pasteButton.addAction(UIAction { [weak self] _ in
            QALog.add("toolbar paste")
            self?.onPaste?()
        }, for: .touchUpInside)
        Self.attachPressFade(pasteButton)
        keys.addArrangedSubview(pasteButton)

        logButton = Self.makeIconButton("ladybug.fill", identifier: "chrome.shareLogs")
        logButton.accessibilityLabel = String(localized: "Attach debug log")
        logButton.addAction(UIAction { [weak self] _ in
            QALog.add("toolbar attach logs")
            self?.onShareLogs?()
        }, for: .touchUpInside)
        Self.attachPressFade(logButton)
        keys.addArrangedSubview(logButton)

        leftFade.translatesAutoresizingMaskIntoConstraints = false
        rightFade.translatesAutoresizingMaskIntoConstraints = false
        leftFade.isUserInteractionEnabled = false
        rightFade.isUserInteractionEnabled = false

        addSubview(keyboardButton)
        addSubview(statusLabel)
        addSubview(scroller)
        addSubview(leftFade)
        addSubview(rightFade)
        addSubview(mic)

        let keyHeight = height - 8
        statusWidthConstraint = statusLabel.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            statusWidthConstraint,
            keyboardButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            keyboardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            keyboardButton.widthAnchor.constraint(equalToConstant: 44),
            keyboardButton.heightAnchor.constraint(equalToConstant: keyHeight),
            mic.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            mic.centerYAnchor.constraint(equalTo: centerYAnchor),
            mic.widthAnchor.constraint(equalToConstant: 48),
            mic.heightAnchor.constraint(equalToConstant: keyHeight),
            statusLabel.leadingAnchor.constraint(equalTo: keyboardButton.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.heightAnchor.constraint(lessThanOrEqualToConstant: keyHeight),
            scroller.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 6),
            scroller.trailingAnchor.constraint(equalTo: mic.leadingAnchor, constant: -6),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftFade.leadingAnchor.constraint(equalTo: scroller.leadingAnchor),
            leftFade.topAnchor.constraint(equalTo: scroller.topAnchor),
            leftFade.bottomAnchor.constraint(equalTo: scroller.bottomAnchor),
            leftFade.widthAnchor.constraint(equalToConstant: 18),
            rightFade.trailingAnchor.constraint(equalTo: scroller.trailingAnchor),
            rightFade.topAnchor.constraint(equalTo: scroller.topAnchor),
            rightFade.bottomAnchor.constraint(equalTo: scroller.bottomAnchor),
            rightFade.widthAnchor.constraint(equalToConstant: 18),
            keys.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            keys.topAnchor.constraint(equalTo: scroller.frameLayoutGuide.topAnchor, constant: 4),
            keys.bottomAnchor.constraint(equalTo: scroller.frameLayoutGuide.bottomAnchor, constant: -4),
            keys.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor, constant: -8),
        ])
        for view in keys.arrangedSubviews {
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFades()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFades()
    }

    private func updateFades() {
        let x = scroller.contentOffset.x
        let overflow = scroller.contentSize.width - scroller.bounds.width
        leftFade.alpha = x > 2 ? 1 : 0
        rightFade.alpha = overflow > 2 && x < overflow - 2 ? 1 : 0
    }

    func setRecording(_ recording: Bool) {
        mic.setRecording(recording)
    }

    func setStatusCaption(_ caption: String) {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = !trimmed.isEmpty && trimmed != String(localized: "Tap to dictate")
        statusLabel.text = visible ? trimmed : nil
        statusLabel.isHidden = !visible
        statusWidthConstraint.constant = visible ? 112 : 0
        leftFade.alpha = visible ? 0 : leftFade.alpha
        rightFade.alpha = visible ? 0 : rightFade.alpha
        setNeedsLayout()
    }

    func setPasteEnabled(_ enabled: Bool) {
        pasteButton.isEnabled = enabled
        pasteButton.alpha = enabled ? 1 : 0.45
    }

    func setKeyboardVisible(_ visible: Bool) {
        let name = visible ? "keyboard.chevron.compact.down" : "keyboard"
        let image = UIImage(systemName: name)?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        )
        keyboardButton.setImage(image, for: .normal)
        keyboardButton.accessibilityLabel = visible
            ? String(localized: "Hide Keyboard")
            : String(localized: "Show Keyboard")
    }

    private static func makeKey(title: String, symbol: String?) -> UIButton {
        let button = UIButton(type: .system)
        if let symbol {
            let image = UIImage(systemName: symbol)?.applyingSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
            )
            button.setImage(image, for: .normal)
            button.tintColor = UIColor.white.withAlphaComponent(0.95)
            button.accessibilityLabel = symbol
        } else {
            var config = UIButton.Configuration.plain()
            config.title = title
            config.baseForegroundColor = UIColor.white.withAlphaComponent(0.95)
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
                return outgoing
            }
            button.configuration = config
            button.accessibilityLabel = title
        }
        button.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        button.layer.cornerRadius = 8
        button.clipsToBounds = true
        return button
    }

    private static func makeIconButton(_ systemName: String, identifier: String) -> UIButton {
        let button = UIButton(type: .system)
        let image = UIImage(systemName: systemName)?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        )
        button.setImage(image, for: .normal)
        styleIconButton(button, highlighted: false)
        button.accessibilityIdentifier = identifier
        return button
    }

    private static func styleIconButton(_ button: UIButton, highlighted: Bool) {
        button.tintColor = UIColor.white.withAlphaComponent(0.95)
        button.backgroundColor = UIColor.white.withAlphaComponent(highlighted ? 0.28 : 0.08)
        button.layer.cornerRadius = 8
    }

    private static func attachPressFade(_ button: UIButton) {
        button.addAction(UIAction { _ in
            UIView.animate(withDuration: 0.08) { button.alpha = 0.4 }
        }, for: .touchDown)
        button.addAction(UIAction { _ in
            UIView.animate(withDuration: 0.14) { button.alpha = 1 }
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
}

private final class FadeEdgeView: UIView {
    enum Edge { case leading, trailing }
    private let gradient = CAGradientLayer()

    init(edge: Edge) {
        super.init(frame: .zero)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let clear = UIColor.clear.cgColor
        let fill = UIColor(white: 0.12, alpha: 1).cgColor
        if edge == .leading {
            gradient.colors = [fill, clear]
        } else {
            gradient.colors = [clear, fill]
        }
        layer.addSublayer(gradient)
        alpha = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }
}

struct HerdrToolbarHost: UIViewRepresentable {
    let bar: HerdrInputAccessory

    func makeUIView(context: Context) -> HerdrInputAccessory { bar }
    func updateUIView(_ uiView: HerdrInputAccessory, context: Context) {}
}
