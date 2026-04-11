import AppKit
import SwiftUI

struct HistoryTab: View {
    private var stats = StatisticsService.shared
    @State private var searchText = ""
    @State private var copiedEventID: UUID?

    private var entries: [TranscriptionEvent] {
        let withText = stats.events.filter { ($0.text ?? "").isEmpty == false }
        let sorted = withText.sorted { $0.timestamp > $1.timestamp }
        guard !searchText.isEmpty else { return sorted }
        let needle = searchText.lowercased()
        return sorted.filter { ($0.text ?? "").lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if stats.events.contains(where: { ($0.text ?? "").isEmpty == false }) {
                header
                Divider()
                if entries.isEmpty {
                    emptyState("No matches for \"\(searchText)\"")
                } else {
                    list
                }
            } else {
                emptyState("Recent transcriptions appear here.")
            }
        }
        .padding()
    }

    private var header: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search history", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(entries) { event in
                    HistoryRow(
                        event: event,
                        isCopied: copiedEventID == event.id,
                        onCopy: { copy(event) }
                    )
                }
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .font(.body)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func copy(_ event: TranscriptionEvent) {
        guard let text = event.text, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedEventID = event.id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedEventID == event.id {
                copiedEventID = nil
            }
        }
    }
}

private struct HistoryRow: View {
    let event: TranscriptionEvent
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.secondary)

                Text(providerDisplayName(event.provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let bundleID = event.targetAppBundleID {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(appName(for: bundleID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onCopy) {
                    Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Text(event.text ?? "")
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(6)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func providerDisplayName(_ rawValue: String) -> String {
        ProviderType(rawValue: rawValue)?.displayName ?? rawValue
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}
