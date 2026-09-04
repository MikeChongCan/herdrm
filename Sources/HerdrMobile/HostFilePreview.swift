import Foundation
import HerdrSSH
import QuickLook
import UIKit

enum HostFilePreviewError: LocalizedError {
    case isDirectory
    case tooLarge
    case missing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .isDirectory:
            return String(localized: "That path is a directory.")
        case .tooLarge:
            return String(localized: "This file is too large to preview.")
        case .missing:
            return String(localized: "File not found on the host.")
        case .failed(let reason):
            return reason
        }
    }
}

enum HostFilePreview {
    static let maxBytes = 25 * 1024 * 1024

    static func fetch(path: String, using transport: MobileTransport) async throws -> (
        fileURL: URL, directoryURL: URL
    ) {
        let sftp = try await transport.openSFTP(timeout: .seconds(15))
        defer {
            let sftp = sftp
            Task { try? await sftp.close(timeout: .seconds(2)) }
        }

        let attrs = try await sftp.attributes(at: path, timeout: .seconds(15))
        guard !attrs.isDirectory else { throw HostFilePreviewError.isDirectory }
        guard let size = attrs.size, size <= UInt64(maxBytes) else {
            throw HostFilePreviewError.tooLarge
        }
        guard let data = try await sftp.readFileIfPresent(
            at: path, maxBytes: maxBytes, timeout: .seconds(60)
        ) else {
            throw HostFilePreviewError.missing
        }

        let directoryURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HostFilePreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        let basename = name.isEmpty ? "file" : name
        let fileURL = directoryURL.appendingPathComponent(basename)
        try data.write(to: fileURL, options: .atomic)
        return (fileURL, directoryURL)
    }

    static func present(fileURL: URL, directoryURL: URL, from presenter: UIViewController) {
        let controller = HostFileQLController(fileURL: fileURL, directoryURL: directoryURL)
        presenter.present(controller, animated: true)
    }

    static func removeAllCachedPreviews() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HostFilePreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class HostFileQLController: QLPreviewController, QLPreviewControllerDataSource,
    QLPreviewControllerDelegate
{
    private let fileURL: URL
    private let directoryURL: URL

    init(fileURL: URL, directoryURL: URL) {
        self.fileURL = fileURL
        self.directoryURL = directoryURL
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
        -> any QLPreviewItem
    {
        fileURL as QLPreviewItem
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
