import Foundation

/// Events from `gemini-3.5-transcribe-live` over the Gemini Live WebSocket.
enum GeminiLiveTranscriptEvent: Equatable {
    case ready
    case partial(String)
    case final(String)
    case failed(String)
}

/// Minimal Live API client for streaming speech-to-text.
///
/// Protocol (v1beta WebSocket, camelCase JSON — not the SDK's snake_case):
/// first message is `setup`; audio is `realtimeInput.audio` as 16 kHz PCM16;
/// stop a turn with `audioStreamEnd`. Transcription config lives on `setup`,
/// not inside `generationConfig` (that 1007's on this endpoint).
final class GeminiLiveTranscribeClient: @unchecked Sendable {
    static let modelID = "gemini-3.5-transcribe-live"

    private static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var onEvent: (@Sendable (GeminiLiveTranscriptEvent) -> Void)?
    private var setupDone = false
    private var setupError: String?
    private static let skipSystemInstructionKey = "gemini.transcribe.skipSystemInstruction"

    func connect(
        apiKey: String,
        context: DictationContext = .empty,
        onEvent: @escaping @Sendable (GeminiLiveTranscriptEvent) -> Void
    ) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeminiLiveError.missingAPIKey }

        let skipInstruction = UserDefaults.standard.bool(forKey: Self.skipSystemInstructionKey)
        let instruction = skipInstruction ? nil : context.systemInstruction
        do {
            try await openSession(apiKey: trimmed, context: context, instruction: instruction, onEvent: onEvent)
        } catch GeminiLiveError.server(let message) where instruction != nil && Self.looksLikeUnsupportedSetup(message) {
            UserDefaults.standard.set(true, forKey: Self.skipSystemInstructionKey)
            try await openSession(apiKey: trimmed, context: context, instruction: nil, onEvent: onEvent)
        }
    }

    private func openSession(
        apiKey: String,
        context: DictationContext,
        instruction: String?,
        onEvent: @escaping @Sendable (GeminiLiveTranscriptEvent) -> Void
    ) async throws {
        try await disconnect()

        guard var components = URLComponents(string: Self.endpoint) else {
            throw GeminiLiveError.badURL
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw GeminiLiveError.badURL }

        lock.lock()
        self.onEvent = onEvent
        setupDone = false
        setupError = nil
        lock.unlock()

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        try await sendJSON(setupObject(context: context, instruction: instruction))
        try await waitForSetup()
        emit(.ready)
    }

    private func setupObject(context: DictationContext, instruction: String?) -> [String: Any] {
        var transcription: [String: Any] = [
            "languageCodes": [] as [String],
            "mode": "SMART",
        ]
        if !context.vocabulary.isEmpty {
            transcription["customVocabulary"] = context.vocabulary
        }
        var setup: [String: Any] = [
            "model": "models/\(Self.modelID)",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": transcription,
            "realtimeInputConfig": [
                "automaticActivityDetection": ["disabled": false],
            ],
        ]
        if let instruction, !instruction.isEmpty {
            setup["systemInstruction"] = [
                "parts": [["text": instruction]],
            ]
        }
        return ["setup": setup]
    }

    private static func looksLikeUnsupportedSetup(_ message: String) -> Bool {
        let lower = message.lowercased()
        return message.contains("1007")
            || lower.contains("unknown name")
            || lower.contains("invalid argument")
            || lower.contains("systeminstruction")
    }

    func sendPCM16(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await sendJSON([
            "realtimeInput": [
                "audio": [
                    "data": data.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000",
                ],
            ],
        ])
    }

    func endAudioStream() async throws {
        try await sendJSON([
            "realtimeInput": ["audioStreamEnd": true],
        ])
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        lock.lock()
        onEvent = nil
        setupDone = false
        setupError = nil
        lock.unlock()
    }

    private func waitForSetup() async throws {
        for _ in 0..<100 {
            lock.lock()
            let done = setupDone
            let error = setupError
            lock.unlock()
            if done { return }
            if let error { throw GeminiLiveError.server(error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw GeminiLiveError.timeout
    }

    private func sendJSON(_ object: Any) async throws {
        guard let task else { throw GeminiLiveError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GeminiLiveError.encoding
        }
        try await task.send(.string(text))
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let value): data = value
                @unknown default: continue
                }
                handle(data)
            } catch {
                if Task.isCancelled { return }
                lock.lock()
                if !setupDone { setupError = error.localizedDescription }
                lock.unlock()
                emit(.failed(error.localizedDescription))
                return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if root["setupComplete"] != nil {
            lock.lock()
            setupDone = true
            lock.unlock()
        }
        if let error = root["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Gemini error"
            lock.lock()
            if !setupDone { setupError = message }
            lock.unlock()
            emit(.failed(message))
        }
        let content = root["serverContent"] as? [String: Any]
        if let interim = transcriptText(content?["interimInputTranscription"])
            ?? transcriptText(root["interimInputTranscription"])
        {
            emit(.partial(interim))
        }
        if let final = transcriptText(content?["inputTranscription"])
            ?? transcriptText(root["inputTranscription"])
        {
            emit(.final(final))
        }
    }

    private func transcriptText(_ value: Any?) -> String? {
        guard let object = value as? [String: Any],
              let text = object["text"] as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func emit(_ event: GeminiLiveTranscriptEvent) {
        lock.lock()
        let handler = onEvent
        lock.unlock()
        handler?(event)
    }
}

enum GeminiLiveError: LocalizedError {
    case missingAPIKey
    case badURL
    case notConnected
    case encoding
    case timeout
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return String(localized: "Add a Gemini API key in Settings.")
        case .badURL: return String(localized: "Couldn’t reach Gemini.")
        case .notConnected: return String(localized: "Not connected to Gemini.")
        case .encoding: return String(localized: "Couldn’t encode audio.")
        case .timeout: return String(localized: "Gemini didn’t start in time.")
        case .server(let message): return message
        }
    }
}
