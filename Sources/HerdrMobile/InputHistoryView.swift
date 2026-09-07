import SwiftUI
import UIKit

struct InputHistoryView: View {
    @State private var entries = InputHistoryStore.load()

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Input History"),
                    systemImage: "clock",
                    description: Text(String(localized: "Sent composer messages and kept drafts show up here."))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.text)
                            .font(.body)
                            .textSelection(.enabled)
                        HStack {
                            if !entry.title.isEmpty {
                                Text(entry.title)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(entry.createdAt, format: .relative(presentation: .named))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("history.entry")
                    .contextMenu {
                        Button(String(localized: "Copy")) {
                            UIPasteboard.general.string = entry.text
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(String(localized: "Copy")) {
                            UIPasteboard.general.string = entry.text
                        }
                        .tint(.blue)
                        Button(String(localized: "Delete"), role: .destructive) {
                            InputHistoryStore.remove(entry.id)
                            entries = InputHistoryStore.load()
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Input History"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .destructiveAction) {
                    Button(String(localized: "Clear"), role: .destructive) {
                        InputHistoryStore.clear()
                        entries = []
                    }
                    .accessibilityIdentifier("history.clear")
                }
            }
        }
        .onAppear { entries = InputHistoryStore.load() }
    }
}
