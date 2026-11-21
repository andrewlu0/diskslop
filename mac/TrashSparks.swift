import AppKit
import QuartzCore

struct SparkTexture {
    let head: CGImage, trail: CGImage
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let glow = profile(hot: false)
    fileprivate static let white = profile(hot: true)

    private static func bitmap(_ width: Int, _ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func profile(hot: Bool) -> (head: CGImage, trail: CGImage) {
        func stamp(trailing: Bool) -> CGImage {
            let width = trailing ? 96 : 64, height = 64
            let context = bitmap(width, height)
            let pixels = context.data!.assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let u = (Double(x)+0.5)/Double(width)
                let taper = 0.12 + 0.88*u*u*(3-2*u)
                let density = trailing ? pow(u, hot ? 3.5 : 0.78) : 1
                for y in 0..<height {
                    let v = abs(2*(Double(y)+0.5)/Double(height)-1)
                    let radius = trailing ? v/taper : hypot(2*u-1, v)
                    let shoulder = hot ? 0.64 : 0.73
                    let edge = min(1, max(0, (radius-shoulder)/(1-shoulder)))
                    let light = hot ? 1 : 0.62*exp(-4*radius*radius) + 0.38*exp(-1.5*radius*radius)
                    let alpha = UInt32((255 * density * light * (1-edge*edge*(3-2*edge))).rounded())
                    pixels[y*width+x] = alpha * 0x01010101
                }
            }
            return context.makeImage()!
        }
        return (stamp(trailing: false), stamp(trailing: true))
    }

    init(rgb: UInt32) {
        let tint = NSColor(rgb: rgb).cgColor
        func colored(_ mask: CGImage) -> CGImage {
            let context = Self.bitmap(mask.width, mask.height)
            let bounds = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
            context.draw(mask, in: bounds)
            context.setBlendMode(.sourceIn); context.setFillColor(tint); context.fill(bounds)
            return context.makeImage()!
        }
        head = colored(Self.glow.head); trail = colored(Self.glow.trail)
    }
}

struct TrashSpark {
    private enum Part { case ember, splitting(at: Double), dust(at: Double, side: CGFloat) }
    let origin: CGPoint, rgb: UInt32, diameter: CGFloat, drift: CGPoint
    let hold: Double, duration: Double
    private var part: Part = .ember

    static func scatter(in regions: ArraySlice<TrashGlassRegion>, toward target: CGPoint) -> [Self] {
        let weight = max(1, regions.reduce(CGFloat.zero) { $0 + sqrt($1.area) })
        let spare = 56 - 2 * regions.count
        var result: [Self] = []
        var primaryCount = 0
        result.reserveCapacity(84)
        for region in regions {
            let share = Int(CGFloat(spare) * sqrt(region.area) / weight)
            let count = min(2 + share, 2 + Int(sqrt(region.area) * 0.39))
            let size = region.shape.size
            let center = region.shape.point(CGPoint(x: 0.5, y: 0.5))
            let dx = target.x-center.x, dy = target.y-center.y
            let span = max(1, hypot(dx, dy)) * max(1, hypot(size.width, size.height))
            let columns = min(count, max(1, Int(sqrt(CGFloat(count) * size.width / max(0.5, size.height)).rounded())))
            let rows = (count + columns - 1)/columns
            for i in 0..<count {
                let row = i/columns, width = min(columns, count - row*columns)
                let uv = CGPoint(x: (CGFloat(i % columns) + .random(in: 0.06...0.94))/CGFloat(width),
                                 y: (CGFloat(row) + .random(in: 0.06...0.94))/CGFloat(rows))
                let p = region.shape.point(uv)
                let facing = ((p.x-center.x)*dx + (p.y-center.y)*dy)/span
                let delay = min(0.18, max(0.024, 0.10 - 0.14*facing + .random(in: -0.035...0.035)))
                var spark = Self(origin: p, rgb: region.colorAt(p), diameter: .random(in: 1.30...1.85),
                    drift: CGPoint(x: (uv.x-0.5)*19 + .random(in: -9...9), y: .random(in: -24 ... -5)),
                    hold: delay, duration: .random(in: 0.82...1.12))
                primaryCount += 1
                if primaryCount % 4 == 2 {
                    let split = delay + .random(in: 0.052...0.092)
                    spark.part = .splitting(at: split); result.append(spark)
                    for side in [CGFloat(-1), CGFloat(1)] {
                        spark.part = .dust(at: split, side: side); result.append(spark)
                    }
                } else { result.append(spark) }
            }
        }
        return result
    }

    func layer(to target: DockTrashTarget, texture: SparkTexture, shine: Bool, backingScale: CGFloat, refreshRate: Int) -> CALayer {
        let spark = CALayer()
        let halo = diameter * (shine ? 4.5 : 2.8)
        spark.bounds = CGRect(x: -halo/2, y: -halo/2, width: halo, height: halo)
        spark.position = origin; spark.opacity = 0
        let head = CALayer(), trail = CALayer(), hotHead = CALayer(), hotTrail = CALayer()
        head.bounds = spark.bounds; head.contents = texture.head
        // Preserve a white sample as the soft tip crosses between physical pixels.
        let tipTextureWidth = diameter + 1.5 / max(1, backingScale)
        hotHead.bounds = CGRect(x: 0, y: 0, width: tipTextureWidth, height: tipTextureWidth)
        hotHead.contents = SparkTexture.white.head
        let length: CGFloat = 48
        trail.bounds = CGRect(x: 0, y: 0, width: length, height: halo)
        trail.anchorPoint = CGPoint(x: 1, y: 0.5); trail.contents = texture.trail
        hotTrail.bounds = CGRect(x: 0, y: 0, width: length, height: tipTextureWidth)
        hotTrail.anchorPoint = trail.anchorPoint; hotTrail.position = CGPoint(x: length, y: halo/2)
        hotTrail.contents = SparkTexture.white.trail
        hotHead.opacity = 0; hotTrail.opacity = 0
        trail.addSublayer(hotTrail); head.addSublayer(hotHead)
        spark.addSublayer(trail); spark.addSublayer(head)

        let end = target.point, loose = CGPoint(x: origin.x + drift.x, y: origin.y + drift.y)
        let fall = min(86, max(21, hypot(origin.x - end.x, origin.y - end.y)*0.16))
        let release = hold + 0.18, initialSlope = 0.72
        // Match the falling velocity on both sides of the Bézier join.
        let tangent = 2 * (1-release) / (3 * initialSlope * (release-hold))
        let first = CGPoint(x: loose.x + drift.x*tangent, y: loose.y + drift.y*tangent)
        let last = target.edge.approach(to: end, by: fall)
        let steps = 40
        let points = (0...steps).map { i -> CGPoint in
            let t = Double(i)/Double(steps)
            if case let .dust(at, side) = part, t >= at {
                let f = (at-hold)/(release-hold)
                let span = side < 0 ? 0.25 : 0.31
                let u = min(1, (t-at)/span), fan = u*u*(3-2*u)
                let advance = f*f + (2*f/(release-hold))*span*u*(1-0.5*u)
                let spread = side * (11 + abs(drift.x)*0.4) / max(1, hypot(drift.x, drift.y))
                return CGPoint(x: origin.x + drift.x*advance - drift.y*spread*fan,
                               y: origin.y + drift.y*advance + drift.x*spread*fan - 9*u*u)
            }
            if t <= release {
                let f = max(0, (t - hold)/(release - hold))
                return CGPoint(x: origin.x + drift.x*f*f, y: origin.y + drift.y*f*f)
            }
            let f = (t-release)/(1-release)
            let u = f * (initialSlope + f * (3 - 2*initialSlope + f*(initialSlope-2))), v = 1-u
            let a = v*v*v, b = 3*v*v*u, c = 3*v*u*u, d = u*u*u
            return CGPoint(x: a*loose.x + b*first.x + c*last.x + d*end.x,
                           y: a*loose.y + b*first.y + c*last.y + d*end.y)
        }
        let streaks = (0...steps).map { i -> NSValue in
            let before = max(0, i-1), after = min(steps, i+1)
            let dx = points[after].x - points[before].x, dy = points[after].y - points[before].y
            let velocity = hypot(dx, dy) * CGFloat(steps) / (CGFloat(after-before) * duration)
            let playbackSpeed = 3 * pow(1 - CGFloat(i) / CGFloat(steps), 2.0 / 3.0)
            let exposure = min(49, max(0.12, velocity * playbackSpeed * 0.029))
            let rotation = CATransform3DMakeRotation(atan2(dy, dx), 0, 0, 1)
            return NSValue(caTransform3D: CATransform3DScale(rotation, exposure/length, 1, 1))
        }
        func animation(_ key: String, _ values: [Any], at times: [Double]? = nil) -> CAKeyframeAnimation {
            let effect = CAKeyframeAnimation(keyPath: key)
            effect.values = values; effect.keyTimes = times?.map { NSNumber(value: $0) }; effect.duration = duration
            effect.timingFunction = ChartMotion.timingFunction
            return effect
        }
        let flight = CAAnimationGroup()
        flight.preferredFrameRateRange = chartFrameRate(refreshRate)
        flight.duration = duration
        let times: [Double], scales: [Double], opacity: [Double], name: String
        switch part {
        case .ember:
            times = [0, hold, hold+0.07, release, 0.54, 0.74, 0.91, 1]
            scales = [0.75, 0.75, 0.67, 0.59, 0.48, 0.30, 0.12, 0.02]
            opacity = [0.08, 0.72, 1, 1, 0.97, 0.73, 0.32, 0]; name = "toTrash"
        case .splitting(let at):
            times = [0, hold, at, at+0.048, at+0.115, 1]
            scales = [0.75, 0.75, 0.64, 0.36, 0.015, 0.015]
            opacity = [0.08, 0.72, 1, 0.65, 0, 0]; name = "breakup"
        case .dust(let at, let side):
            let span = side < 0 ? 0.25 : 0.31
            times = [0, at, at+0.033, at+0.095, at+0.72*span, at+span, 1]
            scales = [0.57, 0.57, 0.54, 0.44, 0.25, 0.015, 0.015]
            opacity = [0, 0, 0.99, 0.93, 0.47, 0, 0]; name = "dust"
        }
        let heat = animation("opacity", [0, 0.22, 0.91, 1, 1], at: [0, hold, hold+0.045, hold+0.085, 1])
        flight.animations = [animation("position", points.map { NSValue(point: $0) }),
                             animation("transform.scale", scales, at: times), animation("opacity", opacity, at: times)]
        spark.add(flight, forKey: name)
        hotHead.add(heat, forKey: "heat"); hotTrail.add(heat, forKey: "heat")
        trail.add(animation("transform", streaks), forKey: "motionBlur")
        return spark
    }
}
