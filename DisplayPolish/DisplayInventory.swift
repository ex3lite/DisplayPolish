import AppKit
import CoreGraphics

struct ConnectedDisplay: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool

    static func read() -> [Self] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return Self(id: id, name: screen.localizedName, isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
