import Foundation

/// Which embedded VT engine draws attach/shell panes.
public enum TerminalEngineKind: String, CaseIterable, Identifiable {
    case ghostty
    case swiftterm

    public static let defaultsKey = "terminal.engine"

    public var id: String { rawValue }

    public var settingsLabel: String {
        switch self {
        case .ghostty: return "Ghostty (default)"
        case .swiftterm: return "SwiftTerm (legacy)"
        }
    }

    /// Missing key → Ghostty. Unknown values fall back to Ghostty.
    public static var current: TerminalEngineKind {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ghostty.rawValue
        return TerminalEngineKind(rawValue: raw) ?? .ghostty
    }
}
