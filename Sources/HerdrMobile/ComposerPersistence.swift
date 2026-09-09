import Foundation

/// Unsent composer text, keyed by device/pane so popping the sidebar and
/// coming back restores dictation and typing.
enum ComposerDraftStore {
    private static let prefix = "composer.draft."

    static func load(_ key: String) -> String {
        UserDefaults.standard.string(forKey: Self.prefix + key) ?? ""
    }

    static func save(_ key: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.prefix + key)
        } else {
            UserDefaults.standard.set(text, forKey: Self.prefix + key)
        }
    }
}

struct InputHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date
    let paneID: String
    let title: String

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), paneID: String, title: String) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.paneID = paneID
        self.title = title
    }
}

enum InputHistoryStore {
    private static let defaultsKey = "composer.inputHistory"
    private static let limit = 100

    static func load() -> [InputHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([InputHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func append(text: String, paneID: String, title: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = load()
        if let last = entries.first, last.text == trimmed, last.paneID == paneID {
            return
        }
        entries.insert(
            InputHistoryEntry(text: trimmed, paneID: paneID, title: title),
            at: 0
        )
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        save(entries)
    }

    static func remove(_ id: UUID) {
        save(load().filter { $0.id != id })
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func save(_ entries: [InputHistoryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

struct TranscriptionHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

enum TranscriptionHistoryStore {
    private static let defaultsKey = "voice.transcriptionHistory"
    static let limit = 10

    static func load() -> [TranscriptionHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func recent(_ count: Int = 5) -> [TranscriptionHistoryEntry] {
        Array(load().prefix(count))
    }

    static func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = load()
        if let last = entries.first, last.text == trimmed { return }
        entries.insert(TranscriptionHistoryEntry(text: trimmed), at: 0)
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func remove(_ id: UUID) {
        let entries = load().filter { $0.id != id }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
