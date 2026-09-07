import HerdrKit
import HerdrSSH
import UniformTypeIdentifiers
import UIKit

enum MobileAttachmentError: LocalizedError {
    case empty
    case tooLarge
    case encodingFailed
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return String(localized: "Nothing to paste from the clipboard.")
        case .tooLarge:
            return String(localized: "That file is larger than the 50 MB limit.")
        case .encodingFailed:
            return String(localized: "The clipboard image could not be encoded as JPEG.")
        case .transferFailed(let reason):
            return reason
        }
    }
}

/// Reads the phone clipboard, stages files on the herdr host over SFTP, and
/// returns quoted absolute paths for the agent composer.
enum MobileAttachmentStager {
    static let maxBytes = 50 * 1024 * 1024
    static let jpegQuality: CGFloat = 0.85
    private static let alreadyExists: UInt64 = 11

    @MainActor
    static func clipboardHasAttachment(_ pasteboard: UIPasteboard = .general) -> Bool {
        pasteboard.hasImages || fileURLs(in: pasteboard).isEmpty == false
    }

    @MainActor
    static func stageQuotedPaths(
        from pasteboard: UIPasteboard = .general,
        using provider: any MobileTransportProvider
    ) async throws -> String {
        let locals = try materialize(from: pasteboard)
        guard !locals.isEmpty else { throw MobileAttachmentError.empty }
        defer {
            for item in locals where item.removeAfterUpload {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
        return try await uploadPrepared(locals, using: provider)
    }

    @MainActor
    static func stageLocalURLs(
        _ urls: [URL],
        using provider: any MobileTransportProvider
    ) async throws -> String {
        guard !urls.isEmpty else { throw MobileAttachmentError.empty }
        let prepared = try urls.map(preparedItem(from:))
        defer {
            for item in prepared where item.removeAfterUpload {
                try? FileManager.default.removeItem(at: item.url)
            }
        }
        return try await uploadPrepared(prepared, using: provider)
    }

    @MainActor
    private static func uploadPrepared(
        _ items: [LocalItem],
        using provider: any MobileTransportProvider
    ) async throws -> String {
        let transport = try await provider.currentTransport()
        let sftp = try await transport.openSFTP(timeout: .seconds(15))
        defer {
            let sftp = sftp
            Task { try? await sftp.close(timeout: .seconds(2)) }
        }

        let directory = try await remoteTemporaryAttachmentsDirectory(using: transport)
        try await ensureDirectory(directory, on: sftp)

        var remotePaths: [String] = []
        for item in items {
            remotePaths.append(try await upload(item.url, to: directory, using: sftp))
        }
        return remotePaths.map(ShellQuoting.quoted).joined(separator: " ")
    }

    private struct LocalItem {
        let url: URL
        let removeAfterUpload: Bool
    }

    private static func materialize(from pasteboard: UIPasteboard) throws -> [LocalItem] {
        let images = pasteboard.images ?? []
        if !images.isEmpty {
            return try images.map(compressedJPEGItem)
        }

        let files = fileURLs(in: pasteboard)
        if !files.isEmpty {
            return try files.map(preparedItem(from:))
        }
        return []
    }

    private static func preparedItem(from url: URL) throws -> LocalItem {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true else {
            throw MobileAttachmentError.transferFailed("Only regular files can be pasted.")
        }
        if let size = values.fileSize, size > maxBytes {
            throw MobileAttachmentError.tooLarge
        }
        if isImageFile(values.contentType, pathExtension: url.pathExtension),
           let image = UIImage(contentsOfFile: url.path)
        {
            return try compressedJPEGItem(image)
        }
        return LocalItem(url: url, removeAfterUpload: false)
    }

    private static func compressedJPEGItem(_ image: UIImage) throws -> LocalItem {
        let jpeg = try jpegData(from: image)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-clipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).jpg")
        try jpeg.write(to: url, options: .atomic)
        return LocalItem(url: url, removeAfterUpload: true)
    }

    private static func jpegData(from image: UIImage) throws -> Data {
        let pixel = pixelSize(of: image)
        guard let data = image.jpegData(compressionQuality: jpegQuality) else {
            throw MobileAttachmentError.encodingFailed
        }
        guard data.count <= maxBytes else { throw MobileAttachmentError.tooLarge }
        QALog.add("attachment jpeg \(Int(pixel.width))x\(Int(pixel.height)) \(data.count)b q=\(jpegQuality)")
        return data
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    private static func isImageFile(_ type: UTType?, pathExtension: String) -> Bool {
        if let type, type.conforms(to: .image) { return true }
        return UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true
    }

    private static func fileURLs(in pasteboard: UIPasteboard) -> [URL] {
        (pasteboard.urls ?? []).filter(\.isFileURL)
    }

    /// Host-side `NSTemporaryDirectory()` / `$TMPDIR`, not `~/.cache`.
    private static func remoteTemporaryAttachmentsDirectory(
        using transport: any MobileTransport
    ) async throws -> String {
        let result = try await transport.execute(
            #"if t=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) && [ -n "$t" ]; then printf '%s' "$t"; else printf '%s' "${TMPDIR:-/tmp}"; fi"#,
            timeout: .seconds(10)
        )
        let raw = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root: String
        if raw.hasPrefix("/") {
            root = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        } else {
            root = "/tmp"
        }
        return "\(root)/herdrm-attachments"
    }

    private static func ensureDirectory(_ path: String, on sftp: SSHSFTPClient) async throws {
        if let attrs = try? await sftp.attributes(at: path, timeout: .seconds(10)), attrs.isDirectory {
            try? await sftp.setPermissions(0o700, at: path, timeout: .seconds(5))
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        if parent != path, parent != "/", !parent.isEmpty {
            try await ensureDirectory(parent, on: sftp)
        }
        do {
            try await sftp.createDirectory(at: path, permissions: 0o700, timeout: .seconds(10))
        } catch SSHError.sftpFailure(let status) where status == alreadyExists {
            return
        }
    }

    private static func upload(_ localURL: URL, to directory: String, using sftp: SSHSFTPClient) async throws -> String {
        let name = remoteFilename(for: localURL)
        let destination = "\(directory)/\(name)"
        let staging = "\(directory)/.\(name).part"
        try? await sftp.removeFile(at: staging, timeout: .seconds(5))

        let data = try Data(contentsOf: localURL)
        guard data.count <= maxBytes else { throw MobileAttachmentError.tooLarge }

        QALog.add("attachment upload start \(data.count)b \(name)")
        let timeout = Duration.seconds(min(600, 30 + data.count / 65_536))
        let file = try await sftp.openFileForWriting(at: staging, permissions: 0o600, timeout: .seconds(15))
        do {
            try await file.write(data, timeout: timeout)
            try await file.close(timeout: .seconds(10))
        } catch {
            try? await file.close(timeout: .seconds(2))
            try? await sftp.removeFile(at: staging, timeout: .seconds(5))
            QALog.add("attachment upload fail \(error.localizedDescription)")
            throw MobileAttachmentError.transferFailed(error.localizedDescription)
        }
        try await sftp.setPermissions(0o600, at: staging, timeout: .seconds(5))
        try await sftp.renameFileAtomically(from: staging, to: destination, timeout: .seconds(10))
        QALog.add("attachment upload done \(destination)")
        return destination
    }

    private static func remoteFilename(for localURL: URL) -> String {
        let rawExtension = localURL.pathExtension.lowercased()
        let isSafe = !rawExtension.isEmpty
            && rawExtension.utf8.count <= 16
            && rawExtension.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...122).contains(byte)
            }
        let suffix = isSafe ? ".\(rawExtension)" : ""
        return "\(UUID().uuidString.lowercased())\(suffix)"
    }
}
