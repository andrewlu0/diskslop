import AppKit
import MetalKit

final class ChartRenderer {
    static let shared = ChartRenderer()
    let reflowPipeline: MTLRenderPipelineState
    let device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "triangle")
        descriptor.fragmentFunction = library.makeFunction(name: "zoom")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        descriptor.vertexFunction = library.makeFunction(name: "reflow")
        descriptor.fragmentFunction = library.makeFunction(name: "surface")
        guard let reflowPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.reflowPipeline = reflowPipeline
        self.device = device; self.queue = queue; self.pipeline = pipeline
    }

    func snapshot(width: Int, height: Int, draw: (CGContext) -> Void) -> MTLTexture? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: info), let data = context.data else { return nil }
        draw(context)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: context.bytesPerRow)
        return texture
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex triangle(uint i [[vertex_id]]) {
        float2 uv = float2((i << 1) & 2, i & 2);
        return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv};
    }
    float2 polar(float angle, float radius) {
        float radians = angle * 6.28318530718f;
        return 0.5f + 0.5f * radius * float2(sin(radians), -cos(radians));
    }
    struct Patch { float4 from, to; };
    vertex Vertex reflow(uint corner [[vertex_id]], uint instance [[instance_id]],
                         constant float4 &mode [[buffer(0)]], device const Patch *patches [[buffer(1)]]) {
        Patch p = patches[instance];
        float4 box = mix(p.from, p.to, mode.x);
        float2 edge = float2(float(corner / 2) / mode.y, float(corner % 2));
        float2 xy = mix(box.xy, box.zw, edge), uv = mix(p.to.xy, p.to.zw, edge);
        if (mode.z > 0) { xy = polar(xy.x, xy.y); uv = polar(uv.x, uv.y); }
        return {float4(2 * xy.x - 1, 1 - 2 * xy.y, 0, 1), uv};
    }
    fragment half4 surface(Vertex v [[stage_in]], texture2d<half> target [[texture(0)]]) {
        constexpr sampler sample(coord::normalized, address::clamp_to_edge, filter::linear);
        return target.sample(sample, v.uv);
    }
    fragment half4 zoom(Vertex v [[stage_in]], texture2d<half> parent [[texture(0)]],
                        texture2d<half> child [[texture(1)]], constant float4 &lens [[buffer(0)]],
                        constant float2 *stops [[buffer(1)]], constant uint &count [[buffer(2)]]) {
        constexpr sampler sample(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 xy = 2 * v.uv - 1;
        float radius = length(xy), hub = lens.z, t = lens.w;
        if (t <= 0) return parent.sample(sample, v.uv);
        if (t >= 1) return child.sample(sample, v.uv);
        float fade = smoothstep(0.12f, 0.88f, t);
        if (radius <= hub || radius >= 1)
            return mix(parent.sample(sample, v.uv), child.sample(sample, v.uv), half(fade));
        float angle = fract(atan2(xy.x, -xy.y) / 6.28318530718f + 1);
        float width = lens.y - lens.x, span = pow(width, t);
        float start = width < 0.999999f ? lens.x * (1 - span) / (1 - width) : t * lens.x;
        float a = start + angle * span, b = (a - lens.x) / width;
        float r = (radius - hub) / (1 - hub);
        float2 lo = stops[0], hi = lo;
        for (uint i = 1; i < count; ++i) {
            hi = stops[i];
            if (r <= mix(hi.x, hi.y, t) || i + 1 == count) break;
            lo = hi;
        }
        float f = saturate((r - mix(lo.x, lo.y, t)) / max(0.000001f, mix(hi.x-lo.x, hi.y-lo.y, t)));
        float2 radii = hub + (1 - hub) * mix(lo, hi, f);
        half4 p = parent.sample(sample, polar(a, radii.x));
        if (b < 0 || b > 1 || hi.y <= lo.y) return p;
        half4 c = child.sample(sample, polar(b, radii.y));
        return hi.x <= lo.x ? c : mix(p, c, half(fade));
    }
    """
}

final class SunburstZoomView: MTKView {
    let parentID: UInt32, childID: UInt32
    private let renderer: ChartRenderer
    private let parent: MTLTexture, child: MTLTexture
    private let stops: [SIMD2<Float>]
    private var lens: SIMD4<Float>
    private var from: Double, to: Double, began: CFTimeInterval = 0
    var completed: (() -> Void)?

    init(frame: CGRect, renderer: ChartRenderer, parent: MTLTexture, child: MTLTexture,
         parentID: UInt32, childID: UInt32, parentStops: [CGFloat], childStops: [CGFloat],
         anchor: Sector, level: Int, hub: CGFloat, inward: Bool) {
        self.renderer = renderer; self.parent = parent; self.child = child
        self.parentID = parentID; self.childID = childID
        let offset = level + 1
        stops = (0..<max(parentStops.count, offset + childStops.count)).map { index in
            SIMD2(Float(parentStops[min(index, parentStops.count - 1)]),
                Float(childStops[min(max(0, index - offset), childStops.count - 1)]))
        }
        lens = SIMD4(Float(anchor.start), Float(anchor.end), Float(hub), inward ? 0 : 1)
        from = inward ? 0 : 1; to = 1 - from
        super.init(frame: frame, device: renderer.device)
        isPaused = true; enableSetNeedsDisplay = false
        colorPixelFormat = .bgra8Unorm
        autoResizeDrawable = false
        drawableSize = CGSize(width: parent.width, height: parent.height)
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.isOpaque = false
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        setAccessibilityElement(false)
    }
    required init(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func beginLeg() {
        began = CACurrentMediaTime()
        let start = began
        DispatchQueue.main.asyncAfter(deadline: .now() + legDuration) { [weak self] in
            guard let self, self.began == start, !self.isPaused else { return }
            self.isPaused = true; self.completed?()
        }
    }
    private var legDuration: Double { max(0.08, 0.32 * abs(to - from)) }
    func start() {
        preferredFramesPerSecond = min(120, window?.screen?.maximumFramesPerSecond ?? 60)
        beginLeg()
        isPaused = false
        draw()
    }
    func reverse(towardChild: Bool) {
        let destination: Double = towardChild ? 1 : 0
        guard to != destination else { return }
        from = Double(lens.w); to = destination; beginLeg()
    }
    func destination(angle: CGFloat, depth: CGFloat) -> (CGFloat, CGFloat)? {
        let t = lens.w, width = lens.y - lens.x, span = pow(width, t)
        let start = width < 0.999999 ? lens.x * (1 - span) / (1 - width) : t * lens.x
        let parentAngle = start + Float(angle) * span
        let entering = to == 1
        let targetAngle = entering ? (parentAngle - lens.x) / width : parentAngle
        guard targetAngle >= 0, targetAngle < 1 else { return nil }
        let r = Float(depth)
        for (a, b) in zip(stops, stops.dropFirst()) {
            let lo = a.x + (a.y - a.x) * t, hi = b.x + (b.y - b.x) * t
            guard r < hi, hi > lo else { continue }
            let channel = entering ? 1 : 0
            guard b[channel] > a[channel] else { return nil }
            let mapped = a[channel] + (b[channel] - a[channel]) * (r - lo) / (hi - lo)
            return (CGFloat(targetAngle), CGFloat(mapped))
        }
        return nil
    }
    override func draw(_ dirtyRect: NSRect) {
        guard began > 0, !isPaused else { return }
        let time = min(1, (CACurrentMediaTime() - began) / legDuration)
        guard time < 1, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = renderer.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { isPaused = true; completed?(); return }
        let ease = ChartMotion.easeOut(time)
        lens.w = Float(from + (to - from) * ease)
        encoder.setRenderPipelineState(renderer.pipeline)
        encoder.setFragmentTexture(parent, index: 0); encoder.setFragmentTexture(child, index: 1)
        encoder.setFragmentBytes(&lens, length: MemoryLayout.size(ofValue: lens), index: 0)
        stops.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        var count = UInt32(stops.count)
        encoder.setFragmentBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
}
