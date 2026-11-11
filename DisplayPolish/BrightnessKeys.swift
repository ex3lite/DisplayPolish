import AppKit
import ApplicationServices
import Combine

enum BrightnessKey: Int {
    case increase = 2
    case decrease = 3

    init?(mediaData: Int) {
        // NX_SYSDEFINED encodes the media key and its down/up state in data1.
        guard (mediaData >> 8) & 0xff == 0x0a else { return nil }
        self.init(rawValue: (mediaData >> 16) & 0xffff)
    }

    func adjustedLevel(_ current: Double, lowerBound: Double) -> Double {
        let step = 1.0 / 16
        switch self {
        case .increase:
            if current < 0.999 { return min(current + step, 1) }
            return min(max(current, 1) + step, XDRBoost.gainRange.upperBound)
        case .decrease:
            if current > 1 { return max(current - step, 1) }
            return max(current - step, lowerBound)
        }
    }
}

final class BrightnessKeys: ObservableObject {
    private static let preferenceKey = "brightnessKeysEnabled"
    @Published private(set) var isEnabled: Bool
    @Published private(set) var hasAccess = false
    @Published private(set) var hasRequestedAccess = false
    @Published private(set) var status: String?

    private weak var boost: XDRBoost?
    private let hud = BrightnessHUD()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var accessMonitor: Task<Void, Never>?

    init(boost: XDRBoost) {
        self.boost = boost
        UserDefaults.standard.register(defaults: [Self.preferenceKey: true])
        isEnabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        refresh()
        accessMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        refresh()
    }

    func requestAccess() {
        if hasRequestedAccess,
           let pane = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(pane)
        } else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            hasRequestedAccess = true
        }
        refresh()
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if hasAccess != trusted { hasAccess = trusted }
        if trusted && hasRequestedAccess { hasRequestedAccess = false }
        guard trusted, isEnabled else {
            if tap != nil { stop() }
            setStatus(nil)
            return
        }
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let mediaMask = (CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mediaMask, callback: Self.handleEvent,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            setStatus(String(localized: "Couldn’t connect to the brightness keys. Turn the setting off and on to retry."))
            return
        }

        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        setStatus(nil)
    }

    func stop() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        hud.hide()
    }

    private func setStatus(_ value: String?) {
        if status != value { status = value }
    }

    private static let handleEvent: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let listener = Unmanaged<BrightnessKeys>.fromOpaque(context).takeUnretainedValue()
        // The callback is synchronous on the main run loop. The event stays within this call.
        nonisolated(unsafe) let callbackEvent = event
        let handled = MainActor.assumeIsolated {
            if type == .tapDisabledByTimeout, let tap = listener.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return listener.route(callbackEvent, type: type)
        }
        return handled ? nil : Unmanaged.passUnretained(event)
    }

    private func route(_ event: CGEvent, type: CGEventType) -> Bool {
        let reservedModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        guard event.flags.intersection(reservedModifiers).isEmpty,
              let key = Self.brightnessKey(from: event, type: type),
              let boost else { return false }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }),
              let id = screen.displayID, boost.isSupported(on: id) else { return false }

        // Queue the adjustment so WindowServer does not wait on Metal or DisplayServices.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tap != nil else { return }
            self.adjust(key, on: id)
        }
        return true
    }

    static func brightnessKey(from event: CGEvent, type: CGEventType) -> BrightnessKey? {
        if type == .keyDown {
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: return .increase
            case 145: return .decrease
            default: return nil
            }
        }
        guard type.rawValue == NSEvent.EventType.systemDefined.rawValue,
              let event = NSEvent(cgEvent: event), event.subtype.rawValue == 8 else { return nil }
        return BrightnessKey(mediaData: event.data1)
    }

    func adjust(_ key: BrightnessKey, on id: CGDirectDisplayID) {
        guard let boost, boost.isSupported(on: id),
              let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }
        let hardware = AppleBrightness.level(on: id)
        let requested = boost.requestedGain(on: id)
        let current = requested ?? hardware ?? 1
        let next = key.adjustedLevel(current, lowerBound: hardware == nil ? 1 : 0)

        if next != current {
            boost.setBrightness(next, on: id, hardware: hardware != nil)
        }

        let boosted = boost.requestedGain(on: id) != nil
        let level = boosted ? boost.appliedGain(on: id) : AppleBrightness.level(on: id) ?? 1
        hud.show(level: level, boosted: boosted, on: screen, directNits: boost.directNits(on: id))
    }
}
