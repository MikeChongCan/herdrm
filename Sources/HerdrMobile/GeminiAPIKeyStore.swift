import Foundation
import Security

/// Gemini API key for live transcription. Stays on this device.
enum GeminiAPIKeyStore {
    private static let service = "dev.bybee.herdrm.ios.gemini"
    private static let account = "api-key"

    static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SecItemDelete(baseQuery() as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let existing = load()
        if existing != nil {
            SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            return
        }
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    enum ValidationResult: Equatable {
        case ok
        case failed(String)
    }

    /// Hits the Models API for `gemini-3.5-transcribe-live`. Does not send audio.
    static func validate(_ key: String) async -> ValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed(String(localized: "Enter an API key.")) }
        guard var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe-live"
        ) else {
            return .failed(String(localized: "Couldn’t reach Gemini."))
        }
        components.queryItems = [URLQueryItem(name: "key", value: trimmed)]
        guard let url = components.url else {
            return .failed(String(localized: "Couldn’t reach Gemini."))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return .ok }
            if let message = geminiErrorMessage(in: data), !message.isEmpty {
                return .failed(message)
            }
            return .failed(String(localized: "Gemini rejected this key (\(status))."))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func geminiErrorMessage(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
