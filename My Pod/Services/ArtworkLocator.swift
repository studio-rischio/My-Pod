import AVFoundation
import Foundation

/// Resolves a per-album cover image path. First tries common cover-art file
/// names in the album folder; falls back to extracting embedded art from a
/// candidate audio file into a scratch directory. Cached per-album so we only
/// do the work once even when called for every track.
actor ArtworkLocator {
    private let scratchDir: URL
    private var cache: [String: URL?] = [:]

    init(scratchDir: URL) {
        self.scratchDir = scratchDir
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
    }

    func locate(albumDir: URL, candidateAudioFile: URL) async -> URL? {
        let key = albumDir.standardizedFileURL.path
        if let cached = cache[key] { return cached }
        let result = await find(albumDir: albumDir, audioFile: candidateAudioFile)
        cache[key] = result
        return result
    }

    private func find(albumDir: URL, audioFile: URL) async -> URL? {
        if let url = findImageInDir(albumDir) { return url }
        return await extractEmbeddedArt(from: audioFile)
    }

    private nonisolated func findImageInDir(_ dir: URL) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        let candidates = ["cover", "folder", "front", "albumart", "albumartsmall", "album"]
        let extensions = ["jpg", "jpeg", "png"]
        let lower = files.map { $0.lowercased() }

        for name in candidates {
            for ext in extensions {
                if let i = lower.firstIndex(of: "\(name).\(ext)") {
                    return dir.appendingPathComponent(files[i])
                }
            }
        }
        for ext in extensions {
            if let i = lower.firstIndex(where: { $0.hasSuffix(".\(ext)") }) {
                return dir.appendingPathComponent(files[i])
            }
        }
        return nil
    }

    private func extractEmbeddedArt(from audioFile: URL) async -> URL? {
        let asset = AVURLAsset(url: audioFile)
        guard let common = try? await asset.load(.commonMetadata) else { return nil }
        for item in common where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                let ext = detectImageExtension(data)
                let dest = scratchDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
                try? data.write(to: dest)
                return dest
            }
        }
        return nil
    }

    private nonisolated func detectImageExtension(_ data: Data) -> String {
        if data.count >= 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return "jpg" }
        if data.count >= 4, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 { return "png" }
        return "jpg"
    }
}
