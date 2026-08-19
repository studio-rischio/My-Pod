import Foundation

/// One cover offered by an online catalogue.
nonisolated struct ArtworkSearchResult: Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    /// Image for the results grid.
    ///
    /// Sized for the tile at Retina scale, not for the smallest thing the
    /// catalogue offers: a 132pt tile is 264 real pixels, so the 100px variant
    /// Apple returns by default arrives visibly upscaled.
    let thumbnailURL: URL
    /// What gets downloaded when the user picks this one.
    let fullURL: URL
    /// The one size the catalogue is *known* to have, used two ways: as the
    /// fallback if `fullURL` 404s, and as what gets probed when checking a
    /// release has any art at all.
    let fallbackURL: URL?
    let source: String
    /// Nominal size of `fullURL`, where the catalogue guarantees one.
    let sizeLabel: String?
}

/// Looks up cover art online.
///
/// **This is the only part of My Pod that touches the network**, apart from
/// `BugReporter` handing a URL to the browser. It runs when the user presses
/// Search and at no other time — not at launch, not during a library scan, not
/// during a sync. Nothing about the library is transmitted except the artist and
/// album the user is searching for, and only for the album they're looking at.
nonisolated enum ArtworkSearch {
    enum SearchError: LocalizedError {
        case emptyQuery
        case nothingFound
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .emptyQuery: return "Type something to search for."
            case .nothingFound: return "No covers found. Try clearing the artist field and searching on the album name alone, or check the album's spelling."
            case .transport(let message): return "The search couldn't be completed: \(message)"
            }
        }
    }

    /// MusicBrainz requires a descriptive agent identifying the application and
    /// a contact address, and will refuse or throttle requests without one.
    private static let userAgent =
        "MyPod/1.7 ( https://github.com/studio-rischio/My-Pod )"

    private static let timeout: TimeInterval = 15

    // MARK: - Search

    /// Apple's catalogue first, Cover Art Archive only if it comes back empty.
    ///
    /// They're good at opposite things: iTunes has near-complete coverage of
    /// commercial releases and nothing else, while Cover Art Archive is
    /// contributor-driven and reaches obscure and self-released material that
    /// Apple never carried. Running the fallback only on an empty result also
    /// keeps MusicBrainz's one-request-per-second rule satisfied without any
    /// rate limiting of our own — a user cannot press a button that fast.
    /// Artist and album stay separate all the way down because the two
    /// catalogues want opposite things. Apple's endpoint takes one free-text
    /// term and does its own matching. MusicBrainz takes a Lucene query, and a
    /// free-text one is close to useless there — searching "Boards of Canada
    /// Geogaddi" returns releases *titled* "Boards of Canada" by other artists,
    /// where `artist:"…" AND release:"…"` returns the album, at score 100.
    /// Measured, not assumed.
    static func search(artist: String, album: String) async throws -> [ArtworkSearchResult] {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty || !album.isEmpty else { throw SearchError.emptyQuery }
        Log.artwork.info("search: \"\(artist)\" — \"\(album)\"")

        // A failure at Apple is not a reason to skip the archive. They're
        // separate services: a 5xx or a timeout at one says nothing about the
        // other, and the fallback exists precisely for the material Apple is
        // worst at. The error is kept rather than dropped, so if the archive
        // also comes up empty the user is told what actually went wrong instead
        // of "no covers found".
        var appleFailure: Error?
        do {
            let term = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
            let apple = try await searchAppleMusic(term)
            if !apple.isEmpty {
                Log.artwork.info("search: Apple Music returned \(apple.count) result(s)")
                return apple
            }
            Log.artwork.info("search: Apple Music had nothing — trying the Cover Art Archive")
        } catch {
            appleFailure = error
            Log.artwork.warning("search: Apple Music failed (\(error.localizedDescription)) — trying the Cover Art Archive")
        }

        do {
            let archive = try await searchCoverArtArchive(artist: artist, album: album)
            if !archive.isEmpty {
                Log.artwork.info("search: Cover Art Archive returned \(archive.count) result(s)")
                return archive
            }
        } catch {
            Log.artwork.warning("search: Cover Art Archive failed: \(error.localizedDescription)")
            throw appleFailure ?? error
        }

        if let appleFailure { throw appleFailure }
        Log.artwork.info("search: nothing found in either catalogue")
        throw SearchError.nothingFound
    }

    private static func searchAppleMusic(_ query: String) async throws -> [ArtworkSearchResult] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "18"),
        ]
        guard let url = components.url else { return [] }

        struct Response: Decodable {
            struct Item: Decodable {
                let collectionName: String?
                let artistName: String?
                let artworkUrl100: String?
                let collectionId: Int?
            }
            let results: [Item]
        }

        let data = try await get(url)
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }

        return decoded.results.compactMap { item in
            guard let thumb = item.artworkUrl100, let thumbURL = URL(string: thumb) else { return nil }
            // Substituting the dimensions in the path is undocumented but
            // universal. `fallbackURL` is why that's safe to rely on: if the
            // large variant ever 404s, the 100px one that Apple actually
            // returned is still there.
            let large = thumb.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")
            let grid = thumb.replacingOccurrences(of: "100x100bb", with: "400x400bb")
            return ArtworkSearchResult(
                id: "apple-\(item.collectionId.map(String.init) ?? thumb)",
                title: item.collectionName ?? "Unknown album",
                artist: item.artistName ?? "Unknown artist",
                thumbnailURL: URL(string: grid) ?? thumbURL,
                fullURL: URL(string: large) ?? thumbURL,
                fallbackURL: thumbURL,
                source: "Apple Music",
                sizeLabel: large == thumb ? nil : "1200 × 1200"
            )
        }
    }

    /// Two hops: MusicBrainz for release IDs, then Cover Art Archive for the
    /// front cover of each.
    ///
    /// Nothing in the MusicBrainz response says whether a release has cover art,
    /// and most don't — a plain listing showed two dead tiles for every live one.
    /// So every candidate is probed before it's offered.
    private static func searchCoverArtArchive(artist: String, album: String) async throws -> [ArtworkSearchResult] {
        var terms: [String] = []
        if !artist.isEmpty { terms.append("artist:\"\(escape(artist))\"") }
        if !album.isEmpty { terms.append("release:\"\(escape(album))\"") }
        guard !terms.isEmpty else { return [] }

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
        components.queryItems = [
            URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components.url else { return [] }

        struct Response: Decodable {
            struct Release: Decodable {
                struct Credit: Decodable {
                    struct Artist: Decodable { let name: String? }
                    let artist: Artist?
                }
                let id: String
                let title: String?
                let artistCredit: [Credit]?

                enum CodingKeys: String, CodingKey {
                    case id, title
                    case artistCredit = "artist-credit"
                }
            }
            let releases: [Release]
        }

        let data = try await get(url)
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }

        let candidates: [ArtworkSearchResult] = decoded.releases.compactMap { release in
            guard let thumb = URL(string: "https://coverartarchive.org/release/\(release.id)/front-500"),
                  let small = URL(string: "https://coverartarchive.org/release/\(release.id)/front-250"),
                  let full = URL(string: "https://coverartarchive.org/release/\(release.id)/front")
            else { return nil }
            let artist = release.artistCredit?.compactMap { $0.artist?.name }.joined(separator: ", ")
            return ArtworkSearchResult(
                id: "caa-\(release.id)",
                title: release.title ?? "Unknown release",
                artist: (artist?.isEmpty == false ? artist : nil) ?? "Unknown artist",
                thumbnailURL: thumb,
                fullURL: full,
                fallbackURL: small,
                source: "Cover Art Archive",
                sizeLabel: nil
            )
        }
        return await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { (index, await exists(candidate.fallbackURL ?? candidate.thumbnailURL)) }
            }
            var keep = Set<Int>()
            for await (index, ok) in group where ok { keep.insert(index) }
            let kept = candidates.enumerated().filter { keep.contains($0.offset) }.map(\.element)
            Log.artwork.info("search: \(candidates.count) MusicBrainz release(s), \(kept.count) with cover art")
            return kept
        }
    }

    /// Lucene treats these as syntax; an album called `Where?` or `A + B` would
    /// otherwise produce a malformed query rather than no results.
    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if #"+-&|!(){}[]^"~*?:\/"#.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static func exists(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Fetching

    /// Download the image behind a result, falling back to the smaller variant
    /// rather than failing outright.
    static func fetch(_ result: ArtworkSearchResult) async -> Data? {
        if let data = try? await get(result.fullURL), !data.isEmpty {
            Log.artwork.info("downloaded cover from \(result.source) (\(data.count) bytes)")
            return data
        }
        guard let fallback = result.fallbackURL else {
            Log.artwork.warning("cover download failed and there is no smaller variant to fall back to")
            return nil
        }
        Log.artwork.info("full-size cover unavailable, falling back to the thumbnail")
        return try? await get(fallback)
    }

    /// Thumbnail bytes for the results grid. Nil rather than throwing — a tile
    /// that can't load its picture is a gap in a grid, not a failed search.
    ///
    /// Falls back for the same reason `fetch` does: the tile size is derived by
    /// rewriting the URL, and the size the catalogue actually handed us is the
    /// only one guaranteed to be there.
    static func thumbnail(_ result: ArtworkSearchResult) async -> Data? {
        if let data = try? await get(result.thumbnailURL), !data.isEmpty { return data }
        guard let fallback = result.fallbackURL else { return nil }
        return try? await get(fallback)
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SearchError.transport("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as SearchError {
            throw error
        } catch {
            throw SearchError.transport(error.localizedDescription)
        }
    }
}
