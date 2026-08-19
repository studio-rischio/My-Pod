import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turning an arbitrary image into an album's `cover.jpg`.
///
/// ImageIO throughout rather than AppKit: `NSImage` will hand back a
/// representation at the wrong scale and silently ignore EXIF orientation, which
/// matters here because the obvious source for a missing cover is a phone photo
/// of the sleeve.
///
/// Writing `cover.jpg` needs no change to the sync path at all —
/// `ArtworkLocator` checks `cover` before every other name and `jpg` before
/// every other extension, so the new file outranks whatever the folder already
/// had.
nonisolated enum CoverArt {
    /// How a non-square source becomes square.
    enum Fill: String, CaseIterable, Identifiable, Sendable {
        /// Centre-crop. What every music app does, and covers are near-square
        /// anyway, so it's the default.
        case crop
        /// Scale to fit and pad the remainder. Right for a wide gatefold scan,
        /// where cropping would cut the artwork in half.
        case fit

        var id: String { rawValue }
        var title: String { self == .crop ? "Crop" : "Fit" }
    }

    /// Longest edge of the file written.
    ///
    /// Deliberately generous: the device needs far less — 140×140 on iPod Photo,
    /// 320×240 fullscreen, 100×100 on nano — and libgpod renders its own
    /// thumbnails from whatever it's given. The resolution is for the user's
    /// library, not the iPod.
    static let maxEdge = 1000
    static let fileName = "cover.jpg"
    private static let jpegQuality = 0.85

    // MARK: - Loading

    /// Decode a file, with EXIF orientation applied.
    static func load(contentsOf url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(decode)
    }

    /// Decode raw bytes — a browser drag or a screenshot arrives this way, with
    /// no file behind it.
    static func load(data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(decode)
    }

    /// `kCGImageSourceCreateThumbnailWithTransform` is what applies orientation;
    /// there is no cheaper way to get an upright `CGImage` out of ImageIO. The
    /// cap is far above `maxEdge` so nothing is thrown away before the caller
    /// has chosen crop or fit, and `FromImageAlways` never upscales, so a small
    /// source stays its own size.
    private static func decode(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Squaring

    /// Square `image`, scaled so its edge is at most `maxEdge`.
    ///
    /// Crop and fit differ by one number — which dimension the scale is derived
    /// from — so they share everything else, including the centring.
    static func square(_ image: CGImage, fill: Fill) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        guard w > 0, h > 0 else { return nil }

        let sourceEdge = fill == .crop ? min(w, h) : max(w, h)
        let edge = Int(min(sourceEdge, Double(maxEdge)).rounded())
        guard edge > 0 else { return nil }

        let scale = Double(edge) / sourceEdge
        let drawW = w * scale, drawH = h * scale

        guard let context = CGContext(
            data: nil,
            width: edge,
            height: edge,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            // JPEG carries no alpha. Painting onto an opaque context means the
            // padding in `.fit` is a real colour rather than black-by-default.
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        let pad = fill == .fit ? edgeColor(of: image) : CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setFillColor(pad)
        context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (Double(edge) - drawW) / 2,
            y: (Double(edge) - drawH) / 2,
            width: drawW,
            height: drawH
        ))
        return context.makeImage()
    }

    /// A mount colour for `.fit` padding, taken from the outside of the image.
    ///
    /// Black bars around a sleeve read as a mistake; a colour drawn from the
    /// artwork itself reads as a mount. Measured by drawing the image into a 3×3
    /// buffer and averaging the eight outer cells — so it's the average of the
    /// outer *regions*, not of a thin border. That's deliberate: a one-pixel
    /// edge sample picks up scanner white, JPEG ringing, or a stray dark line
    /// and produces a mount that matches nothing in the picture.
    private static func edgeColor(of image: CGImage) -> CGColor {
        let fallback = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        var pixels = [UInt8](repeating: 0, count: 3 * 3 * 4)
        let result: CGColor? = pixels.withUnsafeMutableBytes { buffer -> CGColor? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: 3,
                      height: 3,
                      bitsPerComponent: 8,
                      bytesPerRow: 3 * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  )
            else { return nil }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 3, height: 3))

            var r = 0.0, g = 0.0, b = 0.0
            var count = 0.0
            for index in 0..<9 where index != 4 {
                let offset = index * 4
                r += Double(base.load(fromByteOffset: offset, as: UInt8.self))
                g += Double(base.load(fromByteOffset: offset + 1, as: UInt8.self))
                b += Double(base.load(fromByteOffset: offset + 2, as: UInt8.self))
                count += 1
            }
            return CGColor(red: r / count / 255, green: g / count / 255, blue: b / count / 255, alpha: 1)
        }
        return result ?? fallback
    }

    // MARK: - Writing

    enum WriteError: LocalizedError {
        case notWritable(URL)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .notWritable(let dir):
                return "“\(dir.lastPathComponent)” can't be written to. Cover art has to live beside the music."
            case .encodingFailed:
                return "That image couldn't be encoded as a JPEG."
            }
        }
    }

    static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        // Only the image is written — no source metadata is carried over, so
        // location tags on a phone photo don't ride along into the library.
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Write `image` as `<albumDirectory>/cover.jpg`.
    @discardableResult
    static func write(_ image: CGImage, toAlbum albumDirectory: URL) throws -> URL {
        guard isWritable(albumDirectory) else {
            Log.artwork.error("can't write cover art: \(albumDirectory.path) is not writable")
            throw WriteError.notWritable(albumDirectory)
        }
        guard let data = jpegData(image) else {
            Log.artwork.error("can't write cover art: JPEG encoding failed")
            throw WriteError.encodingFailed
        }
        let destination = albumDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            Log.artwork.error("writing \(fileName) to \(albumDirectory.path) failed: \(error.localizedDescription)")
            throw error
        }
        Log.artwork.info(
            "wrote \(fileName) (\(image.width)×\(image.height), \(data.count) bytes) to \(albumDirectory.lastPathComponent)"
        )
        return destination
    }

    // MARK: - Inspecting a folder

    /// Some libraries live on a NAS or a read-only mount. Checked before the
    /// sheet offers Save rather than after the user has chosen an image.
    static func isWritable(_ directory: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: directory.path)
    }

    static func existingCover(in directory: URL) -> URL? {
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The image the folder is using *now* that a new `cover.jpg` would outrank.
    ///
    /// Reported rather than deleted: leaving a silently-ignored duplicate behind
    /// is confusing, but so is an app quietly removing files from a music folder.
    static func shadowedImage(in directory: URL) -> URL? {
        guard let current = ArtworkLocator.imageInDirectory(directory) else { return nil }
        return current.lastPathComponent.lowercased() == fileName ? nil : current
    }
}
