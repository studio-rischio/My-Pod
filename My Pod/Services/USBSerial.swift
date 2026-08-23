import Foundation
import IOKit

/// Reads the USB serial number of the device a volume is mounted from.
///
/// Used only for identifying an iPod that libgpod couldn't identify itself.
/// What comes back is one of two quite different things depending on how old
/// the iPod is, and the difference matters:
///
/// - A **FireWire GUID** (16 hex digits) on anything up to the nano 2G / 5G
///   video. This is what `SysInfo`'s `FirewireGuid` field wants, but it says
///   nothing about the model.
/// - An **Apple serial** ("8L8271TV9V") on a nano 3G or later, and on the
///   classic. libgpod can map its last three characters to an exact model.
///
/// `nonisolated` so identification can run off the main actor.
nonisolated enum USBSerial {
    /// The serial number of the USB device backing `volume`, or nil if the
    /// volume isn't on USB or exposes no serial.
    static func forVolume(_ volume: URL) -> String? {
        guard let bsdName = bsdName(of: volume) else { return nil }

        let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        // Walk *up* the IOService plane rather than assuming a fixed depth:
        // between the partition and the USB device sit the media, the block
        // storage driver, the mass-storage class driver and the interface, and
        // that chain is not the same on every Mac.
        let property = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "USB Serial Number" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
        guard let serial = property as? String else { return nil }
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "disk24s3" for a volume mounted from /dev/disk24s3.
    private static func bsdName(of volume: URL) -> String? {
        var stat = statfs()
        guard volume.withUnsafeFileSystemRepresentation({ path -> Bool in
            guard let path else { return false }
            return statfs(path, &stat) == 0
        }) else { return nil }

        let from = withUnsafeBytes(of: &stat.f_mntfromname) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        guard from.hasPrefix("/dev/") else { return nil }
        return String(from.dropFirst("/dev/".count))
    }

    /// Whether a serial is a FireWire GUID rather than an Apple serial number.
    ///
    /// The C side refuses to feed a GUID to libgpod's serial→model table (27 of
    /// its keys are pure hex, so a GUID can resolve to a confidently wrong
    /// model); this is the same test, used here to decide whether the serial is
    /// worth writing as `FirewireGuid`.
    static func isFireWireGUID(_ serial: String) -> Bool {
        var s = Substring(serial)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        return s.count == 16 && s.allSatisfy(\.isHexDigit)
    }
}
