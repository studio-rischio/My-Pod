import AppKit
import SwiftUI

/// The pane behind My Pod ▸ Check for Updates…
///
/// Informational only. It never downloads, unzips or replaces anything: the app
/// is ad-hoc signed on purpose, and self-updating without a Developer ID is a
/// worse experience than opening the release page, not a better one.
struct UpdateSheet: View {
    @Bindable var checker: UpdateChecker

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 540, height: 470)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Check for Updates").font(.headline)
            Spacer(minLength: 8)
            if case .checking = checker.state {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch checker.state {
        case .idle, .checking:
            VStack(spacing: 10) {
                ProgressView()
                Text("Asking GitHub for the latest release…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .upToDate(let local, let latest):
            upToDateView(local: local, latest: latest)

        case .available(let release):
            availableView(release)

        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Couldn't check for updates")
                    .font(.title3)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
    }

    private func upToDateView(local: String, latest: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text("My Pod \(local) is up to date")
                .font(.title3)
            // A development build carries a version ahead of anything published,
            // and silently calling that "the latest" would be misleading to the
            // one person most likely to notice.
            if UpdateChecker.isNewer(local, than: latest) {
                Text("This build is newer than the latest release (\(latest)).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("That's the newest release available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func availableView(_ release: ReleaseInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .imageScale(.large)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("My Pod \(release.version) is available")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text(subtitle(for: release))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !release.notes.isEmpty {
                    Divider()
                    ReleaseNotesView(markdown: release.notes)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func subtitle(for release: ReleaseInfo) -> String {
        var pieces = ["You have \(checker.currentVersion)"]
        if let published = release.published {
            pieces.append("released \(published.formatted(date: .abbreviated, time: .omitted))")
        }
        return pieces.joined(separator: " · ")
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if case .failed = checker.state {
                Button("Try Again") { Task { await checker.check() } }
            }
            Spacer()
            if case .available(let release) = checker.state {
                Button("Close") { checker.dismiss() }
                Button("Open Download Page") {
                    Log.ui.info("user opened the release page for \(release.version)")
                    NSWorkspace.shared.open(release.page)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { checker.dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Release notes, rendered as the Markdown they were written in.
///
/// SwiftUI's `Text` understands *inline* Markdown — bold, code spans, links —
/// but nothing about block structure, so handing it a release body whole turns
/// every heading and bullet into one run-on paragraph. This splits the body into
/// blocks and styles them, then lets `Text` handle the inline formatting within
/// each one, which is the part it's good at.
private struct ReleaseNotesView: View {
    let markdown: String

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(String)
        case paragraph(String)
        case code(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(level <= 2 ? .headline : .subheadline)
                        .fontWeight(.semibold)
                        .padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(text))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                case .paragraph(let text):
                    Text(inline(text))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let text):
                    // Verbatim, selectable, and scrolled rather than wrapped.
                    // Release notes carry the quarantine command, which is the
                    // one thing in them a user has to copy exactly.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 9)
                    }
                    .background(.quaternary.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                case .rule:
                    Divider().padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Inline-only, so a `#` or `-` that survived the block pass can't be
    /// re-interpreted as structure. Falls back to the literal text rather than
    /// dropping a line that fails to parse.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// Consecutive plain lines join into one paragraph, the way Markdown means
    /// them to — release notes are usually hard-wrapped, and rendering each line
    /// as its own paragraph would double every gap.
    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        // Fenced blocks are the one place where the line breaks and the leading
        // whitespace are the content, so they bypass everything below.
        var fenced: [String]?

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if let body = fenced {
                    blocks.append(.code(body.joined(separator: "\n")))
                    fenced = nil
                } else {
                    flush()
                    fenced = []
                }
                continue
            }
            if fenced != nil {
                fenced?.append(rawLine)
                continue
            }

            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let hashes = line.prefix { $0 == "#" }.count
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(level: hashes, text: text)) }
            } else if line == "---" || line == "***" || line == "___" {
                flush()
                blocks.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        // An unterminated fence still has to render: dropping the rest of the
        // notes because someone forgot a closing ``` would be worse than showing
        // it as code.
        if let body = fenced, !body.isEmpty {
            blocks.append(.code(body.joined(separator: "\n")))
        }
        flush()
        return blocks
    }
}
