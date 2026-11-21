import AppKit

enum SelectionMode {
    case replace, toggle, range, addRange
    init(_ flags: NSEvent.ModifierFlags) {
        let additive = flags.contains(.control) || flags.contains(.command)
        if flags.contains(.shift) { self = additive ? .addRange : .range }
        else { self = additive ? .toggle : .replace }
    }
}

final class FileOutlineView: NSTableView, NSViewToolTipOwner {
    fileprivate weak var outline: Outline?
    var hoverRow: ((Int) -> Void)?
    private var hoverTracking: NSTrackingArea?
    private var tip: NSView.ToolTipTag?
    private var hoverIndex = -1
    private var inside = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollDidMove), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    private func updateHover(_ index: Int) {
        guard hoverIndex != index else { return }
        hoverIndex = index
        if let tip { removeToolTip(tip); self.tip = nil }
        if index >= 0 { tip = addToolTip(rect(ofRow: index), owner: self, userData: nil) }
        hoverRow?(index)
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        outline?.tooltip(at: row(at: point), column: column(at: point)) ?? ""
    }
    @objc private func scrollDidMove() {
        guard inside, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(visibleRect.contains(point) ? row(at: point) : -1)
    }
    func refreshHover() {
        guard inside, !isHiddenOrHasHiddenAncestor else { return }
        hoverIndex = -2; scrollDidMove()
    }
    override func mouseMoved(with event: NSEvent) {
        inside = true; updateHover(row(at: convert(event.locationInWindow, from: nil)))
        super.mouseMoved(with: event)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { inside = false; updateHover(-1); super.mouseExited(with: event) }
    var makeMenu: (() -> NSMenu?)?
    var selectGesture: ((Int, SelectionMode) -> Void)?
    var selectScope: (() -> Void)?
    override func selectAll(_ sender: Any?) {
        if let selectScope { selectScope() } else { super.selectAll(sender) }
    }
    var gestureEnded: (() -> Void)?
    private(set) var trackingSelection = false
    override func menu(for event: NSEvent) -> NSMenu? {
        if event.modifierFlags.contains(.control) { return nil }
        let r = row(at: convert(event.locationInWindow, from: nil))
        guard r >= 0 else { return nil }
        if !selectedRowIndexes.contains(r) { selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
        return makeMenu?()
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = row(at: p)
        guard i >= 0, event.clickCount == 1 else { super.mouseDown(with: event); return }
        if let cell = view(atColumn: 0, row: i, makeIfNecessary: false) as? OutlineCell,
           let toggle = cell.toggle, cell.disclosureFrame.contains(cell.convert(p, from: self)) {
            toggle(event.modifierFlags.contains(.option))
            return
        }
        window?.makeFirstResponder(self)
        trackingSelection = true
        selectGesture?(i, SelectionMode(event.modifierFlags))
    }
    override func mouseDragged(with event: NSEvent) {
        if !trackingSelection { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard trackingSelection else { super.mouseUp(with: event); return }
        trackingSelection = false
        gestureEnded?()
    }
    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            let i = row(at: convert(event.locationInWindow, from: nil))
            if i >= 0 { selectGesture?(i, .toggle) }
        } else { super.rightMouseDown(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        let horizontal = event.keyCode == 123 || event.keyCode == 124
        if horizontal, event.modifierFlags.intersection([.command, .control, .shift]).isEmpty,
           outline?.navigate(right: event.keyCode == 124, recursive: event.modifierFlags.contains(.option)) == true { return }
        super.keyDown(with: event)
    }
}

private final class TreeSource {
    var model: ScanModel
    init(_ model: ScanModel) { self.model = model }
}
private final class TreeRow: NSObject {
    private let source: TreeSource
    var model: ScanModel { source.model }
    private weak var snapshot: ScanModel?
    let parent: TreeRow?
    let folder: UInt32, slot: UInt32, rank: Int, level: Int
    private var cached: DTRow

    var raw: DTRow {
        get {
            if snapshot !== model {
                var next = DTRow()
                _ = dt_entry(model.handle, folder, slot, &next)
                cached = next; snapshot = model
            }
            return cached
        }
        set { cached = newValue; snapshot = model }
    }
    init(_ raw: DTRow, folder: UInt32, rank: Int, parent: TreeRow?, source: TreeSource) {
        cached = raw; slot = raw.slot; self.folder = folder; self.parent = parent
        self.rank = rank; level = (parent?.level ?? -1) + 1
        self.source = source; snapshot = source.model
    }
    lazy var url = model.url(folder: folder, slot: slot, directory: raw.isFolder)
    lazy var title = raw.title
    private var sizeText: (UInt64, String)?
    var formattedSize: String {
        let bytes = raw.bytes
        if let sizeText, sizeText.0 == bytes { return sizeText.1 }
        let text = formatBytes(bytes); sizeText = (bytes, text); return text
    }
    var item: DiskItem { DiskItem(raw, folder: folder) }
    var key: UInt64 { UInt64(folder) << 32 | UInt64(slot) }
    var route: [DiskItem] {
        var path: [DiskItem] = []
        var current: TreeRow? = self
        while let node = current, node.key != DiskItem.scanRootKey { path.append(node.item); current = node.parent }
        return path.reversed()
    }
}

// Each run represents consecutive siblings. Only expanded branches split a run.
private struct OutlineRows {
    struct Run {
        let parent: TreeRow, start: Int, ranks: Range<Int>
    }
    private var runs: [Run] = [], byFolder: [UInt32: [Run]] = [:]
    private(set) var subtreeEnd: [UInt64: Int] = [:]
    private(set) var count = 0

    init(root: TreeRow? = nil, expanded: [UInt64: TreeRow] = [:]) {
        guard let root else { return }
        count = 1
        let branches = Dictionary(grouping: expanded.values.filter { $0.parent != nil }, by: \.folder)
        func append(_ parent: TreeRow, _ folder: UInt32, _ ranks: Range<Int>) {
            guard !ranks.isEmpty else { return }
            let run = Run(parent: parent, start: count, ranks: ranks)
            runs.append(run); byFolder[folder, default: []].append(run); count += ranks.count
        }
        func visit(_ parent: TreeRow) {
            let folder = parent.raw.child, children = dt_child_count(parent.model.handle, folder)
            var start = 0
            for child in (branches[folder] ?? []).sorted(by: { $0.rank < $1.rank }) where child.rank >= start && child.rank < children {
                append(parent, folder, start..<(child.rank + 1))
                visit(child); start = child.rank + 1
            }
            append(parent, folder, start..<children)
            subtreeEnd[parent.key] = count
        }
        if expanded[root.key] != nil { visit(root) }
    }
    private func lastRun(_ list: [Run], startingBefore value: Int, by key: (Run) -> Int) -> Run? {
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if key(list[mid]) <= value { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : list[low - 1]
    }
    func child(at row: Int) -> (parent: TreeRow, rank: Int)? {
        guard row > 0, row < count, let run = lastRun(runs, startingBefore: row, by: { $0.start }) else { return nil }
        return (run.parent, run.ranks.lowerBound + row - run.start)
    }
    func index(of node: TreeRow) -> Int {
        if node.parent == nil { return count == 0 ? -1 : 0 }
        guard let list = byFolder[node.folder], let run = lastRun(list, startingBefore: node.rank, by: { $0.ranks.lowerBound }),
              run.ranks.contains(node.rank) else { return -1 }
        return run.start + node.rank - run.ranks.lowerBound
    }
    func relocating(_ selected: IndexSet, to next: Self) -> IndexSet {
        guard !selected.isEmpty else { return [] }
        var result = IndexSet()
        if next.count > 0, selected.contains(0) { result.insert(0) }
        for run in runs {
            let indices = run.start..<(run.start + run.ranks.count)
            guard selected.intersects(integersIn: indices), let destinations = next.byFolder[run.parent.raw.child] else { continue }
            for range in selected.rangeView(of: indices) {
                let offset = run.ranks.lowerBound - run.start
                let ranks = (max(indices.lowerBound, range.lowerBound) + offset)..<(min(indices.upperBound, range.upperBound) + offset)
                for destination in destinations {
                    let overlap = ranks.clamped(to: destination.ranks)
                    if overlap.isEmpty { continue }
                    let first = destination.start + overlap.lowerBound - destination.ranks.lowerBound
                    result.insert(integersIn: first..<(first + overlap.count))
                }
            }
        }
        return result
    }
}

private final class OutlineCell: TableTextCell, FinderIconTarget {
    var finderImage: NSImage? { didSet { if finderImage !== oldValue { needsDisplay = true } } }
    var toggle: ((Bool) -> Void)?
    var expanded = false, numeric = false, level = 0
    private var value = ""
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle; return style
    }()
    private static let numberParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle(); style.alignment = .right; style.lineBreakMode = .byClipping; return style
    }()
    private static let chevrons = ["chevron.right", "chevron.down"].map {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(
            .init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [.secondaryLabelColor])))
    }
    private var indent: CGFloat { min(CGFloat(level) * 13, max(0, bounds.width - 60)) }
    var disclosureFrame: CGRect { CGRect(x: indent, y: bounds.midY - 9, width: 16, height: 18) }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { if backgroundStyle != oldValue { needsDisplay = true } } }
    override func setText(_ text: String) { value = text; needsDisplay = true }
    override func accessibilityValue() -> Any? { value }
    override func draw(_ dirtyRect: NSRect) {
        let x: CGFloat = numeric ? 3 : indent + 37
        if !numeric {
            if toggle != nil {
                let glyph = Self.chevrons[expanded ? 1 : 0]
                glyph?.draw(in: CGRect(x: indent + 3, y: floor(bounds.midY - 5), width: 10, height: 10),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            finderImage?.draw(in: CGRect(x: indent + 18, y: floor(bounds.midY - 8), width: 16, height: 16),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let text = CGRect(x: x, y: floor(bounds.midY - 8), width: max(0, bounds.width - x - 3), height: 17)
        let color: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        (value as NSString).draw(in: text, withAttributes: [.font: numeric ? TableTextCell.sizeFont : Self.font,
            .foregroundColor: color, .paragraphStyle: numeric ? Self.numberParagraph : Self.paragraph])
    }
}

private final class OutlineRowView: NSTableRowView {
    weak var outline: Outline?
    var node: TreeRow?
    var showedExpansion = false
    override func accessibilityDisclosureLevel() -> Int { node?.level ?? 0 }
    override func isAccessibilityDisclosed() -> Bool { node.map { outline?.isOpen($0) == true } ?? false }
    override func setAccessibilityDisclosed(_ disclosed: Bool) {
        if let node { outline?.setOpen(node, disclosed) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard let node, let outline, node.raw.isFolder, dt_child_count(node.model.handle, node.raw.child) > 0 else { return super.accessibilityPerformPress() }
        outline.setOpen(node, !outline.isOpen(node)); return true
    }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityDisclosed(_:)) { return node?.raw.isFolder == true }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}

final class Outline: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = FileOutlineView()
    var hovered: ((URL?, DTKey?) -> Void)?
    var selectionChanged: (() -> Void)?
    var openFolder: (([DiskItem]) -> Void)?
    private var source: TreeSource?
    private var model: ScanModel? { source?.model }
    private var materialized = Set<UInt32>()
    private let recentRows = NSCache<NSNumber, TreeRow>()
    private var rootRow: TreeRow?
    private var expanded: [UInt64: TreeRow] = [:]
    private var rows = OutlineRows()
    private var anchor: TreeRow?
    private var applyingSelection = false
    let icons = FinderIcons()

    override init() {
        super.init()
        recentRows.countLimit = 1024
        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Name"; name.minWidth = 72; name.width = 260
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Size"; size.headerToolTip = "Allocated size on disk"
        size.minWidth = max(78, TableTextCell.sizeColumnMinimum); size.width = max(95, size.minWidth)
        name.headerCell.alignment = .left; size.headerCell.alignment = .right
        view.addTableColumn(name); view.addTableColumn(size)
        view.outline = self
        view.rowHeight = 25
        view.usesAutomaticRowHeights = false
        view.allowsMultipleSelection = true
        view.allowsEmptySelection = true
        view.allowsColumnReordering = false
        view.delegate = self; view.dataSource = self
        view.target = self; view.doubleAction = #selector(openClicked)
        view.setAccessibilityLabel("File tree, largest first")
        view.setAccessibilityRole(.outline)
        view.hoverRow = { [weak self] index in
            guard let self else { return }
            guard index >= 0, let row = self.node(at: index) else { self.hovered?(nil, nil); return }
            self.hovered?(row.url, DTKey(folder: row.folder, slot: row.raw.slot))
        }
        view.selectGesture = { [weak self] row, mode in
            guard let self, let node = self.node(at: row) else { return }
            self.select([node.route], mode: mode)
        }
    }

    func clear() {
        source = nil; anchor = nil
        materialized.removeAll(); recentRows.removeAllObjects(); rootRow = nil; expanded.removeAll(); rows = OutlineRows(); icons.reset()
        view.reloadData()
    }

    func show(_ newModel: ScanModel, refresh: Bool) {
        let same = model === newModel
        guard !same || refresh else { return }
        let open = same ? expanded.values.filter { rows.index(of: $0) >= 0 }.map(\.key) : [DiskItem.scanRootKey]
        icons.reset(); source = TreeSource(newModel); materialized.removeAll()
        anchor = nil; recentRows.removeAllObjects(); rootRow = nil; expanded.removeAll()
        updateRoot(in: newModel)
        for key in open {
            if let route = newModel.route(to: DTKey(key), from: 0), let node = resolve(route, reveal: false) {
                expanded[key] = node; materialized.insert(node.raw.child)
            } else if key == DiskItem.scanRootKey, let rootRow {
                expanded[key] = rootRow; materialized.insert(0)
            }
        }
        rows = OutlineRows(root: rootRow, expanded: expanded)
        view.reloadData()
        view.deselectAll(nil)
    }

    func showLive(_ next: ScanModel, keys: [UInt64], lead: UInt64?) {
        guard let old = model else { show(next, refresh: false); return }
        if old === next {
            if selectedKeys() != Set(keys) { selectSaved(keys, lead: lead, scroll: false) }
            return
        }
        let sameOrder = Array(materialized).withUnsafeBufferPointer {
            dt_outline_order_unchanged(old.handle, next.handle, $0.baseAddress, $0.count)
        }
        if sameOrder {
            var changed: [(Int, UInt64, TreeRow)] = []
            view.enumerateAvailableRowViews { _, i in
                if i >= 0, let node = self.node(at: i) { changed.append((i, node.raw.bytes, node)) }
            }
            let expandabilityChanged = changed.compactMap { (_, _, node) -> TreeRow? in
                let child = node.raw.child
                guard child != .max, (dt_child_count(old.handle, child) == 0) != (dt_child_count(next.handle, child) == 0) else { return nil }
                return node
            }
            source?.model = next
            for node in expandabilityChanged { updateVisibleRow(rows.index(of: node)) }
            let visible = view.visibleRows
            for (i, before, node) in changed where node.raw.bytes != before {
                let col = view.column(withIdentifier: .init("size"))
                let cell = view.view(atColumn: col, row: i, makeIfNecessary: false) as? TableTextCell
                cell?.setText(formatBytes(node.raw.bytes))
                if visible.contains(i) { cell?.highlightChange(from: before, to: node.raw.bytes) }
            }
            if selectedKeys() != Set(keys) { selectSaved(keys, lead: lead, scroll: false) }
            return
        }
        let open = expanded.values.compactMap { row -> URL? in
            guard rows.index(of: row) >= 0, isOpen(row) else { return nil }
            return old.url(folder: row.folder, slot: row.raw.slot, directory: true)
        }
        var origin = view.visibleRect.origin
        let visible = view.visibleRows
        let pin = visible.first(where: { view.isRowSelected($0) }) ?? visible.first
        var scrollAnchor: (url: URL, offset: CGFloat)?
        var previous = [URL: UInt64]()
        for i in visible {
            if let row = node(at: i), let url = old.url(folder: row.folder, slot: row.raw.slot, directory: row.raw.isFolder) {
                previous[url] = row.raw.bytes
                if i == pin { scrollAnchor = (url, view.rect(ofRow: i).minY - origin.y) }
            }
        }
        applyingSelection = true
        source = TreeSource(next); materialized.removeAll(keepingCapacity: true)
        anchor = nil; recentRows.removeAllObjects(); rootRow = nil; expanded.removeAll(keepingCapacity: true)
        updateRoot(in: next)
        if old.isScanPreview, dt_child_count(old.handle, 0) == 0, let rootRow {
            expanded[rootRow.key] = rootRow; materialized.insert(0)
        }
        for url in open {
            guard let route = next.route(to: url), let node = resolve(route, reveal: false), node.raw.isFolder else { continue }
            var branch: TreeRow? = node
            while let row = branch, !isOpen(row) {
                expanded[row.key] = row; materialized.insert(row.raw.child); branch = row.parent
            }
        }
        rows = OutlineRows(root: rootRow, expanded: expanded)
        view.reloadData()
        selectSaved(keys, lead: lead, scroll: false)
        if let scrollAnchor, let route = next.route(to: scrollAnchor.url), let node = resolve(route) {
            let row = rows.index(of: node)
            if row >= 0 { origin.y = view.rect(ofRow: row).minY - scrollAnchor.offset }
        }
        view.scroll(origin)
        for i in view.visibleRows {
            guard let row = node(at: i),
                  let url = next.url(folder: row.folder, slot: row.raw.slot, directory: row.raw.isFolder) else { continue }
            let prior = previous[url] ?? old.route(to: url)?.last?.bytes
            let bytes = row.raw.bytes
            if prior != bytes, let cell = view.view(atColumn: view.column(withIdentifier: .init("size")), row: i, makeIfNecessary: true) as? TableTextCell {
                cell.setText(formatBytes(bytes)); cell.highlightChange(from: prior, to: bytes)
            }
        }
    }

    private func updateRoot(in model: ScanModel) {
        var row = DTRow()
        if dt_entry(model.handle, 0, .max, &row) { rootRow = object(row, folder: 0, rank: 0, parent: nil) }
    }
    private func known(_ key: UInt64) -> TreeRow? {
        if key == DiskItem.scanRootKey { return rootRow }
        return expanded[key] ?? recentRows.object(forKey: NSNumber(value: key))
    }
    private func object(_ raw: DTRow, folder: UInt32, rank: Int, parent: TreeRow?) -> TreeRow {
        let key = UInt64(folder) << 32 | UInt64(raw.slot)
        if let already = known(key) { already.raw = raw; return already }
        materialized.insert(folder)
        let node = TreeRow(raw, folder: folder, rank: rank, parent: parent, source: source!)
        recentRows.setObject(node, forKey: NSNumber(value: key))
        return node
    }
    private func resolve(_ route: [DiskItem], reveal: Bool = true) -> TreeRow? {
        guard let model, let rootRow else { return nil }
        if route.isEmpty { return rootRow }
        var parent: TreeRow? = rootRow
        var toOpen: [TreeRow] = []
        for item in route {
            if reveal, let parent, !isOpen(parent) { toOpen.append(parent) }
            let row: TreeRow
            if let found = known(item.key) { row = found }
            else {
                var raw = DTRow()
                guard dt_entry(model.handle, item.folder, item.slot, &raw) else { return nil }
                let rank = dt_child_rank(model.handle, item.folder, item.slot)
                guard rank >= 0 else { return nil }
                row = object(raw, folder: item.folder, rank: rank, parent: parent)
            }
            parent = row
        }
        if !toOpen.isEmpty {
            for row in toOpen { expanded[row.key] = row; materialized.insert(row.raw.child) }
            applyExpansion()
        }
        return parent
    }
    func reveal(_ route: [DiskItem]) { select([route], mode: .replace) }
    func expand(_ route: [DiskItem]) {
        if let node = resolve(route), !isOpen(node) { setOpen(node, true) }
    }
    func selectAll(in route: [DiskItem]) {
        applyingSelection = true
        defer { applyingSelection = false }
        guard let node = resolve(route) else { return }
        setOpen(node, true)
        let parent = rows.index(of: node)
        guard parent >= 0 else { return }
        let first = parent + 1, end = rows.subtreeEnd[node.key] ?? first
        view.selectRowIndexes(IndexSet(integersIn: first..<end), byExtendingSelection: false)
        anchor = first < end ? self.node(at: first) : nil
        selectionChanged?()
    }
    var selectedFolderRoute: [DiskItem]? {
        guard view.numberOfSelectedRows == 1, let row = node(at: view.selectedRow), row.raw.isFolder else { return nil }
        return row.route
    }
    var leadKey: UInt64? { anchor?.key }
    func selectSaved(_ keys: [UInt64], lead: UInt64?, scroll: Bool = true) {
        guard let model else { return }
        applyingSelection = true
        defer { applyingSelection = false }
        let nodes = keys.compactMap { key -> TreeRow? in
            if let known = known(key), rows.index(of: known) >= 0 { return known }
            return model.route(to: DTKey(key), from: 0).flatMap { self.resolve($0) }
        }
        let indexes = IndexSet(nodes.map { rows.index(of: $0) }.filter { $0 >= 0 })
        view.selectRowIndexes(indexes, byExtendingSelection: false)
        anchor = lead.flatMap { known($0) }.flatMap { node in
            let row = rows.index(of: node)
            return row >= 0 && indexes.contains(row) ? node : nil
        }
            ?? indexes.first.flatMap { node(at: $0) }
        if scroll, let anchor { view.scrollRowToVisible(rows.index(of: anchor)) }
        selectionChanged?()
    }
    var expandedURLs: [URL] {
        expanded.values.compactMap { rows.index(of: $0) >= 0 ? $0.model.url(folder: $0.folder, slot: $0.slot, directory: true) : nil }
    }
    func selectFromChart(_ routes: [[DiskItem]], mode: SelectionMode) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            select(routes, mode: mode)
        }
    }

    func select(_ routes: [[DiskItem]], mode: SelectionMode) {
        applyingSelection = true
        defer { applyingSelection = false }
        let nodes = routes.compactMap { resolve($0) }
        let indexes = IndexSet(nodes.map { rows.index(of: $0) }.filter { $0 >= 0 })
        var result = view.selectedRowIndexes
        switch mode {
        case .replace: result = indexes
        case .toggle: result.formSymmetricDifference(indexes)
        case .range, .addRange:
            guard let last = indexes.last else { return }
            let a = anchor.map { rows.index(of: $0) } ?? -1
            let start = a >= 0 ? a : last
            let range = IndexSet(integersIn: min(start, last)...max(start, last))
            if mode == .range { result = range } else { result.formUnion(range) }
        }
        if result != view.selectedRowIndexes { view.selectRowIndexes(result, byExtendingSelection: false) }
        if mode != .range && mode != .addRange { anchor = nodes.last }
        if let node = nodes.last {
            let i = rows.index(of: node)
            if i >= 0 { view.scrollRowToVisible(i) }
        }
        selectionChanged?()
    }
    func isSelected(_ key: UInt64) -> Bool {
        guard let node = known(key) ?? model?.route(to: DTKey(key), from: 0).flatMap({ resolve($0, reveal: false) }) else { return false }
        let i = rows.index(of: node)
        return i >= 0 && view.selectedRowIndexes.contains(i)
    }
    var firstSelected: DiskItem? { (node(at: view.selectedRow))?.item }
    var selectedChildKey: UInt64? {
        guard view.numberOfSelectedRows == 1, let row = node(at: view.selectedRow), row.parent != nil else { return nil }
        return row.key
    }
    func selectedKeys() -> Set<UInt64> {
        Set(view.selectedRowIndexes.compactMap { (node(at: $0))?.key })
    }
    func selectedIDs() -> [DTKey] {
        view.selectedRowIndexes.compactMap { index in
            guard let row = node(at: index) else { return nil }
            return DTKey(folder: row.folder, slot: row.raw.slot)
        }
    }
    func selectedItems(rootsOnly: Bool = false) -> [DiskItem] {
        let rows = view.selectedRowIndexes.compactMap { node(at: $0) }
        guard rootsOnly && rows.count > 1 else { return rows.map(\.item) }
        let selected = Set(rows.map(\.key))
        return rows.compactMap { row in
            var parent = row.parent
            while let node = parent {
                if selected.contains(node.key) { return nil }
                parent = node.parent
            }
            return row.item
        }
    }
    @objc private func openClicked() {
        guard let row = node(at: view.clickedRow), row.raw.isFolder else { return }
        openFolder?(row.route)
    }

    private func node(at index: Int) -> TreeRow? {
        if index == 0 { return rootRow }
        guard let position = rows.child(at: index), let model else { return nil }
        let folder = position.parent.raw.child
        var raw = DTRow()
        guard dt_child(model.handle, folder, position.rank, &raw) else { return nil }
        return object(raw, folder: folder, rank: position.rank, parent: position.parent)
    }
    fileprivate func isOpen(_ node: TreeRow) -> Bool { expanded[node.key] != nil }
    fileprivate func setOpen(_ node: TreeRow, _ open: Bool, recursive: Bool = false) {
        guard node.raw.isFolder, isOpen(node) != open || recursive else { return }
        let index = rows.index(of: node)
        guard index >= 0 else { return }
        func change(_ branch: TreeRow) {
            let folder = branch.raw.child
            if open {
                expanded[branch.key] = branch; materialized.insert(folder)
                if recursive {
                    for rank in 0..<dt_child_count(branch.model.handle, folder) {
                        var raw = DTRow()
                        if dt_child(branch.model.handle, folder, rank, &raw), raw.isFolder,
                           dt_child_count(branch.model.handle, raw.child) > 0 {
                            change(object(raw, folder: folder, rank: rank, parent: branch))
                        }
                    }
                }
            } else {
                expanded[branch.key] = nil
                if recursive {
                    for child in expanded.values.filter({ $0.parent?.key == branch.key }) { change(child) }
                }
            }
        }
        change(node)
        applyExpansion(collapsing: open ? nil : node)
        if let row = view.rowView(atRow: index, makeIfNecessary: false) {
            NSAccessibility.post(element: row, notification: open ? .rowExpanded : .rowCollapsed)
        }
    }
    private func applyExpansion(collapsing node: TreeRow? = nil) {
        let previous = view.selectedRowIndexes, wasApplying = applyingSelection
        let next = OutlineRows(root: rootRow, expanded: expanded)
        let increases = next.count >= rows.count
        var selection = rows.relocating(previous, to: next)
        let lostSelection = selection.count != previous.count
        rows = next
        if let node, lostSelection {
            if selection.isEmpty { selection.insert(rows.index(of: node)); anchor = node }
            else if let old = anchor, rows.index(of: old) < 0 { anchor = selection.first.flatMap { self.node(at: $0) } }
        }
        applyingSelection = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            if increases {
                view.noteNumberOfRowsChanged()
                view.enumerateAvailableRowViews { view, i in
                    guard let row = view as? OutlineRowView, let node = self.node(at: i) else { return }
                    if row.node !== node || row.showedExpansion != self.isOpen(node) { self.updateVisibleRow(i) }
                }
            } else { view.reloadData() }
            if view.selectedRowIndexes != selection { view.selectRowIndexes(selection, byExtendingSelection: false) }
        }
        applyingSelection = wasApplying
        if lostSelection && !wasApplying { selectionChanged?() }
        view.refreshHover()
    }
    fileprivate func navigate(right: Bool, recursive: Bool) -> Bool {
        guard let row = node(at: view.selectedRow) else { return false }
        if recursive || right != isOpen(row) {
            if row.raw.isFolder, dt_child_count(row.model.handle, row.raw.child) > 0 {
                setOpen(row, right, recursive: recursive); return true
            }
        }
        if right {
            let i = rows.index(of: row) + 1
            if isOpen(row), i < rows.count, let child = node(at: i), child.parent?.key == row.key { reveal(child.route) }
        } else if let parent = row.parent { reveal(parent.route) }
        return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        if view.numberOfSelectedRows == 1 { anchor = node(at: view.selectedRow) }
        selectionChanged?()
    }
    func tableView(_ tableView: NSTableView, typeSelectStringFor column: NSTableColumn?, row: Int) -> String? {
        node(at: row)?.raw.title
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("outlineRow")
        let result = tableView.makeView(withIdentifier: id, owner: self) as? OutlineRowView ?? OutlineRowView()
        result.identifier = id; result.outline = self; result.node = node(at: row)
        result.showedExpansion = result.node.map(isOpen) ?? false
        return result
    }
    fileprivate func tooltip(at index: Int, column: Int) -> String? {
        guard let node = node(at: index) else { return nil }
        return column == 0 ? node.url?.path : node.formattedSize
    }
    private func configure(_ cell: OutlineCell, _ node: TreeRow) {
        if cell.numeric { cell.setText(node.formattedSize); return }
        let raw = node.raw, expandable = raw.isFolder && dt_child_count(node.model.handle, raw.child) > 0
        cell.level = node.level; cell.expanded = isOpen(node)
        cell.toggle = expandable ? { [weak self] recursive in
            guard let self else { return }
            self.setOpen(node, !self.isOpen(node), recursive: recursive)
        } : nil
        icons.display(node.url, in: cell, row: raw)
        cell.setText(node.title)
    }
    private func updateVisibleRow(_ index: Int) {
        guard index >= 0, let node = node(at: index) else { return }
        if let row = view.rowView(atRow: index, makeIfNecessary: false) as? OutlineRowView {
            row.node = node; row.showedExpansion = isOpen(node)
        }
        for column in 0..<view.numberOfColumns {
            if let cell = view.view(atColumn: column, row: index, makeIfNecessary: false) as? OutlineCell { configure(cell, node) }
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let node = node(at: index), let id = tableColumn?.identifier else { return nil }
        let cell = view.makeView(withIdentifier: id, owner: self) as? OutlineCell ?? OutlineCell(frame: .zero)
        if cell.identifier == nil {
            cell.identifier = id; cell.numeric = id.rawValue == "size"
            cell.setAccessibilityElement(true); cell.setAccessibilityRole(.cell)
        }
        configure(cell, node); return cell
    }
}
