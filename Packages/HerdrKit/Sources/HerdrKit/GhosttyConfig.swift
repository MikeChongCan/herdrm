#if os(macOS)
import Foundation

/// The slice of a Ghostty configuration herdrm can adopt: the terminal font.
///
/// herdrm's terminal is libghostty but its settings are its own, so this is a
/// one-time *import* (a button in Settings), not a live bind to Ghostty's file —
/// herdrm's own settings stay the source of truth afterward. See issue #73.
public struct GhosttyConfig: Sendable, Equatable {
    /// The primary `font-family`. Ghostty repeats the key to build a fallback
    /// chain; the first entry is the face the user actually sees, so that is the
    /// one herdrm adopts.
    public var fontFamily: String?
    /// `font-size`, in points.
    public var fontSize: Double?

    public init(fontFamily: String? = nil, fontSize: Double? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }

    public var isEmpty: Bool { fontFamily == nil && fontSize == nil }
}

public enum GhosttyConfigImporter {
    /// Ghostty's config location on macOS, honoring `XDG_CONFIG_HOME`. The App
    /// Support copy (`~/Library/Application Support/com.mitchellh.ghostty/config`)
    /// is deliberately *not* read: it is another app's data directory, so reading
    /// it would raise the very "access data from other apps" prompt herdrm just
    /// stopped triggering (#87). `~/.config/ghostty/config` is the path virtually
    /// everyone uses and is not TCC-protected.
    public static func configURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [URL] = []
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append(URL(fileURLWithPath: xdg).appendingPathComponent("ghostty/config"))
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        candidates.append(URL(fileURLWithPath: home).appendingPathComponent(".config/ghostty/config"))
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Reads and parses the discovered config, or nil when there is none.
    public static func load(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GhosttyConfig? {
        guard let url = configURL(fileManager: fileManager, environment: environment),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return parse(text)
    }

    /// Parses Ghostty's `key = value` config text. Whole-line `#` comments are
    /// ignored; the first `font-family` wins (it is the primary face) while the
    /// last `font-size` wins (scalar keys take their final value). Surrounding
    /// quotes on a value are stripped. Unknown keys are ignored.
    public static func parse(_ text: String) -> GhosttyConfig {
        var config = GhosttyConfig()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            guard !value.isEmpty else { continue }
            switch key {
            case "font-family":
                if config.fontFamily == nil { config.fontFamily = value }
            case "font-size":
                if let size = Double(value) { config.fontSize = size }
            default:
                break
            }
        }
        return config
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let quotes: [Character] = ["\"", "'"]
        if let first = value.first, quotes.contains(first), value.last == first {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
#endif
