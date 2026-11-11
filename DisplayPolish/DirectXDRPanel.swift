import CoreGraphics
import Foundation
import IOKit

final class DirectXDRPanel {
    private static let capKey = "BLNitsCap"
    private static let levelKey = "IOMFBBrightnessLevel"
    private static let physicalLimitKey = "limit_max_physical_brightness"
    private static let recoveryKey = "DirectXDRPanelRecovery"
    private static let fixedPoint = 65_536.0

    private struct Recovery: Codable {
        let registryID: UInt64
        let originalCap: Int64
        let originalLevel: Int64
        var target: Int64?
        var previousTarget: Int64?
    }

    private let service: io_service_t
    private let peakNits: Double
    private var recovery: Recovery
    let sdrWhiteNits: Double

    var levelNits: Double? {
        Self.read(Self.levelKey, from: service).map { Double($0) / Self.fixedPoint }
    }

    init?(displayID: CGDirectDisplayID) {
        guard CGDisplayIsBuiltin(displayID) != 0,
              let calibration = AppleBrightness.luminanceCalibration(on: displayID),
              let peak = calibration.hdr, peak > calibration.sdr,
              let service = Self.builtInService() else { return nil }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
              let cap = Self.read(Self.capKey, from: service),
              let level = Self.read(Self.levelKey, from: service) else {
            IOObjectRelease(service)
            return nil
        }
        self.service = service
        self.peakNits = peak
        self.sdrWhiteNits = calibration.sdr
        recovery = Recovery(registryID: registryID, originalCap: cap, originalLevel: level)
    }

    deinit {
        IOObjectRelease(service)
    }

    @discardableResult
    func setGain(_ gain: Double) -> Bool {
        guard let physicalLimit = Self.read(Self.physicalLimitKey, from: service),
              let oldCap = Self.read(Self.capKey, from: service),
              let oldLevel = Self.read(Self.levelKey, from: service) else { return false }
        let nits = min(sdrWhiteNits * gain, peakNits, Double(physicalLimit) / Self.fixedPoint)
        guard nits.isFinite, nits > sdrWhiteNits else { return false }
        let target = Int64((nits * Self.fixedPoint).rounded())
        if recovery.target == target, oldCap == target, abs(oldLevel - target) <= 1 { return true }

        let before = recovery
        recovery.previousTarget = recovery.target
        recovery.target = target
        guard Self.save(recovery) else {
            recovery = before
            Self.updateRecovery(before)
            return false
        }
        guard Self.write(target, key: Self.capKey, to: service) else {
            recovery = before
            Self.updateRecovery(before)
            return false
        }
        guard Self.write(target, key: Self.levelKey, to: service) else {
            if Self.write(oldCap, key: Self.capKey, to: service) {
                recovery = before
                Self.updateRecovery(before)
            }
            return false
        }
        return true
    }

    func close() {
        if Self.restore(recovery, on: service) {
            UserDefaults.standard.removeObject(forKey: Self.recoveryKey)
            recovery.target = nil
            recovery.previousTarget = nil
        }
    }

    static func restoreInterruptedSession() {
        guard let data = UserDefaults.standard.data(forKey: recoveryKey),
              let recovery = try? JSONDecoder().decode(Recovery.self, from: data),
              let service = builtInService() else { return }
        defer { IOObjectRelease(service) }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { return }
        if registryID != recovery.registryID || restore(recovery, on: service) {
            UserDefaults.standard.removeObject(forKey: recoveryKey)
        }
    }

    private static func updateRecovery(_ recovery: Recovery) {
        if recovery.target == nil {
            UserDefaults.standard.removeObject(forKey: recoveryKey)
        } else {
            _ = save(recovery)
        }
    }

    private static func save(_ recovery: Recovery) -> Bool {
        guard let data = try? JSONEncoder().encode(recovery) else { return false }
        UserDefaults.standard.set(data, forKey: recoveryKey)
        return UserDefaults.standard.synchronize()
    }

    private static func restore(_ recovery: Recovery, on service: io_service_t) -> Bool {
        let targets = [recovery.target, recovery.previousTarget].compactMap { $0 }
        guard !targets.isEmpty else { return true }
        guard let cap = read(capKey, from: service), let level = read(levelKey, from: service) else { return false }
        let ownsCap = targets.contains(cap)
        let ownsLevel = targets.contains { abs(level - $0) <= 1 }
        let capRestored = !ownsCap || write(recovery.originalCap, key: capKey, to: service)
        let levelRestored = !ownsLevel || write(recovery.originalLevel, key: levelKey, to: service)
        return capRestored && levelRestored
    }

    private static func builtInService() -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AppleCLCD2"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var match: io_service_t?
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            let attributes = IORegistryEntryCreateCFProperty(candidate, "DisplayAttributes" as CFString, nil, 0)?
                .takeRetainedValue() as? [String: Any]
            let product = attributes?["ProductAttributes"] as? [String: Any]
            guard (product?["ManufacturerID"] as? String) == "00-10-fa",
                  read("Brightness_Scale", from: candidate) != nil,
                  read(physicalLimitKey, from: candidate) != nil else {
                IOObjectRelease(candidate)
                continue
            }
            if let match {
                IOObjectRelease(match)
                IOObjectRelease(candidate)
                return nil
            }
            match = candidate
        }
        return match
    }

    private static func read(_ key: String, from service: io_service_t) -> Int64? {
        let value = IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue()
        guard let number = value as? NSNumber, (0...10_000 * fixedPoint).contains(number.doubleValue) else { return nil }
        return number.int64Value
    }

    private static func write(_ value: Int64, key: String, to service: io_service_t) -> Bool {
        IORegistryEntrySetCFProperty(service, key as CFString, NSNumber(value: value)) == KERN_SUCCESS
    }
}
