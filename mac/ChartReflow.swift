import AppKit
import MetalKit

struct ChartPatch {
    let from: SIMD4<Float>, to: SIMD4<Float>

    static func filling(_ gap: SIMD4<Float>, from prior: SIMD4<Float>, to target: SIMD4<Float>, radial: Bool) -> Self {
        guard gap.z > gap.x, gap.w > gap.y else { return Self(from: target, to: target) }
        let dx = (prior.x + prior.z - target.x - target.z) * 0.5
        let dy = (prior.y + prior.w - target.y - target.w) * 0.5
        let left = gap.x - target.z, right = gap.z - target.x
        let x = abs(left - dx) < abs(right - dx) ? left : right
        var shift = SIMD4(x, 0, x, 0)
        if !radial {
            let top = gap.y - target.w, bottom = gap.w - target.y
            let y = abs(top - dy) < abs(bottom - dy) ? top : bottom
            if y * (y - 2 * dy) < x * (x - 2 * dx) { shift = SIMD4(0, y, 0, y) }
        }
        return Self(from: target + shift, to: target)
    }
}

final class ChartReflow: MTKView {
    private let renderer: ChartRenderer, texture: MTLTexture, buffer: MTLBuffer
    private let patches: [ChartPatch]
    private let batches: [(offset: Int, count: Int, segments: Int)]
    private let radial: Bool
    private let sliding: Bool
    private let movingPatches: [ChartPatch]
    private let duration: CFTimeInterval
    private var began: CFTimeInterval = 0
    private var fraction: Float = 0
    var completed: (() -> Void)?

    init?(frame: CGRect, renderer: ChartRenderer, texture: MTLTexture, patches: [ChartPatch], radial: Bool, sliding: Bool = false, duration: CFTimeInterval = 0.36) {
        self.duration = duration
        self.sliding = sliding
        movingPatches = sliding ? patches.filter { $0.from != $0.to } : []
        guard !patches.isEmpty else { return nil }
        self.renderer = renderer; self.texture = texture; self.radial = radial
        if radial {
            let groups = Dictionary(grouping: patches) { patch -> Int in
                let span = max(patch.from.z - patch.from.x, patch.to.z - patch.to.x)
                if span <= 1 / 256 { return 1 }
                if span <= 1 / 32 { return 8 }
                if span <= 1 / 4 { return 64 }
                return 256
            }
            var ordered = [ChartPatch](), batches = [(Int, Int, Int)]()
            ordered.reserveCapacity(patches.count)
            for segments in groups.keys.sorted() {
                guard let group = groups[segments] else { continue }
                batches.append((ordered.count, group.count, segments))
                ordered.append(contentsOf: group)
            }
            self.patches = ordered; self.batches = batches
        } else {
            self.patches = patches; batches = [(0, patches.count, 1)]
        }
        guard let storage = self.patches.withUnsafeBytes({ bytes in
            renderer.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }) else { return nil }
        buffer = storage
        super.init(frame: frame, device: renderer.device)
        isPaused = true; enableSetNeedsDisplay = false; autoResizeDrawable = false
        drawableSize = CGSize(width: texture.width, height: texture.height)
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.isOpaque = false; clearColor = MTLClearColorMake(0, 0, 0, 0)
        setAccessibilityElement(false)
    }
    required init(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func start() {
        preferredFramesPerSecond = displayRefreshRate
        began = CACurrentMediaTime(); isPaused = false; draw()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, !self.isPaused else { return }
            self.isPaused = true; self.completed?()
        }
    }
    func cancel() {
        isPaused = true; completed = nil; removeFromSuperview()
    }
    func destination(x: CGFloat, y: CGFloat) -> CGPoint? {
        let x = Float(x), y = Float(y)
        if sliding {
            for patch in movingPatches where x >= patch.to.x && x < patch.to.z && y >= patch.to.y && y < patch.to.w {
                let u = x - (patch.from.x - patch.to.x) * (1 - fraction)
                let v = y - (patch.from.y - patch.to.y) * (1 - fraction)
                guard u >= patch.to.x, u < patch.to.z, v >= patch.to.y, v < patch.to.w else { return nil }
                return CGPoint(x: CGFloat(u), y: CGFloat(v))
            }
            return CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
        for patch in patches.reversed() {
            let box = patch.from + (patch.to - patch.from) * fraction
            guard x >= box.x, x < box.z, y >= box.y, y < box.w else { continue }
            let u = (x - box.x) / (box.z - box.x), v = (y - box.y) / (box.w - box.y)
            return CGPoint(x: CGFloat(patch.to.x + (patch.to.z - patch.to.x) * u),
                y: CGFloat(patch.to.y + (patch.to.w - patch.to.y) * v))
        }
        return nil
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !isPaused, began > 0 else { return }
        let t = min(1, (CACurrentMediaTime() - began) / duration)
        guard t < 1 else { isPaused = true; completed?(); return }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = renderer.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        fraction = Float(ChartMotion.easeOut(t))
        encoder.setRenderPipelineState(renderer.reflowPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        for batch in batches {
            var mode = SIMD4<Float>(fraction, Float(batch.segments), radial ? 1 : 0, sliding ? 1 : 0)
            encoder.setVertexBytes(&mode, length: MemoryLayout.size(ofValue: mode), index: 0)
            encoder.setVertexBuffer(buffer, offset: batch.offset * MemoryLayout<ChartPatch>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 2 * (batch.segments + 1), instanceCount: batch.count)
        }
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
}
