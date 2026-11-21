import AppKit
import Metal

struct Sector {
    let item: DiskItem, start: Double, end: Double, group: UInt32?, tone: KindTone
    let lastRing: Int, parentInode: UInt64
    func path(center: CGPoint, inner: CGFloat, outer: CGFloat) -> CGPath {
        let a = (.pi / 2) - start * 2 * .pi, b = (.pi / 2) - end * 2 * .pi
        let path = CGMutablePath()
        path.addArc(center: center, radius: outer, startAngle: a, endAngle: b, clockwise: true)
        path.addArc(center: center, radius: inner, startAngle: b, endAngle: a, clockwise: false)
        path.closeSubpath()
        return path
    }
    var identity: MapItemName { MapItemName(parent: parentInode, name: item.title) }
    func spanning(_ start: Double, _ end: Double) -> Self {
        Self(item: item, start: start, end: end, group: group, tone: tone, lastRing: lastRing, parentInode: parentInode)
    }
}

private struct SectorPaint {
    let fill: CGColor, seam: CGColor, outer: CGColor, inner: CGColor, ink: NSColor
    let surface: CGGradient
    init(_ rgb: UInt32) {
        let tint = dt_glass_tint(rgb)
        func color(_ pixel: UInt32) -> CGColor {
            NSColor(srgbRed: CGFloat(pixel & 255)/255, green: CGFloat(pixel >> 8 & 255)/255,
                blue: CGFloat(pixel >> 16 & 255)/255, alpha: 1).cgColor
        }
        fill = color(tint.surface.64); seam = color(tint.seam)
        outer = color(tint.top); inner = color(tint.bottom)
        ink = tint.light_ink ? .white : .black.withAlphaComponent(0.87)
        let samples = [tint.surface.128, tint.surface.116, tint.surface.102, tint.surface.73,
                       tint.surface.54, tint.surface.34, tint.surface.16, tint.surface.0]
        let stops: [CGFloat] = [0, 12, 26, 55, 74, 94, 112, 128].map { $0/128 }
        surface = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: samples.map(color) as CFArray, locations: stops)!
    }
}

struct SunburstStyle: Equatable {
    let radius: CGFloat, scale: CGFloat, appearance: NSAppearance, shine: Bool
    var hub: CGFloat { min(70, max(22, radius * 0.23)) }

    fileprivate func draw(_ rings: Rings, list: FolderListing, center: CGPoint, in context: CGContext, cancelled: () -> Bool) {
        let pixel = 1 / scale, dark = appearance.usesDarkColors
        var paints = [UInt32: SectorPaint]()
        func ringRadius(_ i: Int) -> CGFloat { hub + (radius - hub) * rings.stops[i] }
        context.setLineWidth(pixel)
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingMiddle
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for (i, band) in rings.bands.enumerated() {
            if cancelled() { return }
            let inner = ringRadius(i), outer = ringRadius(i+1)
            let middle = (inner+outer)/2, thickness = outer-inner
            var shapes: [UInt32: CGMutablePath] = [:]
            for sector in band {
                let rgb = dark ? sector.tone.dark : sector.tone.light
                if shapes[rgb] == nil { shapes[rgb] = CGMutablePath() }
                shapes[rgb]!.addPath(sector.path(center: center, inner: inner, outer: outer))
            }
            for (rgb, shape) in shapes {
                if cancelled() { return }
                let paint = paints[rgb] ?? SectorPaint(rgb)
                paints[rgb] = paint
                if shine {
                    context.saveGState(); context.addPath(shape); context.clip()
                    context.drawRadialGradient(paint.surface, startCenter: center, startRadius: inner,
                        endCenter: center, endRadius: outer, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    context.restoreGState()
                } else { context.setFillColor(paint.fill); context.addPath(shape); context.fillPath() }
            }
            for sector in band {
                let rgb = dark ? sector.tone.dark : sector.tone.light
                guard let paint = paints[rgb] else { continue }
                let arc = (sector.end-sector.start) * 2 * .pi
                if middle * arc >= pixel * 2.5 {
                    let a = .pi/2 - sector.start * 2 * .pi, b = .pi/2 - sector.end * 2 * .pi
                    context.setStrokeColor(paint.seam)
                    context.move(to: CGPoint(x: center.x + inner*cos(a), y: center.y + inner*sin(a)))
                    context.addLine(to: CGPoint(x: center.x + outer*cos(a), y: center.y + outer*sin(a)))
                    context.strokePath()
                    context.setStrokeColor(shine ? paint.outer : paint.seam)
                    context.addArc(center: center, radius: outer - pixel/2, startAngle: a, endAngle: b, clockwise: true)
                    context.strokePath()
                    if shine && thickness > 4 * pixel {
                        context.setStrokeColor(paint.inner)
                        context.addArc(center: center, radius: inner + pixel/2, startAngle: a, endAngle: b, clockwise: true)
                        context.strokePath()
                    }
                }
                let width = min(142, middle * arc - 10, sqrt(max(0, 3 * middle * (thickness-14))))
                if width >= 43 && thickness >= 17 {
                    let angle = .pi/2 - (sector.start + sector.end) * .pi
                    var tangent = (angle - .pi/2).truncatingRemainder(dividingBy: .pi)
                    if tangent < -.pi/2 { tangent += .pi }
                    context.saveGState()
                    context.translateBy(x: center.x + middle*cos(angle), y: center.y + middle*sin(angle))
                    context.rotate(by: tangent)
                    (sector.item.title as NSString).draw(in: CGRect(x: -width/2, y: -7, width: width, height: 14),
                        withAttributes: [.font: font, .foregroundColor: paint.ink, .paragraphStyle: style])
                    context.restoreGState()
                }
            }
        }
        let url = list.model.url(folder: list.folder, directory: true)
        let title = url.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent } ?? ""
        let textWidth = max(15, hub * 1.82)
        let textRect = CGRect(x: center.x - textWidth/2, y: center.y + 1, width: textWidth, height: 16)
        (title as NSString).draw(in: textRect, withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        (formatBytes(list.summary.bytes) as NSString).draw(in: textRect.offsetBy(dx: 0, dy: -18), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
    }
}

private final class RingArtwork {
    let image: CGImage, texture: MTLTexture?, style: SunburstStyle
    init?(_ layout: Rings, list: FolderListing, style: SunburstStyle, cancelled: () -> Bool) {
        let side = max(1, Int(ceil(style.radius * 2 * style.scale)))
        guard side <= Int(sqrt(24_000_000.0)), !cancelled(), let context = ChartRenderer.bitmap(width: side, height: side) else { return nil }
        let scale = CGFloat(side) / (2 * style.radius)
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        style.appearance.performAsCurrentDrawingAppearance {
            style.draw(layout, list: list, center: CGPoint(x: style.radius, y: style.radius), in: context, cancelled: cancelled)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard !cancelled(), let image = context.makeImage() else { return nil }
        self.image = image; self.style = style
        texture = side <= 2048 ? ChartRenderer.shared?.texture(from: context) : nil
    }
}

private final class RingSelection: NSView {
    weak var map: Sunburst?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { map?.drawSelection() }
}

struct Rings {
    let bands: [[Sector]]
    let stops: [CGFloat]
    fileprivate var artwork: RingArtwork?
    init(_ list: FolderListing, colors: MapBreakdown?, radius: CGFloat, scale: CGFloat, style: SunburstStyle? = nil, cancelled: () -> Bool) {
        let maximum = max(2, min(8, Int(radius / 26)))
        var levels = Array(repeating: [Sector](), count: maximum)
        var tones: [UInt32: KindTone] = [:]
        let model = list.model
        func group(_ item: DiskItem) -> UInt32? {
            var candidate = item
            while true {
                let key = DTKey(candidate.key)
                if let colors {
                    if !candidate.isFolder { return colors.group(at: key) }
                    if let id = colors.group(forDirectory: candidate.child) { return id }
                } else {
                    let id = list.geometry.kind(at: key)
                    if id != 0 { return id }
                }
                var row = DTRow()
                guard candidate.isFolder, dt_child(model.handle, candidate.child, 0, &row) else { return nil }
                candidate = DiskItem(row, folder: candidate.child)
            }
        }
        func visit(_ folder: UInt32, _ bytes: UInt64, _ start: Double, _ span: Double, _ depth: Int) -> Int {
            var deepest = depth - 1
            guard depth < maximum, bytes != 0 else { return deepest }
            var angle = start
            let inode = dt_directory_identity(model.handle, folder).inode
            for i in 0..<dt_child_count(model.handle, folder) {
                var row = DTRow()
                guard !cancelled(), dt_child(model.handle, folder, i, &row) else { break }
                let width = min(start + span - angle, span * Double(row.bytes) / Double(bytes))
                guard width * 2 * .pi * radius * scale >= 0.85 else { break }
                let item = DiskItem(row, folder: folder), id = group(item)
                let tone = id.map { id in
                    if let tone = tones[id] { return tone }
                    let value = colors.map { $0.tone(for: id) ?? .neutral } ?? FileKindCatalog.shared.kind(id).tone
                    tones[id] = value
                    return value
                } ?? .neutral
                let last = item.isFolder ? visit(item.child, item.bytes, angle, width, depth + 1) : depth
                levels[depth].append(Sector(item: item, start: angle, end: angle + width, group: id, tone: tone,
                    lastRing: last, parentInode: inode))
                deepest = max(deepest, last)
                angle += width
            }
            return deepest
        }
        _ = visit(list.folder, list.summary.bytes, 0, 1, 0)
        bands = Array(levels.prefix { !$0.isEmpty })
        let coverage = bands.map { band in band.reduce(0.0) { $0 + $1.end - $1.start } }
        let total = coverage.reduce(0, +)
        var position: CGFloat = 0
        stops = [0] + coverage.map { share in
            position += 0.35 / Double(coverage.count) + 0.65 * share / total
            return position
        }
        if let style { artwork = RingArtwork(self, list: list, style: style, cancelled: cancelled) }
    }
    private init(bands: [[Sector]], stops: [CGFloat]) { self.bands = bands; self.stops = stops }
    func starting(at previous: Self) -> Self? {
        var changed = stops != previous.stops
        let bands = self.bands.enumerated().map { level, band in
            let old = level < previous.bands.count ? previous.bands[level] : []
            let byName = Dictionary(old.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
            var cursor = 0.0
            return band.map { sector in
                let before = byName[sector.identity]
                let start = max(cursor, before?.start ?? cursor)
                cursor = max(start, before?.end ?? start)
                if abs(start - sector.start) + abs(cursor - sector.end) > 0.00001 { changed = true }
                return sector.spanning(start, cursor)
            }
        }
        let stops = self.stops.indices.map { previous.stops[min($0, previous.stops.count - 1)] }
        return changed ? Self(bands: bands, stops: stops) : nil
    }
    func interpolated(from old: Self, fraction: CGFloat) -> Self {
        let stops = zip(old.stops, self.stops).map { $0 + ($1 - $0) * fraction }
        let bands = zip(old.bands, self.bands).map { from, to in
            zip(from, to).map { a, b in b.spanning(a.start + (b.start - a.start)*fraction, a.end + (b.end - a.end)*fraction) }
        }
        return Self(bands: bands, stops: stops)
    }
}

private struct RingHighlight: Equatable {
    let focusedGroup: UInt32?, selection: Set<UInt64>, whole: Bool
    var empty: Bool { focusedGroup == nil && selection.isEmpty }
    func draw(_ rings: Rings, style: SunburstStyle, center: CGPoint, in context: CGContext) {
        guard !empty else { return }
        let hub = style.hub, radius = style.radius
        func path(_ sector: Sector, _ first: Int, through last: Int? = nil) -> CGPath {
            sector.path(center: center, inner: hub + (radius - hub) * rings.stops[first],
                outer: hub + (radius - hub) * rings.stops[(last ?? first) + 1])
        }
        if let focusedGroup {
            let matches = CGMutablePath(), others = CGMutablePath()
            for (level, band) in rings.bands.enumerated() {
                for sector in band {
                    (sector.group == focusedGroup ? matches : others).addPath(path(sector, level))
                }
            }
            context.addPath(others)
            context.setFillColor(CGColor(gray: 0, alpha: selectionDimOpacity))
            context.fillPath()
            context.addPath(matches)
            context.setLineWidth(1 / style.scale)
            context.setStrokeColor(NSColor.labelColor.cgColor)
            context.strokePath()
            return
        }
        guard !selection.isEmpty else { return }
        context.setLineWidth(1 / style.scale)
        context.setStrokeColor(NSColor.labelColor.cgColor)
        if whole {
            for r in [hub, radius] {
                context.strokeEllipse(in: CGRect(x: center.x-r, y: center.y-r, width: 2*r, height: 2*r))
            }
            return
        }
        let selected = CGMutablePath()
        for (i, band) in rings.bands.enumerated() {
            for sector in band where selection.contains(sector.item.key) { selected.addPath(path(sector, i, through: sector.lastRing)) }
        }
        guard !selected.isEmpty else { return }
        let chart = CGMutablePath()
        for r in [hub, radius] { chart.addEllipse(in: CGRect(x: center.x-r, y: center.y-r, width: 2*r, height: 2*r)) }
        shadeUnselected(in: context, chart: chart, selected: selected)
        context.addPath(selected)
        context.strokePath()
    }
}

private struct RingFrame {
    let layout: Rings, list: FolderListing, style: SunburstStyle, highlight: RingHighlight
    var readyTexture: MTLTexture? { highlight.empty ? layout.artwork?.texture : nil }

    func texture(using renderer: ChartRenderer) -> MTLTexture? {
        if let readyTexture { return readyTexture }
        let diameter = 2 * style.radius, center = CGPoint(x: style.radius, y: style.radius)
        let side = min(2048, max(1, Int(ceil(diameter * style.scale))))
        return renderer.snapshot(width: side, height: side) { context in
            let scale = CGFloat(side) / diameter
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            style.appearance.performAsCurrentDrawingAppearance {
                if let artwork = layout.artwork {
                    context.draw(artwork.image, in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
                } else { style.draw(layout, list: list, center: center, in: context, cancelled: { false }) }
                highlight.draw(layout, style: style, center: center, in: context)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

final class Sunburst: NSView {
    var choose: (([[DiskItem]], SelectionMode) -> Void)?
    var menuForRoute: (([DiskItem]) -> NSMenu?)?
    var enter: (([DiskItem]) -> Void)?
    var up: (() -> Void)?
    var hovered: ((URL?, UInt32?) -> Void)?
    var open: (() -> Void)?
    private var focusedGroup: UInt32?
    private weak var focusColors: MapBreakdown?
    private var ringColors: MapBreakdown?
    private var ringList: FolderListing?
    private var zoomRenderer: ChartRenderer?
    private var trashTransition: ChartReflow?
    private var zoomView: SunburstZoomView?
    private struct Departure {
        let source: FolderListing, target: FolderListing, rings: Rings, frame: RingFrame?
    }
    private struct ZoomImages {
        let previous: MTLTexture?, next: MTLTexture?, highlight: RingHighlight
    }
    private var departure: Departure?
    var preparingZoom: Bool { departure != nil }
    private var chartFrame: CGRect { CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius) }

    func highlight(group: UInt32?, colors: MapBreakdown?) {
        guard focusedGroup != group || focusColors !== colors else { return }
        focusedGroup = group
        focusColors = colors
        overlay.needsDisplay = true
    }
    var selection = Set<UInt64>() { didSet { if oldValue != selection { overlay.needsDisplay = true } } }
    var scopeKeys = Set<UInt64>() { didSet { if oldValue != scopeKeys { overlay.needsDisplay = true } } }
    func containsWedge(for key: UInt64) -> Bool { rings?.bands.contains { $0.contains { $0.item.key == key } } == true }
    private var list: FolderListing?, colors: MapBreakdown?, rings: Rings?
    private let motion = ChartMotion()
    private let queue = OperationQueue()
    private let overlay = RingSelection()
    private var task: BlockOperation?
    private var lastRadius: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var hoverKey: UInt64?
    private var swipeTime: TimeInterval = 0
    private var dragStart: CGPoint?, dragged = false
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var radius: CGFloat { max(1, min(bounds.width, bounds.height) / 2 - 10) }
    private var hub: CGFloat { min(70, max(22, radius * 0.23)) }
    var liveDimensions: SunburstStyle {
        SunburstStyle(radius: radius, scale: window?.backingScaleFactor ?? 2, appearance: effectiveAppearance,
            shine: !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
    var trackingSelection: Bool { dragStart != nil }
    private func ringRadius(_ boundary: Int) -> CGFloat { hub + (radius - hub) * (rings?.stops[boundary] ?? 0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let renderer = ChartRenderer.shared
            DispatchQueue.main.async { [weak self] in self?.zoomRenderer = renderer }
        }
        overlay.frame = bounds; overlay.autoresizingMask = [.width, .height]; overlay.map = self; addSubview(overlay)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appearanceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Sunburst disk map")
        setAccessibilityHelp("Select a wedge to reveal its item in the folder list. Double-click a folder to explore it.")
    }
    required init?(coder: NSCoder) { nil }
    private func highlight(for colors: MapBreakdown?) -> RingHighlight {
        RingHighlight(focusedGroup: focusColors === colors ? focusedGroup : nil, selection: selection,
            whole: !selection.isDisjoint(with: scopeKeys))
    }
    private func frame(_ layout: Rings, _ list: FolderListing, _ colors: MapBreakdown?) -> RingFrame {
        RingFrame(layout: layout, list: list, style: liveDimensions, highlight: highlight(for: colors))
    }
    private func snapshot(using renderer: ChartRenderer) -> MTLTexture? {
        guard let rings, let ringList else { return nil }
        return frame(rings, ringList, ringColors).texture(using: renderer)
    }
    func prepareZoom(to target: FolderListing) {
        endTrashReflow()
        departure = nil
        guard let source = ringList, source.model === target.model, source.folder != target.folder,
              !isHiddenOrHasHiddenAncestor, window?.isVisible == true, radius > hub,
              let rings else { return }
        let reversing = zoomView.map { Set([$0.parentID, $0.childID]) == Set([source.folder, target.folder]) } ?? false
        let sourceFrame = reversing || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : frame(rings, source, ringColors)
        departure = Departure(source: source, target: target, rings: rings, frame: sourceFrame)
    }
    private func endZoom() {
        zoomView?.isPaused = true
        zoomView?.completed = nil
        zoomView?.removeFromSuperview(); zoomView = nil
        needsDisplay = true; overlay.needsDisplay = true
    }
    private func install(_ result: Rings, for list: FolderListing, colors: MapBreakdown?, sameFolder: Bool = false, prepared: ZoomImages? = nil) {
        let staying = ringList === list || sameFolder
        let trip = departure
        var images = prepared
        if let trip, trip.target === list, let source = trip.frame, let renderer = zoomRenderer,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let target = frame(result, list, colors)
            if prepared?.highlight != target.highlight {
                if let previous = source.readyTexture, let next = target.readyTexture {
                    images = ZoomImages(previous: previous, next: next, highlight: target.highlight)
                } else {
                    let work = BlockOperation()
                    task?.cancel(); task = work
                    work.addExecutionBlock { [weak self, weak work] in
                        guard let work, !work.isCancelled else { return }
                        let previous = prepared?.previous ?? source.texture(using: renderer)
                        guard !work.isCancelled else { return }
                        let textures = ZoomImages(previous: previous, next: target.texture(using: renderer), highlight: target.highlight)
                        DispatchQueue.main.async {
                            guard let self, self.task === work, !work.isCancelled, self.departure?.target === list else { return }
                            self.task = nil
                            self.install(result, for: list, colors: colors, sameFolder: sameFolder, prepared: textures)
                        }
                    }
                    queue.addOperation(work)
                    return
                }
            }
        }
        departure = nil
        rings = result; ringList = list; ringColors = colors
        needsDisplay = true; overlay.needsDisplay = true
        guard let trip, trip.target === list else { if !staying { endZoom() }; return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { endZoom(); return }
        if let zoomView, (list.folder == zoomView.parentID || list.folder == zoomView.childID),
           (trip.source.folder == zoomView.parentID || trip.source.folder == zoomView.childID) {
            zoomView.reverse(towardChild: list.folder == zoomView.childID)
            return
        }
        endZoom()
        func anchor(in layout: Rings, folder: UInt32) -> (Int, Sector)? {
            for (level, band) in layout.bands.enumerated() {
                if let sector = band.first(where: { $0.item.child == folder }) { return (level, sector) }
            }
            return nil
        }
        let entering = anchor(in: trip.rings, folder: list.folder)
        guard let (level, wedge) = entering ?? anchor(in: result, folder: trip.source.folder),
              Float(wedge.end) > Float(wedge.start), let zoomRenderer, let previous = images?.previous,
              let image = images?.next else {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.16; fade.preferredFrameRateRange = chartFrameRate(displayRefreshRate); fade.timingFunction = ChartMotion.timingFunction
            layer?.add(fade, forKey: "folderChange")
            return
        }
        let inward = entering != nil
        let transition = SunburstZoomView(frame: chartFrame, renderer: zoomRenderer,
            parent: inward ? previous : image, child: inward ? image : previous,
            parentID: inward ? trip.source.folder : list.folder, childID: inward ? list.folder : trip.source.folder,
            parentStops: inward ? trip.rings.stops : result.stops, childStops: inward ? result.stops : trip.rings.stops,
            anchor: wedge, level: level, hub: hub / radius, inward: inward)
        zoomView = transition; addSubview(transition)
        transition.completed = { [weak self] in self?.endZoom(); self?.refreshHover() }
        transition.start()
    }
    func show(_ next: FolderListing?, colors nextColors: MapBreakdown?, keepingLayout: Bool = false) {
        guard list !== next || colors !== nextColors else { return }
        let same = list === next
        endTrashReflow()
        motion.stop()
        list = next; colors = nextColors
        if !same {
            if departure?.target !== next || next == nil {
                departure = nil; endZoom()
                let sameRoot = next != nil && ringList?.model === next?.model && ringList?.folder == next?.folder
                if !keepingLayout && !sameRoot { rings = nil; ringList = nil; ringColors = nil; discardTrashBacking() }
            }
            hoverKey = nil; toolTip = nil; needsDisplay = true; overlay.needsDisplay = true
        }
        rebuild()
    }
    private func endTrashReflow() {
        guard let view = trashTransition else { return }
        view.cancel(); trashTransition = nil; needsDisplay = true; overlay.needsDisplay = true
    }
    private func animateReflow(from previous: Rings, to layout: Rings, duration: CFTimeInterval) -> Bool {
        guard !layout.bands.isEmpty, let zoomRenderer, window?.isVisible == true else { return false }
        let hubRatio = Float(hub / radius)
        func radiusAt(_ stop: CGFloat) -> Float { hubRatio + (1 - hubRatio) * Float(stop) }
        var patches = [ChartPatch]()
        for (level, band) in layout.bands.enumerated() {
            let oldBand = level < previous.bands.count ? previous.bands[level] : []
            let old = Dictionary(uniqueKeysWithValues: oldBand.map { ($0.item.key, $0) })
            let inside = radiusAt(layout.stops[level]), outside = radiusAt(layout.stops[level + 1])
            let oldInside = radiusAt(previous.stops[min(level, previous.stops.count - 1)])
            let oldOutside = radiusAt(previous.stops[min(level + 1, previous.stops.count - 1)])
            var cursor: Float = 0
            for sector in band {
                let to = SIMD4(Float(sector.start), inside, Float(sector.end), outside)
                let prior = old[sector.item.key]
                let from = SIMD4(prior.map { Float($0.start) } ?? cursor, oldInside,
                    prior.map { Float($0.end) } ?? cursor, oldOutside)
                cursor = from.z
                patches.append(ChartPatch(from: from, to: to))
            }
        }
        guard patches.contains(where: { $0.from != $0.to }) else { return true }
        let hubBox = SIMD4<Float>(0, 0, 1, hubRatio)
        patches.append(ChartPatch(from: hubBox, to: hubBox))
        guard let texture = snapshot(using: zoomRenderer),
              let view = ChartReflow(frame: chartFrame, renderer: zoomRenderer, texture: texture, patches: patches, radial: true, duration: duration) else { return false }
        trashTransition = view; addSubview(view)
        view.completed = { [weak self] in self?.endTrashReflow(); self?.refreshHover() }
        view.start()
        return true
    }
    func showLive(_ next: FolderListing, colors: MapBreakdown?, layout: Rings, sameFolder: Bool, afterTrash: Bool = false) {
        endTrashReflow()
        if afterTrash { departure = nil; endZoom() }
        task?.cancel(); task = nil; motion.stop(); discardTrashBacking()
        if let style = layout.artwork?.style, style != liveDimensions {
            list = next; self.colors = colors; rebuild(); return
        }
        list = next; self.colors = colors; lastRadius = radius
        let previous = rings
        install(layout, for: next, colors: colors, sameFolder: sameFolder)
        guard departure == nil else { return }
        setAccessibilityValue("\(layout.bands.count) rings · \(formatBytes(next.summary.bytes))")
        if sameFolder, zoomView == nil, let previous, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if afterTrash && animateReflow(from: previous, to: layout, duration: 0.36) {
                refreshHover()
                return
            }
            if let start = layout.starting(at: previous) {
                if !afterTrash && animateReflow(from: start, to: layout, duration: ChartMotion.duration) {
                    refreshHover()
                    return
                }
                if layout.bands.reduce(0, { $0 + $1.count }) <= 256 {
                    motion.start(on: self) { [weak self] in
                        guard let self else { return }
                        self.rings = self.motion.fraction == 1 ? layout : layout.interpolated(from: start, fraction: self.motion.fraction)
                        self.needsDisplay = true; self.overlay.needsDisplay = true
                        if self.motion.fraction == 1 { self.refreshHover() }
                    }
                } else {
                    let fade = CATransition(); fade.type = .fade; fade.duration = 0.16; fade.preferredFrameRateRange = chartFrameRate(displayRefreshRate); fade.timingFunction = ChartMotion.timingFunction
                    layer?.add(fade, forKey: "liveReflow")
                }
            }
        }
        needsDisplay = true; overlay.needsDisplay = true
        refreshHover()
    }
    private func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point) { hover(point, force: true) }
    }
    override func layout() {
        super.layout()
        if let view = trashTransition, view.frame != chartFrame { endTrashReflow() }
        if let zoomView, zoomView.frame != chartFrame { endZoom() }
        if abs(radius - lastRadius) > 2 { departure = nil; discardTrashBacking(); rebuild() }
    }
    override func viewDidHide() { super.viewDidHide(); endTrashReflow(); endZoom() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); departure = nil; endTrashReflow(); endZoom(); rebuild() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); appearanceChanged() }
    @objc private func appearanceChanged() { endTrashReflow(); departure = nil; endZoom(); rebuild() }
    private func rebuild() {
        motion.stop()
        task?.cancel()
        guard let list, !isHidden, radius > 2 else { return }
        let style = liveDimensions, colors = colors
        lastRadius = style.radius
        let work = BlockOperation(); task = work
        work.addExecutionBlock { [weak self, weak work] in
            guard let work, !work.isCancelled else { return }
            let result = Rings(list, colors: colors, radius: style.radius, scale: style.scale, style: style) { work.isCancelled }
            DispatchQueue.main.async {
                guard let self, self.task === work, !work.isCancelled else { return }
                self.task = nil
                self.discardTrashBacking()
                self.install(result, for: list, colors: colors)
                self.setAccessibilityValue("\(result.bands.count) rings · \(formatBytes(list.summary.bytes))")
                if let window = self.window { self.hover(self.convert(window.mouseLocationOutsideOfEventStream, from: nil), force: true) }
            }
        }
        queue.addOperation(work)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard trashTransition == nil, zoomView == nil, let context = NSGraphicsContext.current?.cgContext else { return }
        drawChart(in: context)
    }
    private func drawChart(in context: CGContext) {
        guard let rings, let list = ringList ?? list else { return }
        if let artwork = rings.artwork {
            context.draw(artwork.image, in: chartFrame)
        } else {
            liveDimensions.draw(rings, list: list, center: center, in: context, cancelled: { false })
        }
    }
    fileprivate func drawSelection() {
        guard trashTransition == nil, zoomView == nil, let context = NSGraphicsContext.current?.cgContext else { return }
        drawSelection(in: context)
    }
    private func drawSelection(in context: CGContext) {
        guard let rings else { return }
        highlight(for: ringColors).draw(rings, style: liveDimensions, center: center, in: context)
    }
    func trashRegions(for keys: Set<UInt64>) -> [TrashGlassRegion] {
        guard let rings, let window, !keys.isEmpty else { return [] }
        let origin = window.convertPoint(toScreen: convert(center, to: nil))
        let dark = effectiveAppearance.usesDarkColors, whole = !scopeKeys.isDisjoint(with: keys)
        var parents: [(start: Double, end: Double, ring: Int)] = []
        if !whole {
            for (ring, band) in rings.bands.enumerated() {
                for s in band where s.item.isFolder && keys.contains(s.item.key) { parents.append((s.start, s.end, ring)) }
            }
            parents.sort { $0.start < $1.start }
        }
        var sources: [TrashGlassRegion] = []
        for (ring, band) in rings.bands.enumerated() {
            var index = 0
            let inner = ringRadius(ring), outer = ringRadius(ring + 1)
            for s in band {
                while index < parents.count && parents[index].end <= s.start { index += 1 }
                let inside = index < parents.count && ring > parents[index].ring &&
                    s.start >= parents[index].start - 1e-12 && s.end <= parents[index].end + 1e-12
                guard whole || inside || keys.contains(s.item.key) else { continue }
                let shape = TrashGlassShape.wedge(center: origin, inner: inner, outer: outer,
                    start: .pi/2 - s.start * 2 * .pi, sweep: (s.end - s.start) * 2 * .pi)
                let rgb = dark ? s.tone.dark : s.tone.light
                let source = TrashGlassRegion(shape: shape) { _ in rgb }
                if sources.count == TrashGlass.regionLimit {
                    guard source.area > sources[sources.count-1].area else { continue }
                    sources.removeLast()
                }
                let at = sources.firstIndex { $0.area < source.area } ?? sources.endIndex
                sources.insert(source, at: at)
            }
        }
        return sources
    }
    private func sector(at point: CGPoint) -> Sector? {
        let dx = point.x - center.x, dy = point.y - center.y, distance = hypot(dx, dy)
        guard departure == nil, ringList === list, let rings, distance >= hub, distance < radius else { return nil }
        var angle = (.pi / 2 - atan2(dy, dx)) / (2 * .pi)
        if angle < 0 { angle += 1 }
        var depth = (distance - hub) / (radius - hub)
        if let view = trashTransition {
            guard let mapped = view.destination(x: angle, y: distance / radius) else { return nil }
            angle = mapped.x; depth = (mapped.y * radius - hub) / (radius - hub)
        }
        if let zoomView {
            guard let mapped = zoomView.destination(angle: angle, depth: depth) else { return nil }
            (angle, depth) = mapped
        }
        guard let ring = rings.bands.indices.first(where: { depth < rings.stops[$0 + 1] }) else { return nil }
        let band = rings.bands[ring]
        var lo = 0, hi = band.count
        while lo < hi { let mid = (lo + hi) / 2; if band[mid].end <= angle { lo = mid + 1 } else { hi = mid } }
        return lo < band.count && band[lo].start <= angle ? band[lo] : nil
    }
    private func route(_ item: DiskItem) -> [DiskItem]? { list.flatMap { $0.model.route(to: DTKey(item.key), from: $0.folder) } }
    private func hover(_ point: CGPoint, force: Bool = false) {
        let hit = sector(at: point)
        guard force || hit?.item.key != hoverKey else { return }
        hoverKey = hit?.item.key
        let url = hit.flatMap { list?.model.url(folder: $0.item.folder, slot: $0.item.slot, directory: $0.item.isFolder) }
        toolTip = url?.path
        hovered?(url, hit?.group)
    }
    override func mouseMoved(with event: NSEvent) { hover(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hoverKey = nil; toolTip = nil; hovered?(nil, nil) }
    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil); dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start = dragStart, hypot(point.x-start.x, point.y-start.y) > 3 else { return }
        dragged = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        let point = convert(event.locationInWindow, from: nil), mode = SelectionMode(event.modifierFlags)
        guard !dragged else { return }
        guard let item = sector(at: point)?.item, let route = route(item) else {
            if hypot(point.x-center.x, point.y-center.y) < hub { up?() }
            return
        }
        choose?([route], mode)
        if event.clickCount == 2 { if item.isFolder { enter?(route) } else { open?() } }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let item = sector(at: convert(event.locationInWindow, from: nil))?.item, let route = route(item) else { return }
        if event.modifierFlags.contains(.control) { choose?([route], .toggle) }
        else if let menu = menuForRoute?(route) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    private func drill(_ event: NSEvent, inward: Bool) {
        guard event.timestamp - swipeTime > 0.45 else { return }
        swipeTime = event.timestamp
        if !inward { up?(); return }
        guard let item = sector(at: convert(event.locationInWindow, from: nil))?.item, var path = route(item) else { return }
        if !item.isFolder { path.removeLast() }
        if !path.isEmpty { enter?(path) }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), abs(event.scrollingDeltaY) > 0.1 { drill(event, inward: event.scrollingDeltaY > 0) }
        else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) { if abs(event.magnification) > 0.025 { drill(event, inward: event.magnification > 0) } }
}
