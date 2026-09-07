import UIKit
import HerdrKit

/// Context-menu preview: system glass/blur card with the full URL highlighted.
final class LinkPreviewCardController: UIViewController {
    private let headline: String
    private let urlText: String
    private let symbolName: String

    init(link: DetectedLink) {
        switch link {
        case .web(let url):
            headline = url.host ?? url.absoluteString
            urlText = url.absoluteString
            symbolName = "link"
        case .hostFile(let path):
            headline = (path as NSString).lastPathComponent
            urlText = path
            symbolName = "doc"
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let blur = UIVisualEffectView(effect: Self.chromeEffect())
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 18
        blur.clipsToBounds = true

        let icon = UIImageView(image: UIImage(systemName: symbolName))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .systemBlue
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.text = headline
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label
        title.numberOfLines = 2

        let urlLabel = UILabel()
        urlLabel.numberOfLines = 0
        urlLabel.attributedText = NSAttributedString(
            string: urlText,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: UIColor.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )

        let textStack = UIStackView(arrangedSubviews: [title, urlLabel])
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.alignment = .leading

        let row = UIStackView(arrangedSubviews: [icon, textStack])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12

        let root = UIView()
        root.addSubview(blur)
        blur.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -16),
        ])

        let width = min(UIScreen.main.bounds.width - 48, 320)
        let lines = CGFloat(urlText.split(separator: "\n").count + urlText.count / 36)
        preferredContentSize = CGSize(width: width, height: min(220, 72 + max(24, lines * 18)))
        view = root
    }

    private static func chromeEffect() -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.tintColor = UIColor.systemBlue.withAlphaComponent(0.22)
            return glass
        }
        return UIBlurEffect(style: .systemChromeMaterial)
    }
}
