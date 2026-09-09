import SafariServices
import UIKit

enum InAppBrowser {
    /// Opens http(s) in `SFSafariViewController` so we stay in-app.
    /// Other schemes fall back to the system handler.
    @MainActor
    static func open(_ url: URL, from view: UIView?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        guard let presenter = presenter(from: view) else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        safari.preferredControlTintColor = .systemBlue
        presenter.present(safari, animated: true)
    }

    @MainActor
    private static func presenter(from view: UIView?) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return view?.window?.rootViewController
    }
}
