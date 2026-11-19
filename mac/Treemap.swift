import AppKit

private class FlippedCanvas: NSView {
    override var isFlipped: Bool { true }
}
private final class MapOverlay: FlippedCanvas {
    weak var map: Treemap?
    override func draw(_ dirtyRect: NSRect) { map?.drawOverlay(dirtyRect) }
}

final class Treemap: NSView {
    var choose: (([[DiskItem]], SelectionMode) -> Void)?
    var menuForRoute: (([DiskItem]) -> NSMenu?)?
    var zoomChanged: (() -> Void)?
    private var geometry: FileMap?
    private var rendered: RenderedFiles?
    private var revision = 0, drawing = false
    private var reflow: DispatchWorkItem?
    private var lastSize: NSSize = .zero, lastScale: CGFloat = 0
    private static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    private(set) var viewport = whole
    var zoom: CGFloat { 1 / viewport.width }
    var aspect: CGFloat { bounds.width > 1 && bounds.height > 1 ? bounds.width / bounds.height : 1.4 }
    private var down: NSPoint?, marquee: NSRect?, panOrigin: NSRect?
    private var rootKeys = Set<UInt64>()
    private var marked: [CGRect] = []
    private var selectedBounds: CGRect?
    var selection = Set<UInt64>() { didSet { if selection != oldValue { updateSelection() } } }
    private let overlay = MapOverlay(), glassHost = FlippedCanvas()
    private var glassLayer: NSView?, glassTiles: [NSView] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectContainerView()
            glass.spacing = 0
            glass.contentView = glassHost
            glass.frame = bounds; glass.autoresizingMask = [.width, .height]
            addSubview(glass)
            glassLayer = glass
        }
        overlay.map = self
        overlay.frame = bounds; overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Disk usage treemap")
        setAccessibilityHelp("Select a file to reveal its size in the outline. Command-scroll or pinch to zoom.")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func accessibilityChanged() { updateGlass(); overlay.needsDisplay = true }

    func show(_ listing: FolderListing, ancestors: Set<UInt64>) {
        reflow?.cancel()
        geometry = listing.geometry
        rootKeys = ancestors
        viewport = Self.whole
        rendered = nil; down = nil; marquee = nil; panOrigin = nil
        updateSelection()
        revision += 1
        updateGlass()
        needsDisplay = true; overlay.needsDisplay = true
        setAccessibilityValue("Preparing file map")
        scheduleFrame()
        scheduleReflow()
        zoomChanged?()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        guard lastSize != bounds.size || scale != lastScale else { return }
        lastSize = bounds.size; lastScale = scale
        revision += 1
        scheduleFrame()
        updateGlass()
        scheduleReflow()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
    private func scheduleReflow() {
        reflow?.cancel()
        guard let current = geometry, abs(log(aspect / current.aspect)) > 0.2, viewport == Self.whole else { return }
        let target = aspect
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.geometry === current, self.viewport == Self.whole else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let new = FileMap(model: current.model, folder: current.folder, aspect: target)
                DispatchQueue.main.async {
                    guard self.geometry === current, self.viewport == Self.whole, abs(log(self.aspect / target)) < 0.2 else { return }
                    self.geometry = new
                    self.updateSelection()
                    self.revision += 1; self.scheduleFrame()
                }
            }
        }
        reflow = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private func scheduleFrame() {
        guard !drawing, let current = geometry, bounds.width >= 1, bounds.height >= 1 else { return }
        let scale = min(window?.backingScaleFactor ?? 2, sqrt(24_000_000 / (bounds.width * bounds.height)))
        let w = max(1, Int((bounds.width * scale).rounded())), h = max(1, Int((bounds.height * scale).rounded()))
        let port = viewport, token = revision
        drawing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let frame = current.render(viewport: port, width: w, height: h, scale: scale)
            DispatchQueue.main.async {
                self.drawing = false
                if self.geometry === current, let frame {
                    self.rendered = frame
                    self.needsDisplay = true; self.overlay.needsDisplay = true
                    self.updateGlass()
                    self.setAccessibilityValue("\(current.count.formatted()) file shapes · \(Int(self.zoom.rounded()))×")
                }
                if self.revision != token { self.scheduleFrame() }
            }
        }
    }
    private func world(_ point: CGPoint) -> CGPoint {
        CGPoint(x: viewport.minX + point.x * viewport.width / max(1, bounds.width),
                y: viewport.minY + point.y * viewport.height / max(1, bounds.height))
    }
    private func screen(_ r: CGRect) -> CGRect {
        let sx = bounds.width / viewport.width, sy = bounds.height / viewport.height
        return CGRect(x: (r.minX - viewport.minX) * sx, y: (r.minY - viewport.minY) * sy, width: r.width * sx, height: r.height * sy)
    }
    private func world(_ rect: CGRect) -> CGRect {
        let a = world(rect.origin), b = world(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
    private func move(to rect: CGRect) {
        let size = min(1, max(1 / CGFloat(1 << 30), rect.width))
        let next = CGRect(x: min(max(0,rect.minX),1 - size), y: min(max(0,rect.minY),1 - size), width: size, height: size)
        guard next != viewport else { return }
        viewport = next; revision += 1
        needsDisplay = true; overlay.needsDisplay = true
        updateGlass(); scheduleFrame(); zoomChanged?()
        if next == Self.whole { scheduleReflow() }
    }
    private func magnify(by factor: CGFloat, around anchor: CGPoint) {
        guard geometry != nil, bounds.width > 0, bounds.height > 0 else { return }
        let at = world(anchor), span = min(1, max(1 / CGFloat(1 << 30), viewport.width / factor))
        move(to: CGRect(x: at.x - (anchor.x / bounds.width) * span, y: at.y - (anchor.y / bounds.height) * span, width: span, height: span))
    }
    func stepZoom(inward: Bool) {
        var anchor = CGPoint(x: bounds.midX, y: bounds.midY)
        if inward, let r = selectedBounds {
            let center = CGPoint(x: r.midX, y: r.midY)
            if viewport.contains(center) { anchor = CGPoint(x: screen(r).midX, y: screen(r).midY) }
            else {
                let span = viewport.width / 1.7
                move(to: CGRect(x: center.x - span / 2, y: center.y - span / 2, width: span, height: span))
                return
            }
        }
        magnify(by: inward ? 1.7 : 1 / 1.7, around: anchor)
    }
    func fitMap() { move(to: Self.whole) }
    func fitSelection() {
        guard let r = selectedBounds else { return }
        let span = max(r.width, r.height) * 1.2
        move(to: CGRect(x: r.midX - span / 2, y: r.midY - span / 2, width: span, height: span))
    }
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if event.modifierFlags.contains(.command) {
            let gain: CGFloat = event.hasPreciseScrollingDeltas ? 0.013 : 0.17
            magnify(by: exp(min(1.5, max(-1.5, dy * gain))), around: convert(event.locationInWindow, from: nil))
        } else if zoom > 1 {
            let gain: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 15
            move(to: viewport.offsetBy(dx: -dx * gain * viewport.width / bounds.width, dy: -dy * gain * viewport.height / bounds.height))
        } else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) { magnify(by: max(0.1, 1 + event.magnification), around: convert(event.locationInWindow, from: nil)) }
    override func smartMagnify(with event: NSEvent) {
        if zoom > 1 { fitMap() } else { magnify(by: 3, around: convert(event.locationInWindow, from: nil)) }
    }

    private func updateSelection() {
        if !rootKeys.isDisjoint(with: selection) { marked = [Self.whole] }
        else { marked = selection.compactMap { geometry?.bounds(of: $0) } }
        selectedBounds = marked.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
        overlay.needsDisplay = true
    }
    private func updateGlass() {
        guard #available(macOS 26.0, *), let glassLayer else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        glassLayer.isHidden = reduce
        guard !reduce else { return }
        var count = 0
        for label in rendered?.labels ?? [] {
            let projected = screen(label.rect), r = projected.intersection(bounds)
            guard count < 12, r.width >= 66, r.height >= 36, abs(r.width - projected.width) < 1,
                  abs(r.height - projected.height) < 1 else { continue }
            let tile: NSGlassEffectView
            if count < glassTiles.count { tile = glassTiles[count] as! NSGlassEffectView }
            else {
                tile = NSGlassEffectView(); tile.style = .clear; tile.cornerRadius = 0
                glassHost.addSubview(tile); glassTiles.append(tile)
            }
            let c = label.rgb
            tile.tintColor = NSColor(srgbRed: CGFloat(c >> 16) / 255, green: CGFloat((c >> 8) & 255) / 255,
                                     blue: CGFloat(c & 255) / 255, alpha: 0.28)
            tile.frame = r; tile.isHidden = false; count += 1
        }
        for tile in glassTiles.dropFirst(count) { tile.isHidden = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        guard let view = rendered, geometry?.count != 0, let cg = NSGraphicsContext.current?.cgContext else { return }
        let area = screen(view.viewport)
        cg.saveGState()
        cg.translateBy(x: area.minX, y: area.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .none
        cg.draw(view.image, in: CGRect(origin: .zero, size: area.size))
        cg.restoreGState()
    }
    fileprivate func drawOverlay(_ dirty: NSRect) {
        if rendered == nil || geometry?.count == 0 {
            let title = geometry?.count == 0 ? "No files in this folder" : "Drawing file map…"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
            return
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
        for label in rendered?.labels ?? [] {
            let r = screen(label.rect).intersection(bounds)
            guard r.intersects(dirty), r.width >= 44, r.height >= 21 else { continue }
            let large = r.width >= 150 && r.height >= 74
            let inset: CGFloat = large ? 9 : 4
            let box = CGRect(x: r.minX + inset, y: r.minY + inset, width: r.width - 2 * inset, height: large ? 23 : 16)
            (label.title as NSString).draw(in: box, withAttributes: [.font: NSFont.systemFont(ofSize: large ? 16 : 11, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para])
            if r.height > 39 {
                (label.size as NSString).draw(in: box.offsetBy(dx: 0, dy: large ? 22 : 15), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: large ? 12 : 10, weight: .regular), .foregroundColor: NSColor.white, .paragraphStyle: para])
            }
        }
        if !marked.isEmpty, let cg = NSGraphicsContext.current?.cgContext {
            let regions = marked.filter { $0.intersects(viewport) }.map { screen($0) }
            cg.saveGState()
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setFillColor(NSColor.black.withAlphaComponent(0.43).cgColor)
            cg.fill(dirty)
            cg.setBlendMode(.clear)
            for r in regions { cg.fill(r.intersection(bounds)) }
            cg.endTransparencyLayer(); cg.restoreGState()
            for r in regions {
                if r.width < 4 || r.height < 4 {
                    NSColor.white.setFill(); CGRect(x: r.midX - 2, y: r.midY - 2, width: 4, height: 4).fill()
                } else {
                    let path = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
                    NSColor.white.withAlphaComponent(0.95).setStroke(); path.lineWidth = 2; path.stroke()
                }
            }
        }
        if let marquee {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.20).setFill(); marquee.fill()
            NSColor.white.setStroke(); NSBezierPath(rect: marquee).stroke()
        }
    }
    private func route(at event: NSEvent) -> [DiskItem]? {
        guard let g = geometry, let key = g.hit(world(convert(event.locationInWindow, from: nil))) else { return nil }
        return g.model.route(to: key, from: g.folder)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !event.modifierFlags.contains(.control), let file = route(at: event) else { return nil }
        return menuForRoute?(file)
    }
    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let file = route(at: event) { choose?([file], .toggle) }
        } else if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func mouseDown(with event: NSEvent) {
        down = convert(event.locationInWindow, from: nil)
        panOrigin = event.modifierFlags.contains(.option) && zoom > 1 ? viewport : nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let origin = panOrigin {
            move(to: origin.offsetBy(dx: (down.x - p.x) * origin.width / bounds.width, dy: (down.y - p.y) * origin.height / bounds.height))
            return
        }
        let rect = CGRect(x: min(down.x,p.x), y: min(down.y,p.y), width: abs(down.x - p.x), height: abs(down.y - p.y))
        guard marquee != nil || max(rect.width,rect.height) > 3 else { return }
        marquee = rect; overlay.needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        down = nil
        if panOrigin != nil { panOrigin = nil; return }
        let mode = SelectionMode(event.modifierFlags)
        if let rect = marquee, let g = geometry {
            marquee = nil; overlay.needsDisplay = true
            let keys = g.keys(in: world(rect.intersection(bounds)))
            choose?(g.routes(keys), mode == .replace ? .replace : mode == .toggle ? .toggle : .add)
        } else if let path = route(at: event) {
            choose?([path],mode)
            if event.clickCount == 2 && mode == .replace { fitSelection() }
        }
    }
}
