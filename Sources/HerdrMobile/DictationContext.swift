import Foundation
import SwiftTerm

/// Fresh-on-tap biasing for `gemini-3.5-transcribe-live`. Built from the iOS
/// attach (cwd, title, last visible terminal lines) — not a prefetch.
struct DictationContext: Sendable {
    var projectName: String
    var cwd: String
    var title: String
    var recentTerminal: String
    var vocabulary: [String]
    var systemInstruction: String?

    static let empty = DictationContext(
        projectName: "",
        cwd: "",
        title: "",
        recentTerminal: "",
        vocabulary: [],
        systemInstruction: nil
    )

    static func capture(cwd: String?, title: String?, terminal: TerminalView?) -> DictationContext {
        let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = cwd.split(separator: "/").last.map(String.init) ?? ""
        let recent = visibleTail(from: terminal, lines: 12)
        var terms: [String] = []
        appendUnique(&terms, project)
        appendUnique(&terms, title)
        for part in cwd.split(separator: "/").suffix(3) {
            appendUnique(&terms, String(part))
        }
        for token in tokens(in: title) + tokens(in: recent) {
            appendUnique(&terms, token)
        }
        if terms.count > 80 { terms = Array(terms.prefix(80)) }

        var lines: [String] = [
            "Transcribe a developer speaking to a coding agent.",
            "Prefer identifiers, file names, and paths from this context.",
        ]
        if !project.isEmpty { lines.append("Project: \(project)") }
        if !cwd.isEmpty { lines.append("CWD: \(cwd)") }
        if !title.isEmpty { lines.append("Title: \(title)") }
        let clipped = String(recent.suffix(1_500)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !clipped.isEmpty {
            lines.append("Recent terminal:")
            lines.append(clipped)
        }
        let instruction = lines.count > 2 ? lines.joined(separator: "\n") : nil

        return DictationContext(
            projectName: project,
            cwd: cwd,
            title: title,
            recentTerminal: recent,
            vocabulary: terms,
            systemInstruction: instruction
        )
    }

    private static func visibleTail(from view: TerminalView?, lines: Int) -> String {
        guard let view else { return "" }
        let terminal = view.getTerminal()
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        let last = terminal.buffer.yDisp + rows - 1
        let first = max(0, last - (lines - 1))
        return terminal.getText(
            start: Position(col: 0, row: first),
            end: Position(col: cols - 1, row: last)
        )
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(in text: String) -> [String] {
        let pattern = #"(?:[A-Za-z_][\w.-]{1,}|[\p{Han}]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).compactMap { match in
            let token = ns.substring(with: match.range)
            if token.count > 48 { return nil }
            if Self.stop.contains(token.lowercased()) { return nil }
            return token
        }
    }

    private static func appendUnique(_ terms: inout [String], _ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 48 else { return }
        if stop.contains(trimmed.lowercased()) { return }
        if terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return }
        terms.append(trimmed)
    }

    private static let stop: Set<String> = [
        "the", "and", "for", "to", "of", "a", "an", "is", "in", "on", "at",
        "this", "that", "with", "from", "you", "your", "are", "be", "or",
        "as", "it", "if", "not", "but", "by", "we", "our",
    ]
}
