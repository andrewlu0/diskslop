import AppKit

private class FlippedCanvas: NSView {
    override var isFlipped: Bool { true }
}
private final class MapOverlay: FlippedCanvas {
    weak var map: Treemap?
    override func draw(_ dirtyRect: NSRect) { map?.drawOverlay(dirtyRect) }
}

private final class MapSelectionOverlay: FlippedCanvas {
    weak var map: Treemap?
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        map?.drawSelection(in: context)
    }
}

struct MapRenderSettings: Equatable {
    let viewport: CGRect, width: Int, height: Int, scale: CGFloat, dark: Bool, shine: Bool
    var focus: LegendFocus?
    static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    func overview(_ geometry: FileMap, colors: MapBreakdown?) -> CGImage? {
        let ratio = min(1, 1024 / CGFloat(max(width, height)))
        return geometry.render(viewport: Self.whole, width: max(1, Int(CGFloat(width) * ratio)),
            height: max(1, Int(CGFloat(height) * ratio)), scale: scale * ratio,
            dark: dark, shine: shine, coloring: colors, focus: focus)?.image
    }

    func render(_ geometry: FileMap, colors: MapBreakdown?) -> RenderedFiles? {
        geometry.render(viewport: viewport, width: width, height: height, scale: scale, dark: dark, shine: shine, coloring: colors, focus: focus)
    }
}

struct MovingTile {
    let key: UInt64, from: CGRect, to: CGRect, image: CGImage
    func rect(at t: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * t, y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t, height: from.height + (to.height - from.height) * t)
    }
}

struct LiveMapFrame {
    let raster: RenderedFiles, moves: [MovingTile], priorImage: CGImage?
    let overview: CGImage?
    let trashPatches: [ChartPatch]
    init(_ raster: RenderedFiles, geometry: FileMap, settings: MapRenderSettings, colors: MapBreakdown?, source: (FileMap, RenderedFiles)?, afterTrash: Bool = false) {
        self.raster = raster
        overview = raster.viewport == MapRenderSettings.whole ? raster.image : settings.overview(geometry, colors: colors)
        guard let (previous, prior) = source, prior.viewport == raster.viewport else {
            moves = []; priorImage = nil; trashPatches = []; return
        }
        priorImage = prior.image
        if afterTrash {
            trashPatches = geometry.reflow(from: previous, in: settings)
            moves = []
            return
        }
        trashPatches = []
        let before = previous.motionTiles(in: prior)
        let after = geometry.motionTiles(in: raster)
        let port = raster.viewport
        let sx = CGFloat(raster.image.width) / port.width, sy = CGFloat(raster.image.height) / port.height
        moves = after.compactMap { name, tile in
            guard let from = before[name]?.rect, port.contains(from), port.contains(tile.rect) else { return nil }
            let to = tile.rect
            let delta = max(abs(from.minX-to.minX)*sx, abs(from.maxX-to.maxX)*sx, abs(from.minY-to.minY)*sy, abs(from.maxY-to.maxY)*sy)
            guard delta >= 0.7 * settings.scale else { return nil }
            let crop = CGRect(x: (to.minX-port.minX)*sx, y: (to.minY-port.minY)*sy, width: to.width*sx, height: to.height*sy)
            guard let image = raster.image.cropping(to: crop) else { return nil }
            return MovingTile(key: tile.key, from: from, to: to, image: image)
        }
    }
}

final class Treemap: NSView, NSViewToolTipOwner {
    var choose: (([[DiskItem]], SelectionMode) -> Void)?
    var menuForRoute: (([DiskItem]) -> NSMenu?)?
    var zoomChanged: (() -> Void)?
    var hovered: ((URL?, UInt32?) -> Void)?
    var coloringDidDisplay: ((MapBreakdown?) -> Void)?
    private(set) var displayedColors: MapBreakdown?
    var legendFocus: LegendFocus? {
        didSet {
            guard legendFocus != oldValue else { return }
            endMotion(); overviewIsCurrent = false; revision += 1; scheduleFrame()
        }
    }
    private var requestedColors: MapBreakdown?
    private var geometry: FileMap?
    private var rendered: RenderedFiles? {
        didSet { selectionOverlay.needsDisplay = true }
    }
    private var overview: CGImage?
    private var overviewIsCurrent = false
    private var movingTiles: [MovingTile] = []
    private let motion = ChartMotion()
    private var trashTransition: ChartReflow? {
        didSet { selectionOverlay.isHidden = trashTransition != nil }
    }
    private var renderer: ChartRenderer?
    private let tileSheet = FlippedCanvas()
    var motionSource: (FileMap, RenderedFiles)? {
        guard !isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let geometry, let rendered else { return nil }
        return (geometry, rendered)
    }
    var trackingSelection: Bool { down != nil }
    private var revision = 0, drawing = false
    private var reflow: DispatchWorkItem?
    private var lastSize: NSSize = .zero, lastScale: CGFloat = 0
    private static let whole = MapRenderSettings.whole
    private(set) var viewport = whole {
        didSet { selectionOverlay.needsDisplay = true }
    }
    var zoom: CGFloat { 1 / viewport.width }
    var aspect: CGFloat { bounds.width > 1 && bounds.height > 1 ? bounds.width / bounds.height : 1.4 }
    private var down: NSPoint?, panOrigin: NSRect?
    private var dragged = false
    private var firstClickKey: UInt64?
    private var rootKeys = Set<UInt64>()
    private var marked: [CGRect] = []
    private var selectedBounds: CGRect?
    var selection = Set<UInt64>() { didSet { if selection != oldValue { updateSelection() } } }
    private let overlay = MapOverlay()
    private let selectionOverlay = MapSelectionOverlay()
    private var hoverTracking: NSTrackingArea?
    private var hoverPoint: CGPoint?
    private var hoverKey: UInt64?
    private var hoverPath: String?
    private var hoverTip: NSView.ToolTipTag?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let renderer = ChartRenderer.shared
            DispatchQueue.main.async { [weak self] in self?.renderer = renderer }
        }
        layer?.masksToBounds = true
        tileSheet.wantsLayer = true
        tileSheet.frame = bounds; tileSheet.autoresizingMask = [.width, .height]
        tileSheet.setAccessibilityElement(false)
        addSubview(tileSheet)
        overlay.map = self
        overlay.frame = bounds; overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        selectionOverlay.map = self
        selectionOverlay.frame = bounds; selectionOverlay.autoresizingMask = [.width, .height]
        selectionOverlay.wantsLayer = true
        selectionOverlay.setAccessibilityElement(false)
        addSubview(selectionOverlay)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Disk usage treemap")
        setAccessibilityHelp("Select a file to reveal its size in the outline. Command-scroll or pinch to zoom.")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func accessibilityChanged() {
        overviewIsCurrent = false; endMotion(); revision += 1; scheduleFrame()
        overlay.needsDisplay = true; selectionOverlay.needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        accessibilityChanged()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        updateHover()
    }
    override func mouseExited(with event: NSEvent) { hoverPoint = nil; updateHover() }

    private func updateHover(force: Bool = false) {
        let key = hoverPoint.flatMap { p in bounds.contains(p) ? hit(world(p)) : nil }
        let packed = key.map { UInt64($0.folder) << 32 | UInt64($0.slot) }
        guard packed != hoverKey || (force && hoverPoint != nil) else { return }
        hoverKey = packed
        if let hoverTip { removeToolTip(hoverTip); self.hoverTip = nil }
        guard let key, let packed, let geometry, let url = geometry.model.url(folder: key.folder, slot: key.slot, directory: false) else {
            hoverPath = nil; hovered?(nil, nil); return
        }
        hoverPath = url.path
        if let rect = geometry.bounds(of: packed) {
            let area = screen(rect).intersection(bounds)
            if !area.isEmpty { hoverTip = addToolTip(area, owner: self, userData: nil) }
        }
        hovered?(url, colorGroup(for: key))
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        guard let path = hoverPath else { return "" }
        if let mode = displayedColors?.mode, [.created, .modified, .accessed].contains(mode), let hoverKey, let geometry {
            var seconds: Int64 = 0
            let known = dt_group_date(geometry.model.handle, DTKey(hoverKey), UInt8(mode.rawValue), &seconds)
            let date = known ? Date(timeIntervalSince1970: Double(seconds)).formatted(date: .abbreviated, time: .shortened) : "Unknown date"
            return "\(path)\n\(mode.title) · \(date)"
        }
        return path
    }
    func colorGroup(for key: DTKey, directory: Bool = false) -> UInt32? {
        guard let geometry else { return nil }
        guard let displayedColors else { return geometry.kind(at: key) }
        if directory {
            var row = DTRow()
            guard dt_entry(geometry.model.handle, key.folder, key.slot, &row) else { return nil }
            return displayedColors.group(forDirectory: row.child)
        }
        return displayedColors.group(at: key)
    }
    func trashRegions(for keys: Set<UInt64>) -> [TrashGlassRegion] {
        guard let geometry, let rendered, let window else { return [] }
        let painted = screen(rendered.viewport).intersection(visibleRect)
        return keys.compactMap { key in
            guard let worldRect = rootKeys.contains(key) ? Self.whole : geometry.bounds(of: key) else { return nil }
            let local = screen(worldRect).intersection(painted)
            guard !local.isEmpty else { return nil }
            let rect = window.convertToScreen(convert(local, to: nil)), source = world(local)
            guard !rect.isEmpty else { return nil }
            return TrashGlassRegion(shape: .tile(rect)) { p in
                rendered.rgb(at: CGPoint(x: source.minX + (p.x - rect.minX) / rect.width * source.width,
                    y: source.minY + (rect.maxY - p.y) / rect.height * source.height))
            }
        }
    }
    func useColors(_ colors: MapBreakdown?) {
        guard requestedColors !== colors else { return }
        requestedColors = colors
        overviewIsCurrent = false
        revision += 1
        scheduleFrame()
    }
    func setPresented(_ presented: Bool) {
        let hidden = !presented
        guard isHidden != hidden else { return }
        isHidden = hidden
        revision += 1
        if presented { scheduleFrame(); scheduleReflow() } else { reflow?.cancel(); endMotion() }
    }

    func clear() {
        reflow?.cancel(); endMotion(); revision += 1
        firstClickKey = nil
        geometry = nil; rendered = nil; requestedColors = nil; displayedColors = nil
        rootKeys.removeAll(); selection.removeAll(); viewport = Self.whole
        down = nil; panOrigin = nil; overview = nil; overviewIsCurrent = false
        updateSelection(); updateHover(force: true)
        needsDisplay = true; overlay.needsDisplay = true
        setAccessibilityValue("Waiting for files")
    }

    func show(_ listing: FolderListing, ancestors: Set<UInt64>) {
        reflow?.cancel()
        endMotion()
        firstClickKey = nil
        geometry = listing.geometry
        requestedColors = nil; displayedColors = nil
        rootKeys = ancestors
        viewport = Self.whole
        rendered = nil; down = nil; panOrigin = nil; overview = nil; overviewIsCurrent = false
        updateSelection()
        revision += 1
        updateHover(force: true)
        needsDisplay = true; overlay.needsDisplay = true
        setAccessibilityValue("Preparing file map")
        scheduleFrame()
        scheduleReflow()
        zoomChanged?()
    }

    var renderSettings: MapRenderSettings? {
        guard !isHidden, bounds.width >= 1, bounds.height >= 1 else { return nil }
        let scale = min(window?.backingScaleFactor ?? 2, sqrt(24_000_000 / (bounds.width * bounds.height)))
        return MapRenderSettings(viewport: viewport, width: max(1, Int((bounds.width * scale).rounded())),
            height: max(1, Int((bounds.height * scale).rounded())), scale: scale, dark: effectiveAppearance.usesDarkColors,
            shine: !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, focus: legendFocus)
    }

    func showLive(_ list: FolderListing, ancestors: Set<UInt64>, colors: MapBreakdown?,
                  frame: LiveMapFrame?, settings: MapRenderSettings?, sameFolder: Bool) {
        reflow?.cancel(); endMotion()
        let prior = rendered
        if geometry?.model !== list.model || geometry?.folder != list.folder { firstClickKey = nil }
        geometry = list.geometry; rootKeys = ancestors
        requestedColors = colors; displayedColors = colors
        overviewIsCurrent = false
        if !sameFolder { viewport = Self.whole; overview = nil }
        revision += 1
        if let frame, let settings, settings == renderSettings {
            rendered = frame.raster
            overview = frame.overview; overviewIsCurrent = overview != nil
            discardTrashBacking()
            if sameFolder, let prior, prior.image === frame.priorImage, prior.focus == frame.raster.focus,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                if !frame.trashPatches.isEmpty {
                    updateSelection()
                    animateTrash(frame.trashPatches, settings: settings)
                } else if !frame.moves.isEmpty { animateTiles(frame.moves, over: prior) }
            }
        } else {
            let compatible = settings?.focus == legendFocus ? frame : nil
            if let compatible { overview = compatible.overview }
            rendered = isHidden ? nil : compatible?.raster ?? (sameFolder ? prior : nil)
            scheduleFrame()
        }
        updateSelection(); updateHover(force: true)
        needsDisplay = true; overlay.needsDisplay = true
        setAccessibilityValue("\(list.geometry.count.formatted()) file shapes · \(Int(zoom.rounded()))×")
        scheduleReflow()
    }

    private func animateTrash(_ patches: [ChartPatch], settings: MapRenderSettings) {
        guard let renderer, window?.isVisible == true else { return }
        let ratio = min(1, 2048 / Double(max(settings.width, settings.height)))
        let w = max(1, Int(Double(settings.width) * ratio)), h = max(1, Int(Double(settings.height) * ratio))
        guard let texture = renderer.snapshot(width: w, height: h, draw: { context in
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: CGFloat(w) / bounds.width, y: -CGFloat(h) / bounds.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                draw(bounds); drawOverlay(bounds); drawSelection(in: context)
            }
            NSGraphicsContext.restoreGraphicsState()
        }), let view = ChartReflow(frame: bounds, renderer: renderer, texture: texture, patches: patches, radial: false) else { return }
        trashTransition = view; addSubview(view)
        view.completed = { [weak self] in self?.endMotion(); self?.updateHover(force: true) }
        view.start()
    }
    private func endMotion() {
        if let view = trashTransition {
            view.cancel(); trashTransition = nil; needsDisplay = true; overlay.needsDisplay = true
        }
        motion.stop(); movingTiles.removeAll()
        tileSheet.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }
    private func animateTiles(_ moves: [MovingTile], over previous: RenderedFiles) {
        guard let sheet = tileSheet.layer else { return }
        movingTiles = moves
        CATransaction.begin(); CATransaction.setDisableActions(true)
        func place(_ image: CGImage, in rect: CGRect) -> CALayer {
            let layer = CALayer(); layer.contents = image; layer.contentsGravity = .resize
            layer.frame = tileSheet.convertToLayer(screen(rect)); sheet.addSublayer(layer)
            return layer
        }
        func animate(_ layer: CALayer, _ key: String, from: Any, to: Any) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from; animation.toValue = to; animation.duration = ChartMotion.duration
            animation.timingFunction = ChartMotion.timingFunction
            layer.add(animation, forKey: key)
        }
        let back = place(previous.image, in: previous.viewport)
        let footprint = CGMutablePath()
        for tile in moves {
            for rect in [tile.from, tile.to] {
                footprint.addRect(back.convert(tileSheet.convertToLayer(screen(rect)), from: sheet))
            }
        }
        let mask = CAShapeLayer()
        mask.frame = back.bounds; mask.path = footprint
        back.mask = mask
        back.opacity = 0; animate(back, "opacity", from: 1, to: 0)
        for tile in moves {
            let layer = place(tile.image, in: tile.from), position = layer.position, bounds = layer.bounds
            layer.frame = tileSheet.convertToLayer(screen(tile.to))
            animate(layer, "position", from: position, to: layer.position)
            animate(layer, "bounds", from: bounds, to: layer.bounds)
        }
        CATransaction.commit()
        motion.start { [weak self] in
            guard let self else { return }
            if self.motion.fraction == 1 { self.endMotion(); self.updateHover(force: true) }
            self.overlay.needsDisplay = true
        }
    }
    private func hit(_ point: CGPoint) -> DTKey? {
        if let view = trashTransition {
            guard let p = view.destination(x: (point.x - viewport.minX) / viewport.width,
                y: (point.y - viewport.minY) / viewport.height) else { return nil }
            return geometry?.hit(CGPoint(x: viewport.minX + p.x * viewport.width, y: viewport.minY + p.y * viewport.height))
        }
        if let tile = movingTiles.last(where: { $0.rect(at: motion.fraction).contains(point) }) { return DTKey(tile.key) }
        return geometry?.hit(point)
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        guard lastSize != bounds.size || scale != lastScale else { return }
        discardTrashBacking()
        endMotion()
        selectionOverlay.needsDisplay = true
        lastSize = bounds.size; lastScale = scale
        revision += 1
        scheduleFrame()
        updateHover(force: true)
        scheduleReflow()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
    private func scheduleReflow() {
        reflow?.cancel()
        guard !isHidden, let current = geometry, abs(log(aspect / current.aspect)) > 0.2, viewport == Self.whole else { return }
        let target = aspect
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.geometry === current, self.viewport == Self.whole else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let new = FileMap(model: current.model, folder: current.folder, aspect: target)
                DispatchQueue.main.async {
                    guard self.geometry === current, self.viewport == Self.whole, abs(log(self.aspect / target)) < 0.2 else { return }
                    self.overviewIsCurrent = false
                    self.geometry = new
                    self.updateSelection()
                    self.updateHover(force: true)
                    self.revision += 1; self.scheduleFrame()
                }
            }
        }
        reflow = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
    }

    private func scheduleFrame() {
        if isHidden {
            if displayedColors !== requestedColors {
                displayedColors = requestedColors
                coloringDidDisplay?(requestedColors)
            }
            return
        }
        guard !drawing, let current = geometry, let settings = renderSettings else { return }
        let token = revision
        let colors = requestedColors
        let needsOverview = !overviewIsCurrent
        drawing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let frame = settings.render(current, colors: colors)
            let base = settings.viewport == Self.whole ? frame?.image :
                (needsOverview ? settings.overview(current, colors: colors) : nil)
            DispatchQueue.main.async {
                self.drawing = false
                if !self.isHidden, self.geometry === current, self.requestedColors === colors, self.renderSettings == settings, let frame {
                    self.rendered = frame
                    if let base { self.overview = base; self.overviewIsCurrent = true }
                    self.discardTrashBacking()
                    if self.displayedColors !== colors {
                        self.displayedColors = colors
                        self.coloringDidDisplay?(colors)
                        self.updateHover(force: true)
                    }
                    self.needsDisplay = true; self.overlay.needsDisplay = true
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
        discardTrashBacking()
        endMotion()
        viewport = next; revision += 1
        needsDisplay = true; overlay.needsDisplay = true
        updateHover(force: true); scheduleFrame(); zoomChanged?()
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
    func restoreViewport(_ viewport: CGRect) { move(to: viewport) }
    func fitSelection() {
        guard let r = selectedBounds else { return }
        let span = max(r.width, r.height) * 1.2
        move(to: CGRect(x: r.midX - span / 2, y: r.midY - span / 2, width: span, height: span))
    }
    func revealSelection() {
        guard let r = selectedBounds else { return }
        let footprint = screen(r)
        if max(footprint.width, footprint.height) < 3 { fitSelection(); return }
        guard !viewport.contains(r) else { return }
        let span = max(viewport.width, min(1, max(r.width, r.height) * 1.04))
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
        let previous = marked
        if !rootKeys.isDisjoint(with: selection) { marked = [Self.whole] }
        else { marked = selection.compactMap { geometry?.bounds(of: $0) } }
        selectedBounds = marked.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
        if previous.count == 1, marked.count == 1, let old = previous.first, let new = marked.first,
           old != Self.whole, new != Self.whole, old.intersects(viewport), new.intersects(viewport) {
            for rect in [old, new] {
                let visible = screen(rect).intersection(bounds)
                selectionOverlay.setNeedsDisplay(visible.insetBy(dx: -1, dy: -1))
            }
        } else {
            selectionOverlay.needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        guard trashTransition == nil, let view = rendered, geometry?.count != 0, let cg = NSGraphicsContext.current?.cgContext else { return }
        func draw(_ image: CGImage, _ rect: CGRect) {
            let visible = rect.intersection(viewport)
            guard !visible.isNull, !visible.isEmpty else { return }
            var area = screen(rect), tile = image
            if area.width > bounds.width * 4 || area.height > bounds.height * 4 {
                let sx = CGFloat(image.width) / rect.width, sy = CGFloat(image.height) / rect.height
                let crop = CGRect(x: (visible.minX - rect.minX) * sx, y: (visible.minY - rect.minY) * sy,
                    width: visible.width * sx, height: visible.height * sy).integral
                guard let part = image.cropping(to: crop) else { return }
                tile = part
                area = screen(CGRect(x: rect.minX + crop.minX / sx, y: rect.minY + crop.minY / sy,
                    width: crop.width / sx, height: crop.height / sy))
            }
            guard area.intersects(dirtyRect) else { return }
            cg.saveGState()
            cg.translateBy(x: area.minX, y: area.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.interpolationQuality = .none
            cg.draw(tile, in: CGRect(origin: .zero, size: area.size))
            cg.restoreGState()
        }
        if !view.viewport.contains(viewport), let overview { draw(overview, Self.whole) }
        draw(view.image, view.viewport)
    }
    private func drawHairline(_ rect: CGRect, in context: CGContext) {
        let pixels = context.convertToDeviceSpace(rect).standardized
        let x = pixels.width < 1 ? floor(pixels.midX) : pixels.minX.rounded()
        let y = pixels.height < 1 ? floor(pixels.midY) : pixels.minY.rounded()
        let outer = CGRect(x: x, y: y, width: max(1, pixels.maxX.rounded() - x), height: max(1, pixels.maxY.rounded() - y))
        context.beginPath()
        context.addRect(context.convertToUserSpace(outer))
        if outer.width > 2 && outer.height > 2 {
            context.addRect(context.convertToUserSpace(outer.insetBy(dx: 1, dy: 1)))
        }
        context.drawPath(using: .eoFill)
    }
    fileprivate func drawOverlay(_ dirty: NSRect) {
        guard trashTransition == nil else { return }
        if rendered == nil || geometry?.count == 0 {
            let title = geometry?.count == 0 ? "No files in this folder" : "Drawing file map…"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
            return
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
        for label in rendered?.labels ?? [] {
            let tile = movingTiles.first { $0.key == label.key }
            let r = screen(tile?.rect(at: motion.fraction) ?? label.rect).intersection(bounds)
            guard r.intersects(dirty), r.width >= 44, r.height >= 21 else { continue }
            let ink = label.lightInk ? NSColor.white : NSColor.black
            let large = r.width >= 150 && r.height >= 74
            let inset: CGFloat = large ? 9 : 4
            let box = CGRect(x: r.minX + inset, y: r.minY + inset, width: r.width - 2 * inset, height: large ? 23 : 16)
            (label.title as NSString).draw(in: box, withAttributes: [.font: NSFont.systemFont(ofSize: large ? 16 : 11, weight: .semibold), .foregroundColor: ink, .paragraphStyle: para])
            if r.height > 39 {
                (label.size as NSString).draw(in: box.offsetBy(dx: 0, dy: large ? 22 : 15), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: large ? 12 : 10, weight: .regular), .foregroundColor: ink, .paragraphStyle: para])
            }
        }
    }
    fileprivate func drawSelection(in context: CGContext) {
        guard !marked.isEmpty, let rendered, rendered.focus == nil else { return }
        context.saveGState()
        context.setShouldAntialias(false)
        if rootKeys.isDisjoint(with: selection) {
            if marked.count == 1, let rect = marked.first, rect.intersects(viewport) {
                context.addRect(bounds)
                context.addRect(screen(rect).intersection(bounds))
                context.setFillColor(CGColor(gray: 0, alpha: selectionDimOpacity))
                context.drawPath(using: .eoFill)
            } else {
                let selected = CGMutablePath()
                for region in marked where region.intersects(viewport) { selected.addRect(screen(region).intersection(bounds)) }
                shadeUnselected(in: context, chart: CGPath(rect: bounds, transform: nil), selected: selected)
            }
        }
        let outline = effectiveAppearance.usesDarkColors ? NSColor.black : NSColor.white
        context.setFillColor(outline.withAlphaComponent(0.95).cgColor)
        for region in marked where region.intersects(viewport) { drawHairline(screen(region), in: context) }
        context.restoreGState()
    }
    private func route(at event: NSEvent) -> [DiskItem]? {
        guard let g = geometry, let key = hit(world(convert(event.locationInWindow, from: nil))) else { return nil }
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
        panOrigin = zoom > 1 ? viewport : nil
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = down.x - point.x, dy = down.y - point.y
        guard dragged || max(abs(dx), abs(dy)) > 3 else { return }
        dragged = true
        if let origin = panOrigin, bounds.width > 0, bounds.height > 0 {
            move(to: origin.offsetBy(dx: dx * origin.width / bounds.width, dy: dy * origin.height / bounds.height))
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        down = nil; panOrigin = nil
        guard !dragged else { firstClickKey = nil; return }
        let mode = SelectionMode(event.modifierFlags)
        guard let path = route(at: event), let key = path.last?.key else { firstClickKey = nil; return }
        let zoomToFile = mode == .replace && event.clickCount == 2 && firstClickKey == key
        firstClickKey = mode == .replace && event.clickCount == 1 ? key : nil
        choose?([path], mode)
        if zoomToFile { fitSelection() }
    }
}
