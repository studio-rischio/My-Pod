import AppKit
import Foundation

/// Opens a pre-filled GitHub issue for a bug report.
///
/// Nothing is submitted from the app. GitHub's new-issue page *is* the review
/// step: the reporter reads the whole thing — log included — and presses Submit
/// themselves. That keeps the app out of the business of holding a token, and
/// means no one can file a report they haven't seen.
@MainActor
enum BugReporter {
    static let newIssueURL = "https://github.com/studio-rischio/My-Pod/issues/new"

    /// GitHub answers 414 to an over-long request URI. The ceiling applies to
    /// the *percent-encoded* string, where a newline costs three characters and
    /// log lines are punctuation-heavy — so this sits well under the ~8 KB
    /// limit rather than trying to ride it.
    private static let maxURLLength = 6_000

    /// Builds the report, puts the full log on the clipboard, and opens the
    /// browser. The log in the URL is the *tail*, trimmed to fit; the clipboard
    /// copy is always complete, so a truncated report is one paste from whole.
    static func openIssue(log: String) {
        let redacted = redactingHomeDirectory(log)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(redacted, forType: .string)

        let (url, truncated) = issueURL(log: redacted)
        guard let url else {
            Log.ui.warning("bug report: could not build the issue URL")
            return
        }

        NSWorkspace.shared.open(url)
        Log.ui.info("bug report: opened issue form — log \(truncated ? "truncated to fit" : "included in full"), \(redacted.count) chars on the clipboard")
    }

    /// Builds the report URL from an already-redacted log. Kept separate from
    /// `openIssue` so the result can be inspected without touching the
    /// clipboard or launching a browser.
    static func issueURL(log: String) -> (url: URL?, truncated: Bool) {
        let (body, truncated) = issueBody(log: log)
        guard let encoded = percentEncoded(body) else { return (nil, truncated) }
        return (URL(string: "\(newIssueURL)?labels=bug&body=\(encoded)"), truncated)
    }

    // MARK: - Body

    private static let truncationNotice =
        "… earlier entries trimmed to fit the URL. The full log is on your clipboard — paste it here. …\n"

    private static func issueBody(log: String) -> (body: String, truncated: Bool) {
        let header = """
        ### What happened

        <!-- What did you expect, and what happened instead? -->

        ### Steps to reproduce

        1.
        2.

        ### Which iPod

        <!-- Model and capacity, e.g. iPod Photo 30 GB, iPod classic 5th gen -->

        ### Environment

        | | |
        |---|---|
        | My Pod | \(appVersion) |
        | macOS | \(osVersion) |
        | Architecture | \(architecture) |

        ### Log

        <details>
        <summary>Debug log</summary>

        ```

        """
        let footer = "\n```\n\n</details>\n"

        // Reserve the notice unconditionally: working out whether it's needed
        // requires knowing the budget, which depends on whether it's there.
        let fixed = URLLength(header) + URLLength(footer) + URLLength(truncationNotice)
            + newIssueURL.count + "?labels=bug&body=".count
        let budget = maxURLLength - fixed
        guard budget > 0 else { return (header + footer, true) }

        // Walk backwards: the newest entries are the ones that explain a crash.
        var kept: [Substring] = []
        var used = 0
        var truncated = false
        for line in log.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let cost = URLLength(String(line)) + 3   // + the encoded newline
            if used + cost > budget {
                truncated = true
                break
            }
            used += cost
            kept.append(line)
        }

        let tail = kept.reversed().joined(separator: "\n")
        return (header + (truncated ? truncationNotice : "") + tail + footer, truncated)
    }

    // MARK: - Privacy

    /// Logs carry absolute paths — the library root, every converted file — so
    /// they name the user's home directory, and a bug report is public.
    ///
    /// Only the home path is rewritten. Substituting a bare username would also
    /// hit artist and album names that happen to match it, which would corrupt
    /// the very log lines a maintainer needs to read.
    static func redactingHomeDirectory(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard home.count > 1 else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    // MARK: - Encoding

    /// Unreserved characters only (RFC 3986). Deliberately stricter than
    /// `.urlQueryAllowed`, which leaves `+` and `&` intact — a log line
    /// containing either would otherwise be read as a query separator or
    /// decoded as a space.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func percentEncoded(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    /// Length this text costs *in the URL*, which is what the limit measures.
    private static func URLLength(_ text: String) -> Int {
        percentEncoded(text)?.count ?? text.count * 3
    }

    // MARK: - Environment

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
