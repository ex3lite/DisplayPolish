import CoreGraphics
import SwiftUI

struct BrightnessControl: View {
    static let xdrTint = Color(red: 0.40, green: 0.79, blue: 0.97)

    let display: ConnectedDisplay
    @ObservedObject var xdr: XDRBoost
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hardwareLevel: Double?
    @State private var estimatedNits: Int?
    @State private var hardwareError = false
    @GestureState private var isDragging = false
    @FocusState private var sliderFocused: Bool
    @State private var focusedByPointer = false

    private var supportsXDR: Bool { xdr.isSupported(on: display.id) }
    private var requestedGain: Double? { xdr.requestedGain(on: display.id) }
    private var appliedGain: Double { xdr.appliedGain(on: display.id) }
    private var value: Double { requestedGain ?? hardwareLevel ?? 1 }
    private var effectiveLevel: Double { requestedGain == nil ? value : appliedGain }
    private var isBoosted: Bool { effectiveLevel > 1.001 }
    private var xdrForeground: Color { colorScheme == .dark ? Self.xdrTint : Color(red: 0.02, green: 0.34, blue: 0.48) }
    private var sdrFill: Color { colorScheme == .dark ? Color(white: 0.86) : Color(white: 0.20) }
    private var mutedText: Color { Color.primary.opacity(0.68) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 19)
                    .accessibilityHidden(true)
                Text(display.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if supportsXDR {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let estimatedNits {
                            Text("≈\(estimatedNits) nits")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(effectiveLevel, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: estimatedNits == nil ? 13 : 11, weight: .medium))
                            .foregroundStyle(estimatedNits == nil ? Color.primary : mutedText)
                    }
                    .foregroundStyle(isBoosted ? xdrForeground : Color.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize()
                    .accessibilityHidden(true)
                }
            }

            if supportsXDR {
                brightnessSlider
                if let requestedGain, appliedGain + 0.01 < requestedGain {
                    Text("Requested \(requestedGain, format: .percent.precision(.fractionLength(0))) · Limited by display")
                        .foregroundStyle(mutedText)
                }
            } else {
                Text("XDR unavailable")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }

            if hardwareError {
                Text("Couldn’t set brightness. Try macOS brightness controls.")
                    .foregroundStyle(.secondary)
            }
            if let message = xdr.message(on: display.id) {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .task(id: supportsXDR) {
            guard supportsXDR else { return }
            while !Task.isCancelled {
                if !isDragging { hardwareLevel = AppleBrightness.level(on: display.id) }
                updateNits()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: appliedGain) { _, _ in updateNits() }
    }

    private var brightnessSlider: some View {
        GeometryReader { geometry in
            let inset = 7.0
            let width = max(geometry.size.width - inset * 2, 1)
            let boundary = hardwareLevel == nil ? 0 : width * 0.68
            let sdrWidth = boundary * min(value, 1)
            let xdrWidth = (width - boundary) * max(0, (value - 1) / (XDRBoost.gainRange.upperBound - 1))
            let position = inset + sdrWidth + xdrWidth

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    rail(width: boundary, fill: sdrWidth, color: sdrFill)
                    rail(width: width - boundary, fill: xdrWidth, color: Self.xdrTint)
                }
                .clipShape(.capsule)
                .position(x: geometry.size.width / 2, y: 13)

                Rectangle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 1, height: 9)
                    .position(x: inset + boundary, y: 13)
                Circle()
                    .fill(.white)
                    .overlay {
                        Circle().strokeBorder(.black.opacity(0.18), lineWidth: 1)
                    }
                    .overlay {
                        if sliderFocused && !focusedByPointer {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .position(x: position, y: 13)

                Text("100%")
                    .position(x: max(16, inset + boundary), y: 31)
                Text("XDR")
                    .foregroundStyle(isBoosted ? xdrForeground : mutedText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, inset)
                    .position(x: geometry.size.width / 2, y: 31)
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(mutedText)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        focusedByPointer = true
                        let x = min(max(drag.location.x - inset, 0), width)
                        if x <= boundary && boundary > 0 {
                            adjust(x / boundary)
                        } else {
                            let extensionFraction = (x - boundary) / (width - boundary)
                            adjust(1 + extensionFraction * (XDRBoost.gainRange.upperBound - 1))
                        }
                    }
            )
        }
        .frame(height: 39)
        .focusable()
        .focused($sliderFocused)
        .focusEffectDisabled()
        .onChange(of: sliderFocused) { _, focused in
            if !focused { focusedByPointer = false }
        }
        .onKeyPress(.leftArrow) {
            focusedByPointer = false
            step(.decrease)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            focusedByPointer = false
            step(.increase)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brightness for \(display.name)")
        .accessibilityValue(accessibleReading)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(.increase)
            case .decrement: step(.decrease)
            @unknown default: break
            }
        }
        .animation(reduceMotion || isDragging ? nil : .easeOut(duration: 0.15), value: value)
    }

    private var accessibleReading: Text {
        let percent = effectiveLevel.formatted(.percent.precision(.fractionLength(0)))
        if let estimatedNits { return Text("\(percent), approximately \(estimatedNits) nits") }
        return Text(percent)
    }

    private func rail(width: Double, fill: Double, color: Color) -> some View {
        Rectangle()
            .fill(color.opacity(0.23))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(color)
                    .frame(width: max(0, min(fill, width)))
            }
            .frame(width: width, height: 5)
    }

    private func step(_ direction: BrightnessKey) {
        adjust(direction.adjustedLevel(value, lowerBound: hardwareLevel == nil ? 1 : 0), quantize: false)
    }

    private func adjust(_ level: Double, quantize: Bool = true) {
        let level = quantize ? (level * 100).rounded() / 100 : level
        guard level != value else { return }
        let hasHardwareControl = hardwareLevel != nil
        hardwareError = !xdr.setBrightness(level, on: display.id, hardware: hasHardwareControl)
        if hasHardwareControl && !hardwareError {
            hardwareLevel = min(max(level, 0), 1)
        }
        updateNits()
    }

    private func updateNits() {
        estimatedNits = xdr.directNits(on: display.id)
            ?? AppleBrightness.estimatedNits(on: display.id, gain: appliedGain)
    }
}
