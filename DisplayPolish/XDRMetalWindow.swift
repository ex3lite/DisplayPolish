import AppKit
import MetalKit
import QuartzCore

final class XDRMetalWindow {
    private let window: NSWindow
    private let layer: CAMetalLayer
    private let queue: any MTLCommandQueue
    var frame: NSRect { window.frame }
    var isVisible: Bool { window.isVisible }

    init?(screen: NSScreen, displayID: CGDirectDisplayID) {
        guard let device = CGDirectDisplayCopyCurrentMetalDevice(displayID) ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        self.queue = queue

        let frame = screen.frame
        let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1, height: 1)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = colorSpace
        view.isPaused = true
        guard let layer = view.layer as? CAMetalLayer else { return nil }
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        // WindowServer accepts this undocumented compositing mode for EDR surfaces.
        layer.compositingFilter = "multiply"
        guard layer.compositingFilter as? String == "multiply" else { return nil }
        self.layer = layer

        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.setFrame(frame, display: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = view
    }

    @discardableResult
    func present(gain: Double) -> Bool {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        guard let attachment = pass.colorAttachments[0] else { return false }
        attachment.texture = drawable.texture
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: gain, green: gain, blue: gain, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        return true
    }

    func show() {
        window.orderFrontRegardless()
    }

    func close() {
        window.close()
    }
}
