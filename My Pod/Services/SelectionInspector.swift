import AppKit
import Foundation
import ImageIO

/// Facts about whatever is highlighted in the library tree.
///
/// Every field here costs file I/O to produce — `isCached` reads a marker and
/// stats a target, and the cached file's own size is another stat — so this is
/// computed off the main actor and handed back whole rather than being read
/// piecemeal from a view body.
nonisolated struct SelectionStats: Sendable, Equatable {
    var artists = 0
    var albums = 0
    var tracks = 0

    /// Size of the source files on disk.
    var sourceBytes: UInt64 = 0
    /// What these tracks would occupy on the iPod, measured where a converted
    /// file already exists and estimated where it doesn't.
    var deliveredBytes: UInt64 = 0

    var needConversion = 0
    var converted = 0
    var convertedBytes: UInt64 = 0

    /// Tracks already on the connected iPod. `nil` when nothing is attached —
    /// which is different from zero, and worth not claiming.
    var onIPod: Int?

    var checked = 0

    var pendingConversion: Int { needConversion - converted }
}

/// One track, in as much detail as the inspector shows.
nonisolated struct TrackDetail: Sendable, Equatable {
    var track: LibraryTrack
    var convertedURL: URL?
    var convertedBytes: UInt64?
    var deliveredBytes: UInt64
    var isOnIPod: Bool?
    var isChecked: Bool

    var albumDirectory: URL { track.url.deletingLastPathComponent() }
}

nonisolated enum SelectionInspector: Sendable {
    /// Gather stats for a set of tracks.
    ///
    /// `artists`/`albums` are passed in rather than derived, because the
    /// highlight may be a set of album rows from one artist, and counting
    /// distinct artist strings would report that as one artist selected — true,
    /// but not what was clicked.
    static func stats(
        tracks: [LibraryTrack],
        artists: Int,
        albums: Int,
        checkedPaths: Set<String>,
        iPodKeys: Set<TrackKey>?,
        conversion: ConversionService
    ) async -> SelectionStats {
        await Task.detached(priority: .userInitiated) {
            var out = SelectionStats(artists: artists, albums: albums, tracks: tracks.count)
            var onIPod = 0
            for track in tracks {
                out.sourceBytes &+= track.sizeBytes
                out.deliveredBytes &+= conversion.estimatedIPodBytes(for: track)
                if checkedPaths.contains(track.url.path) { out.checked += 1 }
                if let keys = iPodKeys, keys.contains(TrackKey(library: track)) { onIPod += 1 }
                guard track.needsConversion else { continue }
                out.needConversion += 1
                guard conversion.isCached(track) else { continue }
                out.converted += 1
                let url = conversion.iPodPlayableURL(for: track)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    out.convertedBytes &+= UInt64(size)
                }
            }
            out.onIPod = iPodKeys == nil ? nil : onIPod
            return out
        }.value
    }

    static func detail(
        for track: LibraryTrack,
        checkedPaths: Set<String>,
        iPodKeys: Set<TrackKey>?,
        conversion: ConversionService
    ) async -> TrackDetail {
        await Task.detached(priority: .userInitiated) {
            var detail = TrackDetail(
                track: track,
                deliveredBytes: conversion.estimatedIPodBytes(for: track),
                isOnIPod: iPodKeys.map { $0.contains(TrackKey(library: track)) },
                isChecked: checkedPaths.contains(track.url.path)
            )
            guard track.needsConversion else { return detail }
            let url = conversion.iPodPlayableURL(for: track)
            detail.convertedURL = url
            if conversion.isCached(track),
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                detail.convertedBytes = UInt64(size)
            }
            return detail
        }.value
    }

    // MARK: - Artwork

    /// One shared locator for the whole app session.
    ///
    /// `ArtworkLocator` memoizes per album directory, and that only pays off if
    /// the same instance is reused — which matters most for the thumbnail grid,
    /// where re-selecting an artist would otherwise redo every lookup, embedded
    /// art extraction included.
    private static let locator = ArtworkLocator(
        scratchDir: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MyPodArtworkPreview", isDirectory: true)
    )

    /// Cover art for an album, as an image ready to draw.
    ///
    /// Goes through `ArtworkLocator`, so the inspector shows exactly the image a
    /// sync would write to the device — including the embedded-art fallback. A
    /// miss here is a genuine preview of what the iPod will show: nothing.
    ///
    /// `maxPixel` downsamples at decode time rather than after. A grid of thirty
    /// covers held at full resolution is tens of megabytes of pixel data for
    /// something drawn 56 points wide.
    static func artwork(albumDirectory: URL, candidate: URL, maxPixel: Int) async -> NSImage? {
        guard let url = await locator.locate(albumDir: albumDirectory, candidateAudioFile: candidate) else {
            return nil
        }
        return downsampled(url, maxPixel: maxPixel)
    }

    private static func downsampled(_ url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
