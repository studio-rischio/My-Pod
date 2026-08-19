import Foundation
import Observation

/// A published release of My Pod.
nonisolated struct ReleaseInfo: Sendable, Equatable {
    /// Marketing version with any leading `v` removed — `1.7`, not `v1.7`.
    let version: String
    /// The release's own title, which is usually more descriptive than the tag.
    let title: String
    /// Release notes, as the Markdown they were written in.
    let notes: String
    let page: URL
    let published: Date?
}

/// Asks GitHub whether there's a newer My Pod, when the user asks it to.
///
/// **Strictly manual, and that's a promise rather than an implementation
/// detail.** Nothing here runs at launch, on a timer, or in the background: the
/// only entry point is the menu item. People who keep twenty-year-old hardware
/// working are exactly the people who object to software that phones home, and
/// the README and the site both say nothing leaves the machine unless they ask.
/// Adding an automatic check would make that untrue.
///
/// Shared because a menu command has no view to own it — `Commands` is built
/// alongside the window, not inside it. `DeviceProfileStore.shared` sets the
/// same precedent.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum State: Equatable {
        case idle
        case checking
        /// Nothing newer. `local` is carried so a development build ahead of
        /// every release can say so rather than claim to be the latest.
        case upToDate(local: String, latest: String)
        case available(ReleaseInfo)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Drives the sheet. Set by the menu command, cleared by the sheet.
    var isPresenting = false

    private let endpoint = URL(string: "https://api.github.com/repos/studio-rischio/My-Pod/releases/latest")!

    private init() {}

    /// The running app's `MARKETING_VERSION`.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Open the sheet and start a check. The menu item's only job.
    func presentAndCheck() {
        Log.ui.info("user chose Check for Updates")
        isPresenting = true
        Task { await check() }
    }

    func check() async {
        state = .checking
        do {
            let release = try await fetchLatest()
            let local = currentVersion
            if Self.isNewer(release.version, than: local) {
                Log.ui.info("update available: \(release.version) (running \(local))")
                state = .available(release)
            } else {
                Log.ui.info("no update: latest is \(release.version), running \(local)")
                state = .upToDate(local: local, latest: release.version)
            }
        } catch {
            Log.ui.warning("update check failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    func dismiss() {
        isPresenting = false
        // Reset so the next open doesn't flash the previous answer before the
        // new check lands.
        state = .idle
    }

    // MARK: - Fetching

    private struct Payload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlUrl: String
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name, body
            case htmlUrl = "html_url"
            case publishedAt = "published_at"
        }
    }

    private func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        // GitHub rejects requests without a User-Agent outright.
        request.setValue("MyPod/\(currentVersion) ( https://github.com/studio-rischio/My-Pod )",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // 404 means the repository has no published release yet, which is a
            // different thing from a broken check and reads better said plainly.
            if http.statusCode == 404 {
                throw UpdateError.noReleases
            }
            throw UpdateError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              let page = URL(string: payload.htmlUrl) else {
            throw UpdateError.malformed
        }

        let version = payload.tagName.hasPrefix("v")
            ? String(payload.tagName.dropFirst())
            : payload.tagName

        return ReleaseInfo(
            version: version,
            title: payload.name?.isEmpty == false ? payload.name! : "My Pod \(version)",
            notes: payload.body ?? "",
            page: page,
            published: payload.publishedAt
        )
    }

    enum UpdateError: LocalizedError {
        case noReleases
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .noReleases: return "There aren't any published releases yet."
            case .http(let code): return "GitHub replied with HTTP \(code)."
            case .malformed: return "GitHub's reply wasn't in the expected format."
            }
        }
    }

    // MARK: - Version comparison

    /// Whether `candidate` is a strictly later version than `current`.
    ///
    /// Compared component-wise as integers, not as strings: `1.10` is later than
    /// `1.9`, which string ordering gets backwards. A missing component counts
    /// as zero, so `1.7` and `1.7.0` are the same version.
    ///
    /// Strictly later, deliberately. A development build carries a
    /// `MARKETING_VERSION` ahead of anything published, and an equal-or-newer
    /// test would offer the developer a downgrade every time they checked.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(of: candidate)
        let b = components(of: current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Leading digits of each dot-separated part, so `1.8-beta2` reads as
    /// `[1, 8]` rather than failing to parse at all.
    private nonisolated static func components(of version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}
