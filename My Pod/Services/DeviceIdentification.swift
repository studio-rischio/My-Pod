import Foundation

/// Writing `iPod_Control/Device/SysInfo` so libgpod can tell what iPod this is.
///
/// Why this exists: nothing since old iTunes writes that file. Finder inherited
/// iPod syncing but not that behaviour, and Windows restores don't do it
/// either, so a restored iPod arrives with the file empty or absent. libgpod
/// then resolves the model to its "Invalid" table row, finds no artwork
/// capabilities for it, and **writes no cover art at all** — without failing,
/// and without saying anything. Restoring again cannot fix it.
///
/// `nonisolated` so identification can run off the main actor: it does file I/O
/// on the iPod volume.
nonisolated enum DeviceIdentification {

    /// What we could work out about an unidentified iPod without asking.
    struct Findings: Sendable, Equatable {
        /// The USB serial, whatever kind it turned out to be.
        var serial: String?
        /// The serial, when it is a FireWire GUID and so belongs in `SysInfo`.
        var firewireGUID: String?
        /// A model libgpod resolved from the serial. Only ever set for a nano
        /// 3G or later, or a classic — older iPods report a GUID instead of an
        /// Apple serial, and a GUID cannot name a model.
        var suggested: IPodModel?

        static let none = Findings()
    }

    /// Everything we can learn about the device on our own, so the picker can
    /// preselect rather than interrogate.
    static func inspect(mountpoint: URL, models: [IPodModel]) -> Findings {
        var findings = Findings()

        guard let serial = USBSerial.forVolume(mountpoint) else {
            Log.device.info("identify: no USB serial for \(mountpoint.path)")
            return findings
        }
        findings.serial = serial

        if USBSerial.isFireWireGUID(serial) {
            findings.firewireGUID = serial
            // Expected on everything up to the nano 2G / 5G video — which is
            // most of what this feature is for. Not a failure.
            Log.device.info("identify: USB serial is a FireWire GUID; model must be chosen by hand")
            return findings
        }

        if let number = serial.withCString({ ipod_model_number_from_serial($0) }) {
            let modelNumber = String(cString: number)
            ipod_free_string(number)
            findings.suggested = models.first { $0.modelNumber == modelNumber }
            if let suggested = findings.suggested {
                Log.device.info("identify: serial resolved to \(suggested.modelName) \(suggested.generation) (\(modelNumber))")
            } else {
                Log.device.info("identify: serial resolved to model \(modelNumber), which isn't in the picker list")
            }
        } else {
            Log.device.info("identify: serial \(serial) matched no known model")
        }
        return findings
    }

    /// Write `SysInfo`. The caller must have closed the database first — see
    /// `ipod_write_sysinfo`, which explains why re-reading `SysInfo` under a
    /// live database corrupts its artwork.
    static func write(mountpoint: URL, modelNumber: String, firewireGUID: String?) throws {
        Log.device.info("identify: writing SysInfo at \(mountpoint.path) — ModelNumStr x\(modelNumber), FirewireGuid \(firewireGUID ?? "(unchanged)")")
        let result = mountpoint.path.withCString { mount in
            modelNumber.withCString { model in
                if let guid = firewireGUID {
                    return guid.withCString { ipod_write_sysinfo(mount, model, $0) }
                }
                return ipod_write_sysinfo(mount, model, nil)
            }
        }
        defer { ipod_free_string(result.error) }
        guard result.success != 0 else {
            let message = result.error.flatMap { String(cString: $0) } ?? "Unknown error"
            Log.device.error("identify: writing SysInfo failed: \(message)")
            throw IPodError.identifyFailed(message)
        }
        Log.device.info("identify: SysInfo written; any previous contents saved as SysInfo.mypod-backup")
    }
}
