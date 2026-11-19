import AppKit

enum SelectionMode {
    case replace, toggle, range, addRange, add
    init(_ flags: NSEvent.ModifierFlags) {
        let additive = flags.contains(.control) || flags.contains(.command)
        if flags.contains(.shift) { self = additive ? .addRange : .range }
        else { self = additive ? .toggle : .replace }
    }
}

final class FileOutlineView: NSOutlineView {
    var hoverRow: ((Int) -> Void)?
    private var hoverTracking: NSTrackingArea?
    private var hoverIndex = -1
    private var inside = false
    private var columnSpace: CGFloat = -1
    override func layout() {
        super.layout()
        guard let width = enclosingScrollView?.contentView.bounds.width, width > 0,
              width != columnSpace, tableColumns.count == 2 else { return }
        columnSpace = width
        let overhead = max(0, rect(ofColumn: 1).maxX - tableColumns[0].width - tableColumns[1].width)
        tableColumns[0].width = max(tableColumns[0].minWidth, width - tableColumns[1].width - overhead - 3)
        frame.size.width = width
    }
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
        hoverRow?(index)
    }
    @objc private func scrollDidMove() {
        guard inside, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(visibleRect.contains(point) ? row(at: point) : -1)
    }
    override func mouseMoved(with event: NSEvent) {
        inside = true; updateHover(row(at: convert(event.locationInWindow, from: nil)))
        super.mouseMoved(with: event)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { inside = false; updateHover(-1); super.mouseExited(with: event) }
    var makeMenu: (() -> NSMenu?)?
    var selectGesture: ((Int, SelectionMode) -> Void)?
    private var dragOrigin = -1
    private var dragBase = IndexSet()
    private var dragMode = SelectionMode.replace
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
        guard i >= 0, event.clickCount == 1, !frameOfOutlineCell(atRow: i).contains(p) else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        dragMode = SelectionMode(event.modifierFlags)
        dragBase = selectedRowIndexes
        dragOrigin = i
        selectGesture?(i, dragMode)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragOrigin >= 0 else { super.mouseDragged(with: event); return }
        autoscroll(with: event)
        let i = row(at: convert(event.locationInWindow, from: nil))
        guard i >= 0 else { return }
        let span = IndexSet(integersIn: min(i, dragOrigin)...max(i, dragOrigin))
        let result: IndexSet
        switch dragMode {
        case .toggle: result = dragBase.symmetricDifference(span)
        case .add, .addRange: result = dragBase.union(span)
        default: result = span
        }
        selectRowIndexes(result, byExtendingSelection: false)
    }
    override func mouseUp(with event: NSEvent) {
        if dragOrigin < 0 { super.mouseUp(with: event) }
        dragOrigin = -1
        dragBase.removeAll()
    }
    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            let i = row(at: convert(event.locationInWindow, from: nil))
            if i >= 0 { selectGesture?(i, .toggle) }
        } else { super.rightMouseDown(with: event) }
    }
}

private final class TreeRow: NSObject {
    let model: ScanModel
    weak var parent: TreeRow?
    let folder: UInt32
    var raw: DTRow
    init(_ raw: DTRow, folder: UInt32, parent: TreeRow?, model: ScanModel) {
        self.raw = raw; self.folder = folder; self.parent = parent; self.model = model
    }
    var item: DiskItem { DiskItem(raw, folder: folder) }
    var key: UInt64 { UInt64(folder) << 32 | UInt64(raw.slot) }
    var route: [DiskItem] {
        var path: [DiskItem] = []
        var current: TreeRow? = self
        while let node = current { path.append(node.item); current = node.parent }
        return path.reversed()
    }
}

final class Outline: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let view = FileOutlineView()
    var hovered: ((URL?, DTKey?) -> Void)?
    var selectionChanged: (() -> Void)?
    var openFolder: (([DiskItem]) -> Void)?
    private var model: ScanModel?
    private var objects: [UInt64: TreeRow] = [:]
    private var expanded: [UInt64: TreeRow] = [:]
    private var anchor: TreeRow?
    private var applyingSelection = false
    private let icons = FinderIcons()

    override init() {
        super.init()
        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Name"; name.minWidth = 115; name.width = 260
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Allocated"; size.minWidth = 78; size.width = 95; size.maxWidth = 145
        view.addTableColumn(name); view.addTableColumn(size)
        view.outlineTableColumn = name
        view.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        view.indentationPerLevel = 13
        view.style = .inset
        view.rowHeight = 25
        view.usesAutomaticRowHeights = false
        view.allowsMultipleSelection = true
        view.allowsEmptySelection = true
        view.allowsColumnReordering = false
        view.delegate = self; view.dataSource = self
        view.target = self; view.doubleAction = #selector(openClicked)
        view.setAccessibilityLabel("File tree, largest first")
        view.hoverRow = { [weak self] index in
            guard let self else { return }
            guard index >= 0, let row = self.view.item(atRow: index) as? TreeRow else { self.hovered?(nil, nil); return }
            let url = row.model.url(folder: row.folder, slot: row.raw.slot, directory: row.raw.isFolder)
            self.hovered?(url, DTKey(folder: row.folder, slot: row.raw.slot))
        }
        view.selectGesture = { [weak self] row, mode in
            guard let self, let node = self.view.item(atRow: row) as? TreeRow else { return }
            self.select([node.route], mode: mode)
        }
    }

    func show(_ newModel: ScanModel, refresh: Bool) {
        if refresh || model !== newModel { icons.reset() }
        if model !== newModel {
            model = newModel
            anchor = nil
            objects.removeAll(); expanded.removeAll()
            view.reloadData()
            view.deselectAll(nil)
            return
        }
        guard refresh else { return }
        let old = expanded.values.sorted { view.level(forItem: $0) < view.level(forItem: $1) }
        view.reloadData()
        for node in old {
            var raw = DTRow()
            if dt_entry(newModel.handle, node.folder, node.raw.slot, &raw) {
                node.raw = raw
                if !view.isItemExpanded(node) { view.expandItem(node) }
            } else { expanded.removeValue(forKey: node.key) }
        }
        view.deselectAll(nil)
    }

    private func object(_ raw: DTRow, folder: UInt32, parent: TreeRow?, model: ScanModel) -> TreeRow {
        let key = UInt64(folder) << 32 | UInt64(raw.slot)
        if let already = objects[key] { already.raw = raw; return already }
        let node = TreeRow(raw, folder: folder, parent: parent, model: model)
        objects[key] = node
        return node
    }
    private func resolve(_ route: [DiskItem]) -> TreeRow? {
        guard let model, !route.isEmpty else { return nil }
        var parent: TreeRow?
        for (i, item) in route.enumerated() {
            let row: TreeRow
            if let found = objects[item.key] { row = found }
            else {
                var raw = DTRow()
                guard dt_entry(model.handle, item.folder, item.slot, &raw) else { return nil }
                row = object(raw, folder: item.folder, parent: parent, model: model)
            }
            if i < route.count - 1 && !view.isItemExpanded(row) { view.expandItem(row) }
            parent = row
        }
        return parent
    }
    func reveal(_ route: [DiskItem]) { select([route], mode: .replace) }
    var expandedURLs: [URL] {
        expanded.values.compactMap { $0.model.url(folder: $0.folder, slot: $0.raw.slot, directory: true) }
    }
    func restore(expansions: [[DiskItem]], selections: [[DiskItem]]) {
        for path in expansions { if let row = resolve(path) { view.expandItem(row) } }
        select(selections, mode: .replace)
    }
    func select(_ routes: [[DiskItem]], mode: SelectionMode) {
        applyingSelection = true
        defer { applyingSelection = false }
        let nodes = routes.compactMap(resolve)
        let indexes = IndexSet(nodes.map { view.row(forItem: $0) }.filter { $0 >= 0 })
        var result = view.selectedRowIndexes
        switch mode {
        case .replace: result = indexes
        case .add: result.formUnion(indexes)
        case .toggle: result.formSymmetricDifference(indexes)
        case .range, .addRange:
            guard let last = indexes.last else { return }
            let a = anchor.map { view.row(forItem: $0) } ?? -1
            let start = a >= 0 ? a : last
            let range = IndexSet(integersIn: min(start, last)...max(start, last))
            if mode == .range { result = range } else { result.formUnion(range) }
        }
        view.selectRowIndexes(result, byExtendingSelection: false)
        if mode != .range && mode != .addRange { anchor = nodes.last }
        if let node = nodes.last {
            let i = view.row(forItem: node)
            if i >= 0 { view.scrollRowToVisible(i) }
        }
        selectionChanged?()
    }
    func isSelected(_ key: UInt64) -> Bool {
        guard let node = objects[key] else { return false }
        let i = view.row(forItem: node)
        return i >= 0 && view.selectedRowIndexes.contains(i)
    }
    var firstSelected: DiskItem? { (view.item(atRow: view.selectedRow) as? TreeRow)?.item }
    func selectedKeys() -> Set<UInt64> {
        Set(view.selectedRowIndexes.compactMap { (view.item(atRow: $0) as? TreeRow)?.key })
    }
    func selectedIDs() -> [DTKey] {
        view.selectedRowIndexes.compactMap { index in
            guard let row = view.item(atRow: index) as? TreeRow else { return nil }
            return DTKey(folder: row.folder, slot: row.raw.slot)
        }
    }
    func selectedItems(rootsOnly: Bool = false) -> [DiskItem] {
        let rows = view.selectedRowIndexes.compactMap { view.item(atRow: $0) as? TreeRow }
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
        guard let row = view.item(atRow: view.clickedRow) as? TreeRow, row.raw.isFolder else { return }
        openFolder?(row.route)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let model else { return 0 }
        if let node = item as? TreeRow { return node.raw.isFolder ? dt_child_count(model.handle, node.raw.child) : 0 }
        return dt_child_count(model.handle, 0)
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TreeRow, node.raw.isFolder, let model else { return false }
        return dt_child_count(model.handle, node.raw.child) > 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let model else { return NSNull() }
        let parent = item as? TreeRow
        let folder = parent?.raw.child ?? 0
        var raw = DTRow()
        guard dt_child(model.handle, folder, index, &raw) else { return NSNull() }
        return object(raw, folder: folder, parent: parent, model: model)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? TreeRow { expanded[row.key] = row }
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? TreeRow { expanded.removeValue(forKey: row.key) }
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        if view.numberOfSelectedRows == 1 { anchor = view.item(atRow: view.selectedRow) as? TreeRow }
        selectionChanged?()
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? TreeRow)?.raw.title
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? TreeRow, let id = tableColumn?.identifier else { return nil }
        let isName = id.rawValue == "name"
        let cell: NSTableCellView
        if let reused = view.makeView(withIdentifier: id, owner: self) as? NSTableCellView { cell = reused }
        else {
            cell = NSTableCellView(); cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label; cell.addSubview(label)
            var leading = cell.leadingAnchor
            if isName {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon); cell.imageView = icon
                NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16)])
                leading = icon.trailingAnchor
            } else {
                label.alignment = .right
                label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            }
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leading, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        cell.textField?.stringValue = isName ? row.raw.title : formatBytes(row.raw.bytes)
        if isName {
            let url = row.model.url(folder: row.folder, slot: row.raw.slot, directory: row.raw.isFolder)
            if let image = cell.imageView { icons.display(url, in: image, row: row.raw) }
            cell.toolTip = url?.path
        }
        return cell
    }
}
