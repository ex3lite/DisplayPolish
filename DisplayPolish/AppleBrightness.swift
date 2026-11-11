import CoreGraphics
import Darwin
import Foundation

enum AppleBrightness {
    private typealias Read = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Write = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private typealias ActivePreset = @convention(c) (CGDirectDisplayID) -> UInt
    private typealias CopyPreset = @convention(c) (CGDirectDisplayID, UInt) -> Unmanaged<CFDictionary>?

    private static let functions: (read: Read, write: Write, readLinear: Read?)? = {
        let libraryPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let library = dlopen(libraryPath, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let read = dlsym(library, "DisplayServicesGetBrightness"),
              let write = dlsym(library, "DisplayServicesSetBrightness") else {
            dlclose(library)
            return nil
        }
        // Keep DisplayServices loaded for the lifetime of these function pointers.
        let readLinear = dlsym(library, "DisplayServicesGetLinearBrightness").map { unsafeBitCast($0, to: Read.self) }
        return (unsafeBitCast(read, to: Read.self), unsafeBitCast(write, to: Write.self), readLinear)
    }()

    private static let presets: (active: ActivePreset, copy: CopyPreset)? = {
        guard let library = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        else { return nil }
        guard let active = dlsym(library, "CoreDisplay_Display_GetActivePresetIndex"),
              let copy = dlsym(library, "CoreDisplay_Display_CopyPreset") else {
            dlclose(library)
            return nil
        }
        return (unsafeBitCast(active, to: ActivePreset.self), unsafeBitCast(copy, to: CopyPreset.self))
    }()

    static func level(on displayID: CGDirectDisplayID) -> Double? {
        var level: Float = -1
        guard let functions, functions.read(displayID, &level) == 0, (0...1).contains(level) else { return nil }
        return Double(level)
    }

    static func setLevel(_ level: Double, on displayID: CGDirectDisplayID) -> Bool {
        guard let functions, (0...1).contains(level) else { return false }
        return functions.write(displayID, Float(level)) == 0
    }

    static func estimatedNits(on displayID: CGDirectDisplayID, gain: Double) -> Int? {
        guard gain.isFinite, let readLinear = functions?.readLinear,
              let calibration = luminanceCalibration(on: displayID) else { return nil }
        var linear: Float = 0
        guard readLinear(displayID, &linear) == 0, (0...1.01).contains(linear) else { return nil }
        let scaledWhite = calibration.sdr * min(Double(linear), 1) * max(1, gain)
        return roundedNits(min(scaledWhite, calibration.hdr ?? scaledWhite))
    }

    static func luminanceCalibration(on displayID: CGDirectDisplayID) -> (sdr: Double, hdr: Double?)? {
        guard let presets else { return nil }
        let index = presets.active(displayID)
        guard index != .max, let info = presets.copy(displayID, index)?.takeRetainedValue() as? [String: Any],
              let white = (info["PresetMaxSDRLuminance"] as? NSNumber)?.doubleValue,
              (1...10_000).contains(white) else { return nil }
        let peak = (info["PresetMaxHDRLuminance"] as? NSNumber)?.doubleValue
        return (white, peak.map { max(white, $0) })
    }

    static func roundedNits(_ nits: Double) -> Int {
        let step = nits >= 100 ? 10.0 : 1.0
        return Int((nits / step).rounded() * step)
    }
}
