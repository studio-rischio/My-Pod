// LogsView.swift
//
// In-app log viewer. Surfaces the shared LogStore (see Log.swift) with
// level + category + free-text filters, auto-scroll, and Copy / Save / Clear
// buttons. Reachable from Window → Debug Log.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LogsView: View {
    @State private var store = LogStore.shared
    @State private var selectedCategories: Set<String> = []
    @State private var minLevel: LogLevel = .debug
    @State private var search: String = ""
    @State private var autoScroll: Bool = true

    private static let categories = [
        "ui", "device", "library", "playlist",
        "convert", "sync", "ipod", "artwork"
    ]

    /// Hoisted formatter — re-allocating one per row was a real cost when
    /// 5,000 entries scroll past with auto-scroll on.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        // Compute once per body re-eval. `filtered` is read from the
        // toolbar's count label, the LazyVStack ForEach, and the
        // `.onChange(of: filtered.last?.id)` accessor — without caching,
        // we'd run the filter pass three times per render against
        // 5,000-entry stores.
        let filteredEntries = filtered
        return VStack(spacing: 0) {
            toolbar(filteredCount: filteredEntries.count)
            Divider()
            logList(filtered: filteredEntries)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .navigationTitle("Debug Log")
    }

    // MARK: - Toolbar

    private func toolbar(filteredCount: Int) -> some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Min level", selection: $minLevel) {
                    Text("Debug").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Warning").tag(LogLevel.warning)
                    Text("Error").tag(LogLevel.error)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .help("Only show entries at this level or higher.")

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter messages…", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .help("Case-insensitive substring match against each entry's message.")
                }
                .frame(maxWidth: 260)

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Automatically scroll to the newest entry as it arrives.")

                Button("Copy") { copyToClipboard() }
                    .help("Copy the currently visible (filtered) entries to the clipboard.")
                Button("Save…") { saveToFile() }
                    .help("Save the currently visible (filtered) entries to a text file.")
                Button("Report a Bug…") { reportBug() }
                    .help("Open a pre-filled GitHub issue containing the currently visible (filtered) entries. Your home folder path is replaced with ~, the full log is copied to your clipboard, and nothing is sent until you submit it on GitHub.")
                Button("Clear", role: .destructive) {
                    let previousCount = store.entries.count
                    store.clear()
                    // Clear first, then log — otherwise the "cleared" line
                    // is left behind as the lone surviving entry, which
                    // confuses users who expected an empty list.
                    Log.ui.info("logs view: cleared (\(previousCount) entries)")
                }
                    .help("Empty the in-memory log. Does not clear the system log.")
            }

            HStack(spacing: 6) {
                Text("Categories:").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.categories, id: \.self) { cat in
                    // When `selectedCategories` is empty, every category is
                    // active (the default). Toggling one off creates a
                    // subset; toggling everything back on collapses the
                    // subset back to "empty == all".
                    Toggle(isOn: Binding(
                        get: { selectedCategories.isEmpty || selectedCategories.contains(cat) },
                        set: { on in
                            // Resolve to the equivalent explicit set first,
                            // mutate, then collapse "all on" back to "empty
                            // == all". Single linear flow; the previous
                            // version had an unreachable branch under the
                            // empty-and-toggling-off case.
                            var explicit: Set<String> = selectedCategories.isEmpty
                                ? Set(Self.categories)
                                : selectedCategories
                            if on { explicit.insert(cat) } else { explicit.remove(cat) }
                            selectedCategories = (explicit.count == Self.categories.count) ? [] : explicit
                        }
                    )) {
                        Text(cat).font(.caption)
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                }
                Spacer()
                Text("\(filteredCount) of \(store.entries.count) entries")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(10)
    }

    // MARK: - List

    private func logList(filtered: [LogEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: filtered.last?.id) { _, newId in
                guard autoScroll, let newId else { return }
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo(newId, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timestamp(entry.timestamp))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(entry.level.rawValue.uppercased())
                .font(.caption.monospaced())
                .foregroundStyle(color(for: entry.level))
                .frame(width: 52, alignment: .leading)
            Text(entry.category)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timestamp(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug:   return .secondary
        case .info:    return .primary
        case .warning: return .orange
        case .error:   return .red
        }
    }

    // MARK: - Filtering + export

    private var filtered: [LogEntry] {
        let activeCats = selectedCategories.isEmpty ? Set(Self.categories) : selectedCategories
        let q = search.lowercased()
        return store.entries.filter { entry in
            guard entry.level >= minLevel else { return false }
            guard activeCats.contains(entry.category) else { return false }
            if !q.isEmpty && !entry.message.lowercased().contains(q) { return false }
            return true
        }
    }

    private func copyToClipboard() {
        let text = exportText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Log.ui.info("logs view: copied \(filtered.count) entries to clipboard")
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "mypod-log-\(df.string(from: Date())).txt"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try exportText().write(to: url, atomically: true, encoding: .utf8)
                Log.ui.info("logs view: saved \(filtered.count) entries to \(url.path)")
            } catch {
                Log.ui.warning("logs view: save failed \(error.localizedDescription)")
            }
        }
    }

    /// Scoped to the visible entries, matching Copy and Save — the three
    /// buttons sit together, so acting on different sets would surprise.
    private func reportBug() {
        BugReporter.openIssue(log: exportText())
    }

    private func exportText() -> String {
        LogStore.exportText(filtered)
    }
}
