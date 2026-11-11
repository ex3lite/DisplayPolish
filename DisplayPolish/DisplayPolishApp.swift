import SwiftUI

@main
struct DisplayPolishApp: App {
    @StateObject private var xdr: XDRBoost
    @StateObject private var keys: BrightnessKeys

    init() {
        let boost = XDRBoost()
        _xdr = StateObject(wrappedValue: boost)
        _keys = StateObject(wrappedValue: BrightnessKeys(boost: boost))
    }

    var body: some Scene {
        let brightnessKeys = keys
        MenuBarExtra("DisplayPolish", systemImage: xdr.isActive ? "sun.max.fill" : "sun.max") {
            DisplayMenu(xdr: xdr, keys: brightnessKeys)
        }
        .menuBarExtraStyle(.window)
    }
}
