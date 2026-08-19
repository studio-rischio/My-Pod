import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// One distinct picture found inside an album's audio files.
nonisolated struct EmbeddedArtworkCandidate: Sendable, Identifiable {
    /// Digest of the image bytes. Identity, not decoration — it's what collapses
    /// the same picture repeated across twelve files into one tile.
    let id: String
    let data: Data
    /// Titles of the tracks carrying this exact image, in album order.
    let trackTitles: [String]
    let pixelWidth: Int
    let pixelHeight: Int

    var trackCount: Int { trackTitles.count }

    var sizeLabel: String {
        pixelWidth > 0 ? "\(pixelWidth) × \(pixelHeight)" : "Unknown size"
    }
}

/// Pulls cover art back out of the audio files themselves.
///
/// The extraction is what `ArtworkLocator` already does as its last-resort
/// fallback — the difference here is that it reads **every** track rather than
/// one. Compilations routinely carry a different picture per file, and a
/// Various Artists folder can hold a dozen distinct covers; showing whichever
/// one happened to be first would pick wrong on exactly the albums most likely
/// to have the problem.
nonisolated enum EmbeddedArtwork {
    /// Ceiling on how many files are opened. An `AVURLAsset` load per track is
    /// the expensive part, and a folder with hundreds of tracks in it is a
    /// mis-structured library rather than an album.
    static let maxTracksScanned = 100

    static func scan(album: LibraryAlbum) async -> [EmbeddedArtworkCandidate] {
        var byDigest: [String: (data: Data, titles: [String])] = [:]
        let considered = album.tracks.prefix(maxTracksScanned)
        if album.tracks.count > maxTracksScanned {
            Log.artwork.warning(
                "embedded scan: \(album.name) has \(album.tracks.count) tracks — only the first \(maxTracksScanned) are read"
            )
        }
        var withArtwork = 0

        for track in considered {
            guard let data = await artworkData(in: track.url), !data.isEmpty else { continue }
            withArtwork += 1
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            byDigest[digest, default: (data, [])].titles.append(track.title)
        }
        Log.artwork.info(
            "embedded scan: \(album.artist) — \(album.name): \(withArtwork) of \(considered.count) file(s) carry art, \(byDigest.count) distinct image(s)"
        )

        let candidates = byDigest.map { digest, entry in
            let size = pixelSize(of: entry.data)
            return EmbeddedArtworkCandidate(
                id: digest,
                data: entry.data,
                trackTitles: entry.titles,
                pixelWidth: size.width,
                pixelHeight: size.height
            )
        }
        // Most-used first: on a normal album that's the album cover, and on a
        // compilation it puts whatever the ripper applied to everything ahead of
        // the one-off per-track pictures.
        return candidates.sorted {
            $0.trackCount == $1.trackCount ? $0.id < $1.id : $0.trackCount > $1.trackCount
        }
    }

    private static func artworkData(in file: URL) async -> Data? {
        let asset = AVURLAsset(url: file)
        guard let common = try? await asset.load(.commonMetadata) else { return nil }
        for item in common where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }

    /// Dimensions without decoding the pixels — the properties dictionary alone
    /// carries them, and these images are only ever drawn as thumbnails.
    private static func pixelSize(of data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }
}
