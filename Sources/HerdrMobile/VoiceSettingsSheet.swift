import SwiftUI

struct VoiceSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = TerminalInputChrome()
    @State private var apiKey = GeminiAPIKeyStore.load() ?? ""
    @State private var saved = GeminiAPIKeyStore.load() != nil
    @State private var previewText = ""
    @State private var validating = false
    @State private var validation: GeminiAPIKeyStore.ValidationResult?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(String(localized: "Input method")) {
                        Text(String(localized: "Gemini Voice"))
                    }
                    LabeledContent(String(localized: "Model")) {
                        Text("gemini-3.5-transcribe-live")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(String(localized: "Status")) {
                        Text(saved ? String(localized: "API key saved") : String(localized: "Needs API key"))
                            .foregroundStyle(saved ? .green : .orange)
                    }
                    .accessibilityIdentifier("settings.geminiStatus")
                    NavigationLink {
                        InputHistoryView()
                    } label: {
                        Text(String(localized: "Input History"))
                    }
                    .accessibilityIdentifier("settings.inputHistory")
                } header: {
                    Text(String(localized: "Voice Input"))
                } footer: {
                    Text(String(localized: "Unsent composer text is kept when you leave a pane. Sent messages land in Input History so you can copy them later."))
                }

                Section {
                    SecureField(String(localized: "Gemini API key"), text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("settings.geminiKey")
                    Button(saved ? String(localized: "Saved") : String(localized: "Save Key")) {
                        save()
                    }
                    .accessibilityIdentifier("settings.saveGeminiKey")
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        Task { await validate() }
                    } label: {
                        HStack {
                            Text(String(localized: "Validate API Key"))
                            if validating {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.validateGeminiKey")
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validating)
                    if let validation {
                        switch validation {
                        case .ok:
                            Text(String(localized: "Key works with gemini-3.5-transcribe-live."))
                                .foregroundStyle(.green)
                                .font(.footnote)
                        case .failed(let message):
                            Text(message)
                                .foregroundStyle(.red)
                                .font(.footnote)
                        }
                    }
                    if saved {
                        Button(String(localized: "Remove Key"), role: .destructive) {
                            apiKey = ""
                            GeminiAPIKeyStore.save("")
                            saved = false
                            validation = nil
                        }
                        .accessibilityIdentifier("settings.removeGeminiKey")
                    }
                } header: {
                    Text(String(localized: "API Key"))
                } footer: {
                    Text(String(localized: "Create a key in Google AI Studio. It is stored in this phone’s Keychain and used only for live transcription."))
                }

                Section {
                    HStack {
                        MicButtonView(
                            recording: preview.isRecording,
                            darkChrome: false,
                            onToggle: { preview.dictation.toggle() },
                            onHoldStart: { Task { await preview.dictation.start() } },
                            onHoldStop: { Task { _ = await preview.dictation.stop(waitForTrailingFinal: true) } }
                        )
                        .frame(width: 36, height: 36)
                        Text(preview.statusCaption.isEmpty ? String(localized: "Tap to dictate") : preview.statusCaption)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .onAppear {
                        preview.dictation.onFinal = { text in
                            if previewText.isEmpty || previewText.hasSuffix(" ") {
                                previewText += text
                            } else {
                                previewText += " " + text
                            }
                        }
                    }
                    .onDisappear { preview.dictation.cancel() }
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .accessibilityIdentifier("settings.voicePreview")
                    if !previewText.isEmpty {
                        Text(previewText)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(String(localized: "Try dictation"))
                } footer: {
                    Text(String(localized: "Tap the mic to start and stop. Hold it to record until you release."))
                }

                Section {
                    Link(String(localized: "Get a Gemini API key"), destination: URL(string: "https://aistudio.google.com/apikey")!)
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            save()
                        }
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.done")
                }
            }
        }
    }

    private func save() {
        GeminiAPIKeyStore.save(apiKey)
        saved = GeminiAPIKeyStore.load() != nil
    }

    private func validate() async {
        validating = true
        defer { validating = false }
        save()
        validation = await GeminiAPIKeyStore.validate(apiKey)
    }
}
