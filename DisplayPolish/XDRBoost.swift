import AppKit
import Combine
import CoreGraphics
import IOKit.ps
import notify

final class XDRBoost: NSObject, ObservableObject {
    static let gainRange = 1.0...3.2

    private enum Output {
        case direct(DirectXDRPanel)
        case metal(XDRMetalWindow)

        func close(preservingLevel: Bool = false) {
            switch self {
            case .direct(let panel): panel.close(preservingLevel: preservingLevel)
            case .metal(let window): window.close()
            }
        }
    }

    private struct Session {
        let output: Output
        let requested: Double
        let applied: Double

        var overlay: XDRMetalWindow? {
            if case .metal(let window) = output { return window }
            return nil
        }
    }

    @Published private var sessions: [CGDirectDisplayID: Session] = [:]
    @Published private var errors: [CGDirectDisplayID: String] = [:]
    private var monitor: Task<Void, Never>?
    private var powerSourceToken: Int32?

    var isActive: Bool { !sessions.isEmpty }

    override init() {
        super.init()
        DirectXDRPanel.restoreInterruptedSession()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshActiveDisplays),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(disableAll),
            name: NSApplication.willTerminateNotification, object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(disableAll), name: name, object: nil)
        }
        var token: Int32 = 0
        if notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main, { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshActiveDisplays() }
        }) == NOTIFY_STATUS_OK {
            powerSourceToken = token
        }
    }

    isolated deinit {
        monitor?.cancel()
        if let powerSourceToken { notify_cancel(powerSourceToken) }
    }

    func isSupported(on id: CGDirectDisplayID) -> Bool {
        Self.eligibleScreen(id) != nil
    }

    func requestedGain(on id: CGDirectDisplayID) -> Double? {
        sessions[id]?.requested
    }

    func appliedGain(on id: CGDirectDisplayID) -> Double {
        sessions[id]?.applied ?? 1
    }

    func directNits(on id: CGDirectDisplayID) -> Int? {
        guard case .direct(let panel)? = sessions[id]?.output, let nits = panel.levelNits else { return nil }
        return AppleBrightness.roundedNits(nits)
    }

    func message(on id: CGDirectDisplayID) -> String? {
        errors[id]
    }

    @discardableResult
    func setBrightness(_ value: Double, on id: CGDirectDisplayID, hardware: Bool) -> Bool {
        guard value.isFinite else { return false }
        if value <= 1 {
            stop(id)
            return !hardware || AppleBrightness.setLevel(max(value, 0), on: id)
        }

        guard let screen = Self.eligibleScreen(id) else {
            stop(id, message: String(localized: "XDR isn’t available on this display."))
            return true
        }
        let gain = min(value, Self.gainRange.upperBound)
        let current = sessions[id]
        if case .direct(let panel)? = current?.output {
            guard panel.setGain(gain) else { return false }
            updateDirect(panel, id: id, gain: gain, nits: panel.levelNits ?? panel.sdrWhiteNits)
            return true
        }
        if current == nil, hardware, let panel = DirectXDRPanel(displayID: id) {
            if panel.setGain(gain) {
                updateDirect(panel, id: id, gain: gain, nits: panel.levelNits ?? panel.sdrWhiteNits)
                startMonitoring()
                return true
            }
            panel.close()
        }

        render(on: screen, id: id, gain: gain)
        guard sessions[id] != nil else { return true }

        startMonitoring()
        return current != nil || !hardware || AppleBrightness.setLevel(1, on: id)
    }

    @objc func disableAll() {
        monitor?.cancel()
        monitor = nil
        for session in sessions.values { session.output.close() }
        sessions.removeAll()
        errors.removeAll()
    }

    private func stop(_ id: CGDirectDisplayID, message: String? = nil, preservingLevel: Bool = false) {
        sessions.removeValue(forKey: id)?.output.close(preservingLevel: preservingLevel)
        if errors[id] != message { errors[id] = message }
        if sessions.isEmpty {
            monitor?.cancel()
            monitor = nil
        }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.refreshActiveDisplays()
            }
        }
    }

    @objc private func refreshActiveDisplays() {
        let screens = NSScreen.screens
        let connected = Set(screens.compactMap(\.displayID))
        if !errors.keys.allSatisfy(connected.contains) {
            errors = errors.filter { connected.contains($0.key) }
        }
        for (id, session) in sessions {
            let screen = Self.eligibleScreen(id, among: screens)
            switch session.output {
            case .direct(let panel):
                let nits = panel.levelNits
                if let nits, nits <= panel.sdrWhiteNits {
                    stop(id, preservingLevel: true)
                } else if screen == nil {
                    stop(id)
                } else if let nits {
                    updateDirect(panel, id: id, nits: nits)
                }
            case .metal:
                if let screen {
                    render(on: screen, id: id, gain: session.requested)
                } else {
                    stop(id)
                }
            }
        }
    }

    private func updateDirect(_ panel: DirectXDRPanel, id: CGDirectDisplayID, gain: Double? = nil, nits: Double) {
        let applied = min(Self.gainRange.upperBound, max(1, nits / panel.sdrWhiteNits))
        let requested = gain ?? applied
        let current = sessions[id]
        if current == nil || (gain != nil && current?.requested != requested) ||
            abs((current?.applied ?? 1) - applied) >= 0.005 {
            sessions[id] = Session(output: .direct(panel), requested: requested, applied: applied)
        }
        if errors[id] != nil { errors[id] = nil }
    }

    private func render(on screen: NSScreen, id: CGDirectDisplayID, gain: Double) {
        let current = sessions[id]
        let overlay: XDRMetalWindow
        if let existing = current?.overlay, existing.frame == screen.frame, existing.isVisible {
            overlay = existing
        } else {
            current?.overlay?.close()
            guard let replacement = XDRMetalWindow(screen: screen, displayID: id) else {
                stop(id, message: String(localized: "Couldn’t start XDR on this display."))
                return
            }
            overlay = replacement
            overlay.show()
        }

        let requestChanged = current?.overlay !== overlay || current?.requested != gain
        // Keep the requested multiplier on the surface. WindowServer applies its own EDR limit.
        guard !requestChanged || overlay.present(gain: gain) else {
            if current?.overlay !== overlay { overlay.close() }
            stop(id, message: String(localized: "Couldn’t draw XDR on this display."))
            return
        }
        let headroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
        let applied = min(gain, max(headroom, 1))
        if requestChanged || abs((current?.applied ?? 1) - applied) >= 0.005 {
            sessions[id] = Session(output: .metal(overlay), requested: gain, applied: applied)
        }
        if errors[id] != nil { errors[id] = nil }
    }

    private static func eligibleScreen(_ id: CGDirectDisplayID, among screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        guard CGDisplayIsInMirrorSet(id) == 0 else { return nil }
        return screens.first { screen in
            screen.displayID == id && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.01
        }
    }
}
