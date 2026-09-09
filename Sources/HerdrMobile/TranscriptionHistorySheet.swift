import SwiftUI
import UIKit

struct TranscriptionHistorySheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries = TranscriptionHistoryStore.load()

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Transcriptions"),
                        systemImage: "mic",
                        description: Text(String(localized: "Recent voice transcriptions show up here after you dictate."))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            onPick(entry.text)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.text)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(entry.createdAt, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("transcription.entry")
                        .swipeActions(edge: .trailing) {
                            Button(String(localized: "Delete"), role: .destructive) {
                                TranscriptionHistoryStore.remove(entry.id)
                                entries = TranscriptionHistoryStore.load()
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Recent Transcriptions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(String(localized: "Clear"), role: .destructive) {
                            TranscriptionHistoryStore.clear()
                            entries = []
                        }
                    }
                }
            }
            .onAppear { entries = TranscriptionHistoryStore.load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
