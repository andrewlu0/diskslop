import AppKit
import QuartzCore

enum TrashGlassShape {
    case tile(CGRect)
    case wedge(center: CGPoint, inner: CGFloat, outer: CGFloat, start: CGFloat, sweep: CGFloat)

    var size: CGSize {
        switch self {
        case .tile(let rect): return rect.size
        case let .wedge(_, inner, outer, _, sweep):
            return CGSize(width: sweep * (outer + inner)/2, height: outer - inner)
        }
    }

    func point(_ uv: CGPoint) -> CGPoint {
        switch self {
        case .tile(let r): return CGPoint(x: r.minX + uv.x * r.width, y: r.minY + uv.y * r.height)
        case let .wedge(center, inner, outer, start, sweep):
            let angle = start - sweep * uv.x, radius = inner + (outer - inner) * uv.y
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }

    var outline: CGPath {
        switch self {
        case .tile(let rect): return CGPath(rect: rect, transform: nil)
        case let .wedge(center, inner, outer, start, sweep):
            let path = CGMutablePath()
            path.addArc(center: center, radius: outer, startAngle: start, endAngle: start - sweep, clockwise: true)
            path.addArc(center: center, radius: inner, startAngle: start - sweep, endAngle: start, clockwise: false)
            path.closeSubpath()
            return path
        }
    }
}

struct TrashGlassRegion {
    let shape: TrashGlassShape
    let colorAt: (CGPoint) -> UInt32
    var area: CGFloat { shape.size.width * shape.size.height }
}

private final class FlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class TrashGlass {
    static let regionLimit = 24
    let dock = DockTrashLocator()
    private var panels: [NSPanel] = []
    private var clearance: DispatchWorkItem?
    private var flight = UUID()

    func play(_ regions: [TrashGlassRegion], from view: NSView) {
        guard !regions.isEmpty, let window = view.window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !view.isHiddenOrHasHiddenAncestor,
              NSApp.isActive, let screen = window.screen else { return }
        clearPanels()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shine = !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let footprints = regions.prefix(Self.regionLimit)
        let path = CGMutablePath()
        for region in footprints { path.addPath(region.shape.outline) }
        let target = reduced ? nil : dock.target(from: screen)
        let id = UUID(), windowFrame = window.frame
        flight = id
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view, weak window] in
            let sparks = target.map { TrashSpark.scatter(in: footprints, toward: $0.point) } ?? []
            let textures = Dictionary(uniqueKeysWithValues: Set(sparks.map(\.rgb)).map { ($0, SparkTexture(rgb: $0)) })
            DispatchQueue.main.async { [weak self, weak view, weak window] in
                guard let self, self.flight == id, let view, let window, view.window === window,
                      window.isVisible, window.frame == windowFrame, !view.isHiddenOrHasHiddenAncestor, NSApp.isActive else { return }
                self.present(footprints, path: path, target: target, sparks: sparks, textures: textures, reduced: reduced, shine: shine)
            }
        }
    }

    private func present(_ footprints: ArraySlice<TrashGlassRegion>, path: CGPath, target: DockTrashTarget?,
                         sparks: [TrashSpark], textures: [UInt32: SparkTexture], reduced: Bool, shine: Bool) {
        var extent = path.boundingBoxOfPath
        if let target {
            extent = extent.union(CGRect(origin: target.point, size: CGSize(width: 1, height: 1))).insetBy(dx: -65, dy: -110)
        } else { extent = extent.insetBy(dx: -5, dy: -5) }
        let rims = footprints.map { region in
            (region.shape.outline, NSColor(rgb: region.colorAt(region.shape.point(CGPoint(x: 0.5, y: 0.5)))))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for display in NSScreen.screens {
            let frame = extent.integral.intersection(display.frame)
            guard !frame.isEmpty else { continue }
            let panel = FlightPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Trash animation"
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = true
            panel.animationBehavior = .none; panel.level = .floating
            panel.isExcludedFromWindowsMenu = true; panel.isRestorable = false
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
            panel.setAccessibilityElement(false)
            let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
            view.layer = CALayer(); view.wantsLayer = true; view.setAccessibilityElement(false)
            panel.contentView = view
            let stage = CALayer()
            stage.anchorPoint = .zero; stage.bounds = CGRect(origin: .zero, size: frame.size)
            stage.position = CGPoint(x: -frame.minX, y: -frame.minY)
            view.layer!.addSublayer(stage)
            for (outline, tint) in rims {
                let rim = CAShapeLayer()
                let bounds = outline.boundingBoxOfPath
                rim.bounds = bounds; rim.position = CGPoint(x: bounds.midX, y: bounds.midY)
                rim.path = outline; rim.fillColor = tint.withAlphaComponent(reduced ? 0.38 : 0.78).cgColor
                rim.strokeColor = tint.blended(withFraction: 0.26, of: .white)?.cgColor; rim.lineWidth = 1 / display.backingScaleFactor
                if shine && !reduced {
                    rim.shadowPath = outline; rim.shadowColor = tint.cgColor; rim.shadowOffset = .zero
                    rim.shadowRadius = 4; rim.shadowOpacity = 0.6
                }
                rim.opacity = 0
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.keyTimes = [0, 0.28, 1]; pulse.values = reduced ? [0.8, 0.55, 0] : [0.87, 0.96, 0]
                pulse.preferredFrameRateRange = chartFrameRate(display.maximumFramesPerSecond)
                pulse.timingFunction = ChartMotion.timingFunction
                pulse.duration = reduced ? 0.24 : 0.31
                stage.addSublayer(rim); rim.add(pulse, forKey: "glow")
            }
            if let target {
                for spark in sparks {
                    guard let texture = textures[spark.rgb] else { continue }
                    stage.addSublayer(spark.layer(to: target, texture: texture, shine: shine, backingScale: display.backingScaleFactor, refreshRate: display.maximumFramesPerSecond))
                }
            }
            panel.setFrame(frame, display: false)
            panel.orderFront(nil); panels.append(panel)
        }
        CATransaction.commit()
        let done = DispatchWorkItem { [weak self] in self?.clearPanels() }
        clearance = done
        let duration = sparks.map(\.duration).max() ?? 0.24
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05, execute: done)
    }

    private func clearPanels() {
        clearance?.cancel(); clearance = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
    }
}
