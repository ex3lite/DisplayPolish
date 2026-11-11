import AppKit
import SwiftUI

struct DisplayMenu: View {
    @ObservedObject var xdr: XDRBoost
    @ObservedObject var keys: BrightnessKeys
    @State private var displays: [ConnectedDisplay] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)

            if displays.isEmpty {
                Text("No connected displays")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(displays) { display in
                            BrightnessControl(display: display, xdr: xdr)
                            if display.id != displays.last?.id { Divider() }
                        }
                    }
                    .padding(2)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 375)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .padding(.top, 8)
                .padding(.bottom, 10)
            keySettings
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 342)
        .background(alignment: .top) {
            if xdr.isActive {
                LinearGradient(colors: [BrightnessControl.xdrTint.opacity(0.10), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 82)
                    .allowsHitTesting(false)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: xdr.isActive ? "sun.max.circle.fill" : "sun.max.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(xdr.isActive ? BrightnessControl.xdrTint : Color.primary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text("Brightness")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button("Quit DisplayPolish", systemImage: "power") {
                    keys.stop()
                    xdr.disableAll()
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("DisplayPolish menu")
        }
    }

    private var keySettings: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: "keyboard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 19)
                    .accessibilityHidden(true)
                Text("Brightness keys")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                if keys.hasAccess {
                    Toggle("Use brightness keys", isOn: Binding(get: { keys.isEnabled }, set: keys.setEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(BrightnessControl.xdrTint)
                        .help("Adjust the display under the pointer")
                } else if keys.hasRequestedAccess {
                    Button("Open Settings…", action: keys.requestAccess)
                        .controlSize(.small)
                } else {
                    Button("Grant Access…", action: keys.requestAccess)
                        .controlSize(.small)
                }
            }
            if !keys.hasAccess {
                Text(keys.hasRequestedAccess
                     ? String(localized: "If DisplayPolish is already enabled in Accessibility, remove its entry and add the current build.")
                     : String(localized: "Allow DisplayPolish to adjust the display under the pointer."))
                    .padding(.leading, 28)
            }
            if let status = keys.status {
                Text(status)
                    .padding(.leading, 28)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func refresh() {
        displays = ConnectedDisplay.read()
        keys.refresh()
    }
}
