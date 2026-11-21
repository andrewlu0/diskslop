import AppKit

struct RankedFile {
    let url: URL, bytes: UInt64, key: UInt64?
    static func read(_ ranking: OpaquePointer) -> [Self] {
        defer { dt_ranked_free(ranking) }
        return (0..<dt_ranked_count(ranking)).compactMap { i in
            var bytes: UInt64 = 0, key = DTKey()
            guard let raw = dt_ranked_file(ranking, i, &bytes, &key) else { return nil }
            let url = URL(fileURLWithFileSystemRepresentation: raw, isDirectory: false, relativeTo: nil)
            return Self(url: url, bytes: bytes, key: key.folder == .max ? nil : UInt64(key.folder) << 32 | UInt64(key.slot))
        }
    }
}

final class RankedTable: NSTableView {
    var makeMenu: (() -> NSMenu?)?
    var hovered: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) { hovered?(row(at: convert(event.locationInWindow, from: nil))); super.mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered?(-1); super.mouseExited(with: event) }
    func refreshHover() {
        guard !isHiddenOrHasHiddenAncestor, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(point) { hovered?(row(at: point)) }
    }
    private var trackingClick = false
    private var rangeAnchor: Int?
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, event.clickCount == 1 else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        trackingClick = true
        let mode = SelectionMode(event.modifierFlags)
        switch mode {
        case .replace:
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            rangeAnchor = index
        case .toggle:
            if isRowSelected(index) { deselectRow(index) }
            else { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true) }
            rangeAnchor = index
        case .range, .addRange:
            let start = rangeAnchor.flatMap { isRowSelected($0) ? $0 : nil } ?? (selectedRow >= 0 ? selectedRow : index)
            selectRowIndexes(IndexSet(integersIn: min(start, index)...max(start, index)), byExtendingSelection: mode == .addRange)
            rangeAnchor = start
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if !trackingClick { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if trackingClick { trackingClick = false } else { super.mouseUp(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        if event.modifierFlags.contains(.control) {
            if selectedRowIndexes.contains(index) { deselectRow(index) } else { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true) }
            rangeAnchor = index
            return nil
        }
        if !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return makeMenu?()
    }
}

final class LargestFiles: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = RankedTable()
    lazy var view = NativeTableSurface(table, preferencesName: "LargestFiles")
    var selectionChanged: (() -> Void)?
    var openFile: (() -> Void)?
    private(set) var rows: [RankedFile] = []
    private let icons = FinderIcons()
    private var updating = false

    override init() {
        super.init()
        let name = NSTableColumn(identifier: .init("name")), size = NSTableColumn(identifier: .init("size"))
        name.title = "Name"; name.minWidth = 65
        size.title = "Size"; size.minWidth = max(78, TableTextCell.sizeColumnMinimum); size.width = size.minWidth
        size.resizingMask = [.userResizingMask]; size.headerCell.alignment = .right; size.headerToolTip = "Allocated size on disk"
        [name, size].forEach(table.addTableColumn)
        table.rowHeight = 25; table.allowsMultipleSelection = true
        table.allowsColumnReordering = false; table.usesAutomaticRowHeights = false
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(open)
        table.setAccessibilityLabel("Largest files, ranked by allocated size")
    }
    var selected: [RankedFile] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    var singleSelection: RankedFile? {
        guard table.numberOfSelectedRows == 1, rows.indices.contains(table.selectedRow) else { return nil }
        return rows[table.selectedRow]
    }
    func replace(_ next: [RankedFile], keeping selection: Set<URL>? = nil, live: Bool = false) {
        if live, selection == nil, rows.count == next.count, zip(rows, next).allSatisfy({ $0.url == $1.url }) {
            let previous = rows, visible = table.visibleRows
            rows = next
            let size = table.column(withIdentifier: .init("size"))
            table.enumerateAvailableRowViews { _, i in
                guard next.indices.contains(i), previous[i].bytes != next[i].bytes,
                      let cell = self.table.view(atColumn: size, row: i, makeIfNecessary: false) as? TableTextCell else { return }
                cell.setText(formatBytes(next[i].bytes)); cell.toolTip = next[i].url.path
                if visible.contains(i) { cell.highlightChange(from: previous[i].bytes, to: next[i].bytes) }
            }
            return
        }
        let urls = selection ?? Set(selected.map(\.url))
        let previous = live ? Dictionary(rows.map { ($0.url, $0.bytes) }, uniquingKeysWith: { first, _ in first }) : [:]
        let origin = table.visibleRect.origin
        updating = true
        rows = next
        table.reloadData()
        table.selectRowIndexes(IndexSet(next.indices.filter { urls.contains(next[$0].url) }), byExtendingSelection: false)
        updating = false
        if live {
            table.scroll(origin)
            for i in table.visibleRows { table.highlight("size", row: i, previous: previous[next[i].url], current: next[i].bytes) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let id = column?.identifier, rows.indices.contains(row) else { return nil }
        let file = rows[row], name = id.rawValue == "name", size = id.rawValue == "size"
        let cell = TableTextCell.make(in: table, column: id, icon: name, numeric: size)
        cell.setText(name ? file.url.lastPathComponent : formatBytes(file.bytes))
        cell.toolTip = file.url.path
        if let image = cell.imageView, name {
            var item = DTRow(); item.child = .max
            icons.display(file.url, in: image, row: item)
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updating { selectionChanged?() }
    }
    @objc private func open() { openFile?() }
}
