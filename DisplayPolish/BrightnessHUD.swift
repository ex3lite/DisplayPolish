import AppKit
import SwiftUI

final class BrightnessHUD {
    private static let size = NSSize(width: 308, height: 66)
    private static let appearance: [(Double, Double)] = [
        (0, 0), (0.027, 0.25), (0.066, 0.46), (0.112, 0.63), (0.162, 0.77),
        (0.212, 0.86), (0.263, 0.91), (0.323, 0.95), (0.383, 0.98), (0.473, 0.993), (0.633, 1)
    ]
    private static let disappearance: [(Double, Double)] = [
        (0, 1), (0.016, 0.98), (0.05, 0.86), (0.082, 0.73), (0.116, 0.58),
        (0.148, 0.43), (0.182, 0.31), (0.216, 0.23), (0.25, 0.15),
        (0.291, 0.09), (0.341, 0.05), (0.40, 0.02), (0.50, 0)
    ]
    private let state = BrightnessHUDState()
    private var window: NSPanel?
    private var backdrop: NSVisualEffectView?
    private var dismissal: Task<Void, Never>?
    private var isDismissing = false

    func show(level: Double, boosted: Bool, on screen: NSScreen, directNits: Int? = nil) {
        let size = NSSize(width: min(Self.size.width, screen.visibleFrame.width - 50), height: Self.size.height)
        let frame = NSRect(
            x: screen.visibleFrame.maxX - size.width - 24.5,
            y: screen.visibleFrame.maxY - size.height - 10,
            width: size.width, height: size.height
        )
        let panel = window ?? makeWindow(frame: frame)
        if panel.frame.size != frame.size {
            backdrop?.maskImage = Self.capsuleMask(size: size)
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasVisible = panel.isVisible
        dismissal?.cancel()
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.contentView?.layoutSubtreeIfNeeded()
        }

        let ceiling = directNits != nil
            ? XDRBoost.gainRange.upperBound
            : max(level, min(Double(screen.maximumExtendedDynamicRangeColorComponentValue),
                             XDRBoost.gainRange.upperBound))
        let nits = directNits ?? screen.displayID.flatMap { AppleBrightness.estimatedNits(on: $0, gain: level) }
        state.update(level: level, boosted: boosted, ceiling: ceiling, nits: nits)

        if !wasVisible || isDismissing {
            let visibleProgress = wasVisible ? Double(backdrop?.layer?.presentation()?.opacity ?? 0) : 0
            animate(Self.appearance, from: visibleProgress, to: 1,
                    delay: wasVisible ? 0 : 0.075, reduceMotion: reduceMotion)
        }
        if !wasVisible { panel.alphaValue = 1 }
        isDismissing = false
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.06)) } catch { return }
            guard let self else { return }
            self.isDismissing = true
            let visibleProgress = Double(self.backdrop?.layer?.presentation()?.opacity ?? 1)
            self.animate(Self.disappearance, from: visibleProgress, to: 0, reduceMotion: reduceMotion)
            do { try await Task.sleep(for: .seconds(reduceMotion ? 0 : 0.50)) } catch { return }
            self.hide()
        }
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        isDismissing = false
        window?.orderOut(nil)
    }

    private func makeWindow(frame: NSRect) -> NSPanel {
        let bounds = NSRect(origin: .zero, size: frame.size)
        let blur = NSVisualEffectView(frame: bounds)
        blur.autoresizingMask = [.width, .height]
        blur.wantsLayer = true
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.capsuleMask(size: frame.size)

        let glass = NSGlassEffectView(frame: bounds)
        glass.autoresizingMask = [.width, .height]
        glass.style = .clear
        glass.cornerRadius = Self.size.height / 2
        let hosting = NSHostingView(rootView: BrightnessHUDView(state: state))
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        glass.contentView = hosting
        blur.addSubview(glass)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        let content = NSView(frame: bounds)
        content.wantsLayer = true
        content.addSubview(blur)
        panel.contentView = content
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backdrop = blur
        window = panel
        return panel
    }

    private static func capsuleMask(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            return true
        }
    }

    private func animate(_ curve: [(Double, Double)], from: Double, to: Double, delay: Double = 0,
                         reduceMotion: Bool) {
        guard let backdrop, let layer = backdrop.layer, let duration = curve.last?.0 else { return }
        // Leave the AppKit layer's anchor and position under AppKit's control.
        // Translate around the top center so the glass and its contents move together.
        let pivotX = backdrop.bounds.width * (0.5 - layer.anchorPoint.x)
        let pivotY = backdrop.bounds.height * (1 - layer.anchorPoint.y)
        func transform(at progress: Double) -> CATransform3D {
            let scale = 0.91 + 0.09 * progress
            var transform = CATransform3DMakeScale(scale, scale, 1)
            transform.m41 = pivotX * (1 - scale)
            transform.m42 = pivotY * (1 - scale) + (1 - progress) * 1.2
            return transform
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = Float(to)
        layer.transform = transform(at: reduceMotion ? 1 : to)
        layer.removeAnimation(forKey: "brightnessHUDMotion")

        if !reduceMotion {
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            let scale = CAKeyframeAnimation(keyPath: "transform")
            var progress = curve.map { sample in
                to == 1 ? from + (1 - from) * sample.1 : from * sample.1
            }
            let totalDuration = duration + delay
            var keyTimes = curve.map { NSNumber(value: ($0.0 + delay) / totalDuration) }
            if delay > 0 {
                progress.insert(from, at: 0)
                keyTimes.insert(0, at: 0)
            }
            opacity.values = progress
            opacity.keyTimes = keyTimes
            opacity.duration = totalDuration
            scale.values = progress.map { NSValue(caTransform3D: transform(at: $0)) }
            scale.keyTimes = keyTimes
            scale.duration = totalDuration
            let group = CAAnimationGroup()
            group.animations = [opacity, scale]
            group.duration = totalDuration
            layer.add(group, forKey: "brightnessHUDMotion")
        }
        CATransaction.commit()
    }
}

private final class BrightnessHUDState: ObservableObject {
    struct Reading {
        var level = 1.0
        var boosted = false
        var ceiling = 1.0625
        var nits: Int?
    }

    @Published private(set) var reading = Reading()

    func update(level: Double, boosted: Bool, ceiling: Double, nits: Int?) {
        reading = Reading(level: level, boosted: boosted, ceiling: max(ceiling, 1.0625), nits: nits)
    }
}

private struct BrightnessHUDView: View {
    @ObservedObject var state: BrightnessHUDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reading: BrightnessHUDState.Reading { state.reading }
    private var isXDR: Bool { reading.level > 1.001 }
    private var sunSymbol: String {
        if isXDR { return "sun.max.circle.fill" }
        return reading.level < 0.333 ? "sun.min.fill" : "sun.max.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sunSymbol)
                .foregroundStyle(isXDR ? Self.xdrTint : .white)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .font(.system(size: 25, weight: .medium))
                .frame(width: 29, height: 32)
                .offset(y: -0.5)
                .accessibilityHidden(true)

            GeometryReader { geometry in
                let boundary = geometry.size.width * 0.74
                let extensionFill = min(max((reading.level - 1) / (reading.ceiling - 1), 0), 1)

                HStack(spacing: 0) {
                    segments(16, fill: min(reading.level, 1), color: .white)
                        .frame(width: max(0, boundary - 2))
                    Color.clear.frame(width: 4)
                    segments(5, fill: extensionFill, color: Self.xdrTint)
                }
                .frame(height: 4)
                .clipShape(.capsule)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                Capsule()
                    .fill(reading.level >= 1 ? .white : .white.opacity(0.48))
                    .frame(width: 1, height: 10)
                    .position(x: boundary, y: geometry.size.height / 2)
                Text("100%")
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                    .position(x: boundary, y: geometry.size.height / 2 + 13)

                if reading.boosted {
                    if extensionFill > 0 {
                        Circle()
                            .fill(Self.xdrTint)
                            .frame(width: 5, height: 5)
                            .position(x: min(geometry.size.width - 2.5, boundary + 2 +
                                             (geometry.size.width - boundary - 2) * extensionFill),
                                      y: geometry.size.height / 2)
                    }
                }
                HStack(spacing: 6) {
                    if let nits = reading.nits {
                        Text("≈\(nits) nits")
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    if reading.boosted {
                        Text(reading.level, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(Self.xdrTint)
                    }
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: 36)
            .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.leading, 22.5)
        .padding(.trailing, 31.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.36), .white.opacity(0.08), .white.opacity(0.24)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.65
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.17), value: reading.level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.boosted ? String(localized: "XDR brightness") : String(localized: "Brightness"))
        .accessibilityValue(accessibleReading)
    }

    private static let xdrTint = Color(red: 0.68, green: 0.89, blue: 1)

    private var accessibleReading: Text {
        let percent = reading.level.formatted(.percent.precision(.fractionLength(0)))
        if let nits = reading.nits { return Text("\(percent), approximately \(nits) nits") }
        return Text(percent)
    }

    private func segments(_ count: Int, fill: Double, color: Color) -> some View {
        HStack(spacing: 1.4) {
            ForEach(0..<count, id: \.self) { index in
                let fraction = min(max(fill * Double(count) - Double(index), 0), 1)
                GeometryReader { segment in
                    Rectangle()
                        .fill(color.opacity(0.24))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(color)
                                .frame(width: segment.size.width * fraction)
                        }
                }
            }
        }
    }
}
