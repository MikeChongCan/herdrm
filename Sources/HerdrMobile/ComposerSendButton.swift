import SwiftUI
import UIKit

/// System send control: tap submits (`agent.prompt` / newline), long-press
/// shows the platform context menu (`UIButton.menu`).
struct ComposerSendButton: UIViewRepresentable {
    var isEnabled: Bool
    var onSend: () -> Void
    var onSendWithoutNewline: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSend: onSend, onSendWithoutNewline: onSendWithoutNewline)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "composer.send"
        button.accessibilityLabel = String(localized: "Send")
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "arrow.up.circle.fill")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 28)
        config.contentInsets = .zero
        button.configuration = config
        button.showsMenuAsPrimaryAction = false
        button.addAction(UIAction { [weak coordinator = context.coordinator] _ in
            coordinator?.onSend()
        }, for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.onSend = onSend
        context.coordinator.onSendWithoutNewline = onSendWithoutNewline
        button.isEnabled = isEnabled
        button.tintColor = isEnabled
            ? .tintColor
            : UIColor.white.withAlphaComponent(0.25)
        button.menu = UIMenu(children: [
            UIAction(
                title: String(localized: "Send"),
                image: UIImage(systemName: "return")
            ) { [weak coordinator = context.coordinator] _ in
                coordinator?.onSend()
            },
            UIAction(
                title: String(localized: "Send without newline"),
                image: UIImage(systemName: "text.insert")
            ) { [weak coordinator = context.coordinator] _ in
                coordinator?.onSendWithoutNewline()
            },
        ])
    }

    final class Coordinator {
        var onSend: () -> Void
        var onSendWithoutNewline: () -> Void

        init(onSend: @escaping () -> Void, onSendWithoutNewline: @escaping () -> Void) {
            self.onSend = onSend
            self.onSendWithoutNewline = onSendWithoutNewline
        }
    }
}
