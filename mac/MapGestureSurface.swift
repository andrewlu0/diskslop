import AppKit
import Metal
import QuartzCore

// The display link and its drawables live on one run loop, independent of AppKit event tracking.
private final class MapDisplayThread {
    static let shared = MapDisplayThread()
    private let lock = NSLock()
    private var loop: CFRunLoop?, waiting = [() -> Void]()

    private init() {
        let thread = Thread { [self] in
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            let tasks = lock.withLock {
                loop = CFRunLoopGetCurrent()
                let tasks = waiting; waiting.removeAll()
                return tasks
            }
            for task in tasks { task() }
            CFRunLoopRun()
        }
        thread.name = "DiskSlop treemap presentation"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    func perform(_ task: @escaping () -> Void) {
        let ready = lock.withLock { () -> CFRunLoop? in
            if loop == nil { waiting.append(task) }
            return loop
        }
        if let ready {
            CFRunLoopPerformBlock(ready, CFRunLoopMode.defaultMode.rawValue, task)
            CFRunLoopWakeUp(ready)
        }
    }
}

final class MapGestureSurface: NSObject {
    private struct Frame {
        var base: MTLTexture, detail: MTLTexture, detailRect: CGRect
        var labels: MapGestureLabels?
        var highlight: MapGestureLabels.Highlight?
        var from: CGRect, to: CGRect, changed: Double, duration: Double = 0
        func viewport(at time: Double) -> CGRect {
            guard duration > 0, time < changed + duration else { return to }
            let t = ChartMotion.easeOut(min(1, max(0, (time - changed) / duration)))
            let span = from.width + (to.width - from.width) * t
            return CGRect(x: from.minX + (to.minX - from.minX) * t,
                y: from.minY + (to.minY - from.minY) * t, width: span, height: span)
        }
    }
    private let lock = NSLock(), renderer: ChartRenderer, pipeline: MTLRenderPipelineState
    private let metal = CAMetalLayer(), period: Double, size: CGSize, scale: CGFloat
    private let smooth: Bool
    private let firstPresentation: (MapGestureSurface) -> Void
    private var quads = [MapGestureLabels.Quad]()
    private var frame: Frame
    private var invalidate: (() -> Void)?
    private var active = true
    private(set) var isDisplaying = false
    private var presented: (time: Double, viewport: CGRect)?
    private var awaitingPresentationSince: CFTimeInterval? = 0
    var visibleViewport: CGRect? { isDisplaying ? lock.withLock { presented?.viewport } : nil }
    private var lastViewport: CGRect?, lastDetail: MTLTexture?, lastBase: MTLTexture?
    private var lastHighlight: MapGestureLabels.Highlight?

    @available(macOS 14.0, *)
    init?(host: NSView, renderer: ChartRenderer, base: RenderedFiles, detail: RenderedFiles, viewport: CGRect,
          firstPresentation: @escaping (MapGestureSurface) -> Void) {
        guard let pipeline = renderer.viewportPipeline, let baseTexture = base.texture, let detailTexture = detail.texture,
              renderer.labelPipeline != nil, detail.labels.isEmpty || detail.gestureLabels != nil,
              let parent = host.layer, let window = host.window, window.isVisible, !host.bounds.isEmpty else { return nil }
        self.renderer = renderer; self.pipeline = pipeline; self.firstPresentation = firstPresentation
        size = host.bounds.size; scale = window.backingScaleFactor
        smooth = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let rate = host.displayRefreshRate
        period = 1 / Double(rate)
        frame = Frame(base: baseTexture, detail: detailTexture, detailRect: detail.viewport, labels: detail.gestureLabels,
            from: viewport, to: viewport, changed: CACurrentMediaTime())
        super.init()
        metal.device = renderer.device; metal.pixelFormat = .bgra8Unorm
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.isOpaque = true; metal.framebufferOnly = true
        metal.frame = parent.bounds
        metal.contentsScale = window.backingScaleFactor
        metal.drawableSize = host.convertToBacking(host.bounds).size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        parent.insertSublayer(metal, at: 0)
        CATransaction.commit()
        let link = CAMetalDisplayLink(metalLayer: metal)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
        link.preferredFrameLatency = 1
        link.delegate = self
        MapDisplayThread.shared.perform { link.add(to: .current, forMode: .default) }
        invalidate = { MapDisplayThread.shared.perform { link.invalidate() } }
    }
    func update(base: RenderedFiles, detail: RenderedFiles, viewport: CGRect) {
        guard let baseTexture = base.texture, let detailTexture = detail.texture else { return }
        let useBacking = lock.withLock {
            frame.base = baseTexture; frame.detail = detailTexture; frame.detailRect = detail.viewport; frame.labels = detail.gestureLabels
            guard viewport != frame.to else { return false }
            let now = CACurrentMediaTime(), gap = now - frame.changed
            frame.from = frame.viewport(at: now); frame.to = viewport; frame.changed = now
            frame.duration = smooth && gap <= 0.04 ? min(3 * period, max(2 * period, gap)) : 0
            guard isDisplaying, let presented, now - presented.time > max(4 * period, 0.05) else { return false }
            awaitingPresentationSince = now
            return true
        }
        if useBacking { setDisplaying(false) }
    }
    func stop() {
        lock.withLock { active = false }
        invalidate?(); invalidate = nil
        metal.removeFromSuperlayer()
    }
    func select(_ highlight: MapGestureLabels.Highlight?) { lock.withLock { frame.highlight = highlight } }
    func setDisplaying(_ visible: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        metal.zPosition = visible ? 1 : 0; isDisplaying = visible
        CATransaction.commit()
    }
    deinit { invalidate?() }
}

@available(macOS 14.0, *)
extension MapGestureSurface: CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let frame = lock.withLock({ active ? self.frame : nil }) else { return }
        let viewport = frame.viewport(at: min(update.targetTimestamp, CACurrentMediaTime() + period / 2))
        guard viewport != lastViewport || lastDetail !== frame.detail || lastBase !== frame.base || frame.highlight != lastHighlight else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = update.drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        guard let command = renderer.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        func coordinates(in source: CGRect) -> SIMD4<Float> {
            SIMD4(Float((viewport.minX - source.minX) / source.width), Float((viewport.minY - source.minY) / source.height),
                Float(viewport.width / source.width), Float(viewport.height / source.height))
        }
        var rects = (coordinates(in: MapRenderSettings.whole), coordinates(in: frame.detailRect))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame.base, index: 0); encoder.setFragmentTexture(frame.detail, index: 1)
        encoder.setFragmentBytes(&rects, length: MemoryLayout.size(ofValue: rects), index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let glyphs = renderer.labelPipeline, frame.labels != nil || frame.highlight != nil {
            quads.removeAll(keepingCapacity: true)
            frame.labels?.place(in: viewport, size: size, quads: &quads)
            frame.highlight?.place(in: viewport, size: size, scale: scale, quads: &quads)
            encoder.setRenderPipelineState(glyphs)
            encoder.setFragmentTexture(frame.labels?.texture ?? frame.detail, index: 0)
            quads.withUnsafeBufferPointer { items in
                for offset in stride(from: 0, to: items.count, by: 64) {
                    let count = min(64, items.count - offset)
                    encoder.setVertexBytes(items.baseAddress! + offset, length: count * MemoryLayout<MapGestureLabels.Quad>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
                }
            }
        }
        encoder.endEncoding()
        let submittedAt = CACurrentMediaTime()
        update.drawable.addPresentedHandler { [weak self] drawable in
            guard let self, drawable.presentedTime > 0 else { return }
            let reveal = self.lock.withLock {
                guard self.active, drawable.presentedTime > (self.presented?.time ?? 0) else { return false }
                self.presented = (drawable.presentedTime, viewport)
                guard let since = self.awaitingPresentationSince, submittedAt >= since else { return false }
                self.awaitingPresentationSince = nil
                return true
            }
            if reveal {
                DispatchQueue.main.async { [weak self] in if let self { self.firstPresentation(self) } }
            }
        }
        command.commit()
        update.drawable.present()
        lastViewport = viewport; lastDetail = frame.detail; lastBase = frame.base; lastHighlight = frame.highlight
    }
}
