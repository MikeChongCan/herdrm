import Foundation
import UIKit

/// In-app ring buffer so a Debug build can share keyboard/dictation logs
/// without Xcode. Dump via the toolbar bug button, then attach the file.
enum QALog {
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let limit = 500
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func add(_ message: String) {
        let row = "\(stamp.string(from: Date()))  \(message)"
        lock.lock()
        lines.append(row)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
        lock.unlock()
        print("[herdrm-qa] \(row)")
    }

    static func dump() -> String {
        lock.lock()
        let copy = lines
        lock.unlock()
        let header = """
        herdrm iOS QA log
        bundle \(Bundle.main.bundleIdentifier ?? "?")
        version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))
        ---
        """
        return ([header] + copy).joined(separator: "\n")
    }

    static func fileURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-qa-\(Int(Date().timeIntervalSince1970)).txt")
        try dump().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
