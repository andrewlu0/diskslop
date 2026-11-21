import AppKit

private final class LegendRow: NSTableRowView {
    var followed = false { didSet { if oldValue != followed { needsDisplay = true } } }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard followed else { return }
        NSColor.labelColor.withAlphaComponent(effectiveAppearance.usesDarkColors ? 0.12 : 0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

private final class KindMarkerCell: NSTableCellView {
    private let marker = NSImageView()
    private var kind: FileKind?
    private static var icons = [String: NSImage]()
    private static let markers: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()
    private static let markerSize = NSSize(width: 30, height: 17)
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(marker)
        marker.translatesAutoresizingMaskIntoConstraints = false
        marker.imageScaling = .scaleNone
        NSLayoutConstraint.activate([
            marker.widthAnchor.constraint(equalToConstant: Self.markerSize.width),
            marker.heightAnchor.constraint(equalToConstant: Self.markerSize.height),
            marker.centerXAnchor.constraint(equalTo: centerXAnchor), marker.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ next: FileKind) {
        kind = next
        toolTip = next.title
        updateColor()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }
    private func updateColor() {
        guard let kind else { return }
        let rgb = kind.fill(darkMode: effectiveAppearance.usesDarkColors)
        let key = "\(kind.glyph)-\(rgb)" as NSString
        if let image = Self.markers.object(forKey: key) { marker.image = image; return }
        if Self.icons[kind.glyph] == nil,
            let url = Bundle.main.url(forResource: kind.glyph, withExtension: "svg", subdirectory: "KindIcons") {
            Self.icons[kind.glyph] = NSImage(contentsOf: url)
        }
        let icon = Self.icons[kind.glyph], tint = NSColor(rgb: rgb)
        let image = NSImage(size: Self.markerSize, flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 1, width: 8, height: 15), xRadius: 2, yRadius: 2).fill()
            icon?.draw(in: NSRect(x: 13, y: 0, width: 17, height: 17))
            tint.setFill()
            rect.fill(using: .sourceIn)
            cg.endTransparencyLayer()
            return true
        }
        Self.markers.setObject(image, forKey: key)
        marker.image = image
    }
}

final class KindLegend: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let leadingInset: CGFloat = 6
    private let background: NSView
    private let title = NSTextField(labelWithString: "Color by")
    private let picker = NSPopUpButton()
    private let activity = NSProgressIndicator()
    var modeChanged: ((MapColorMode) -> Void)?
    var focusChanged: ((LegendFocus?, UInt32?, MapBreakdown?) -> Void)?
    private(set) var focus: LegendFocus?
    private var focusedID: UInt32?
    private var updatingSelection = false
    private let table = NSTableView()
    private lazy var scroll = FittingTableScrollView(table, preferencesName: "Legend", flexibleColumn: "kind")
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var minimumWidthChanged: ((CGFloat) -> Void)? {
        didSet { minimumWidthChanged?(scroll.minimumWidth + 23) }
    }
    private var rows: [KindUsage] = []
    private var groups: MapBreakdown?
    private var order: MapGroupOrder?
    private var visibleGroups = [UInt32: KindUsage]()
    private var settingSort = false
    private var sortRequest = 0
    private let sortQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var indices: [UInt32: Int] = [:]
    private var followed: UInt32?
    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 14
            background = glass
        } else {
            let visual = NSVisualEffectView()
            visual.material = .sidebar
            visual.blendingMode = .withinWindow
            background = visual
        }
        super.init(frame: frame)
        addSubview(background)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let menu = NSMenu()
        menu.autoenablesItems = false
        MapColorMode.populate(menu, target: nil, action: nil)
        picker.menu = menu
        picker.target = self; picker.action = #selector(chooseMode)
        picker.controlSize = .small
        picker.setAccessibilityLabel("Color map by")
        activity.style = .spinning; activity.controlSize = .small; activity.isDisplayedWhenStopped = false
        table.style = .inset
        table.rowHeight = 27
        table.intercellSpacing = .init(width: 2, height: 0)
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.setAccessibilityHelp("Select a row to highlight matching regions in the map. Press Escape to clear.")
        table.allowsColumnReordering = false
        table.usesAutomaticRowHeights = false
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("File kinds, allocated sizes and file counts")
        let marker = NSTableColumn(identifier: .init("marker"))
        marker.title = ""
        marker.headerCell.alignment = .left
        marker.headerCell.setAccessibilityLabel("File kind color and icon")
        marker.minWidth = 31; marker.maxWidth = 31; marker.width = 31; marker.resizingMask = []
        table.addTableColumn(marker)
        for (id, title, width, minWidth) in [
            ("kind", "Kind", 110, 40), ("files", "Files", 57, 39), ("bytes", "Size", 68, 52),
        ] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = CGFloat(width)
            col.minWidth = CGFloat(minWidth)
            col.resizingMask = id == "kind" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            col.headerCell.alignment = id == "bytes" ? .right : .left
            if id == "bytes" { col.headerToolTip = "Allocated size on disk" }
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "kind")
            table.addTableColumn(col)
        }
        setHeader(.kind)
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.minimumWidthChanged = { [weak self] width in self?.minimumWidthChanged?(width + 23) }
        addSubview(scroll)
        addSubview(title)
        addSubview(picker)
        addSubview(activity)
        positionContents()
    }
    required init?(coder: NSCoder) { nil }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        positionContents()
    }
    private func positionContents() {
        guard title.superview === self else { return }
        let panel = NSRect(x: Self.leadingInset, y: 0, width: max(0, bounds.width - Self.leadingInset - 7), height: bounds.height)
        let headerY = panel.maxY - 31
        let textSize = title.intrinsicContentSize
        background.frame = panel
        title.frame = NSRect(x: panel.minX + 10, y: headerY + (23 - ceil(textSize.height)) / 2, width: ceil(textSize.width), height: ceil(textSize.height))
        let x = title.frame.maxX + 6
        picker.frame = NSRect(x: x, y: headerY, width: max(0, min(155, panel.maxX - 26 - x)), height: 23)
        activity.frame = NSRect(x: panel.maxX - 22, y: headerY + 4, width: 14, height: 14)
        scroll.frame = NSRect(x: panel.minX + 5, y: 6, width: max(0, panel.width - 10), height: max(0, headerY - 13))
    }
    @objc private func chooseMode() {
        if let mode = MapColorMode(rawValue: picker.selectedTag()) { modeChanged?(mode) }
    }
    func choosing(_ mode: MapColorMode, loading: Bool) {
        picker.selectItem(withTag: mode.rawValue)
        picker.toolTip = mode.help
        if loading { activity.startAnimation(nil) } else { activity.stopAnimation(nil) }
    }
    private func sortPreferenceKey(_ mode: MapColorMode) -> String { "DiskSlopLegendSort.\(mode.rawValue)" }
    private func setHeader(_ mode: MapColorMode) {
        table.tableColumn(withIdentifier: .init("kind"))?.title = mode.column
        table.setAccessibilityLabel("\(mode.title), file counts and allocated sizes")
        settingSort = true
        let saved = UserDefaults.standard.dictionary(forKey: sortPreferenceKey(mode))
        if let key = saved?["key"] as? String, ["kind", "files", "bytes"].contains(key),
           let ascending = saved?["ascending"] as? Bool {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        } else {
            table.sortDescriptors = [NSSortDescriptor(key: mode.ordered ? "kind" : "bytes", ascending: mode.ordered)]
        }
        settingSort = false
    }
    func show(_ kinds: [KindUsage]) {
        sortQueue.cancelAllOperations()
        if groups != nil { setHeader(.kind) }
        sortRequest += 1
        if let focus, focus.mode != .kind { clearFocus() }
        groups = nil; order = nil; visibleGroups.removeAll()
        followed = nil
        rows = kinds
        let largestCount = kinds.max { $0.files < $1.files }?.formattedFiles ?? formatCount(0)
        fitNumbers(byteWidth: TableTextCell.sizeColumnMinimum, largestCount: largestCount)
        if let sort = table.sortDescriptors.first, sort.key == "bytes" && !sort.ascending { reloadRows() }
        else { orderRows() }
    }
    var sort: (key: String, ascending: Bool) {
        let descriptor = table.sortDescriptors.first
        return (descriptor?.key ?? "bytes", descriptor?.ascending ?? false)
    }
    func show(_ breakdown: MapBreakdown, preservingSort: Bool = false, sorted: MapGroupOrder? = nil) {
        sortQueue.cancelAllOperations()
        sortRequest += 1
        let sameMode = groups?.mode == breakdown.mode
        if let focus, focus.mode != breakdown.mode { clearFocus() }
        if groups !== breakdown { focusedID = nil }
        groups = breakdown; order = sorted ?? breakdown.defaultOrder
        visibleGroups.removeAll(); rows.removeAll(); indices.removeAll(); followed = nil
        if !preservingSort || !sameMode { setHeader(breakdown.mode) }
        fitNumbers(byteWidth: TableTextCell.sizeColumnMinimum, largestCount: formatCount(breakdown.maximumCount))
        syncTableSelection(reload: true)
        restoreFocus(in: breakdown)
        if sorted == nil && sort != (breakdown.mode.ordered ? "kind" : "bytes", breakdown.mode.ordered) { orderRows() }
        if !preservingSort && breakdown.count > 0 { table.scrollRowToVisible(0) }
    }
    func showLive(_ kinds: [KindUsage], colors: MapBreakdown?, sorted: MapGroupOrder?) {
        if colors == nil, groups == nil, sort == ("bytes", false), kinds.count == rows.count {
            let old = rows
            var reordered = IndexSet()
            let visible = table.visibleRows
            rows = kinds
            indices.removeAll(keepingCapacity: true)
            for (i, item) in rows.enumerated() { indices[item.kind.id] = i }
            table.enumerateAvailableRowViews { _, i in
                guard kinds.indices.contains(i) else { return }
                let item = kinds[i], previous = old[i]
                if previous.kind.id != item.kind.id { reordered.insert(i); return }
                for (id, before, after) in [("bytes", previous.bytes, item.bytes), ("files", previous.files, item.files)] where before != after {
                    let col = self.table.column(withIdentifier: .init(id))
                    let cell = self.table.view(atColumn: col, row: i, makeIfNecessary: false) as? TableTextCell
                    cell?.setText(id == "bytes" ? item.formattedSize : item.formattedFiles)
                    if visible.contains(i) { cell?.highlightChange(from: before, to: after) }
                }
            }
            if !reordered.isEmpty {
                table.reloadData(forRowIndexes: reordered, columnIndexes: IndexSet(integersIn: table.tableColumns.indices))
                let prior = Dictionary(old.map { ($0.kind.id, $0) }, uniquingKeysWith: { first, _ in first })
                for i in reordered where visible.contains(i) {
                    let item = kinds[i], before = prior[item.kind.id]
                    table.highlight("bytes", row: i, previous: before?.bytes, current: item.bytes)
                    table.highlight("files", row: i, previous: before?.files, current: item.files)
                }
            }
            restoreKindFocus()
            if let largest = kinds.max(by: { $0.files < $1.files }) {
                fitNumbers(byteWidth: TableTextCell.sizeColumnMinimum, largestCount: largest.formattedFiles)
            }
            return
        }
        let origin = table.visibleRect.origin
        var previous = [String: KindUsage]()
        let sameMode = groups?.mode == colors?.mode
        if sameMode {
            if groups == nil { for item in rows { previous[item.kind.identifier] = item } }
            else {
                for i in table.visibleRows {
                    if let item = usage(at: i) { previous[item.kind.identifier] = item }
                }
            }
        }
        if let colors { show(colors, preservingSort: sameMode, sorted: sorted) }
        else { show(kinds) }
        table.scroll(origin)
        guard sameMode else { return }
        for i in table.visibleRows {
            guard let item = usage(at: i) else { continue }
            let before = previous[item.kind.identifier]
            table.highlight("bytes", row: i, previous: before?.bytes, current: item.bytes)
            table.highlight("files", row: i, previous: before?.files, current: item.files)
        }
    }
    private func fitNumbers(byteWidth: CGFloat, largestCount: String) {
        let countWidth = max(39, TableTextCell.numberWidth(largestCount, font: numberFont))
        for (id, width) in [("bytes", byteWidth), ("files", countWidth)] {
            guard let col = table.tableColumn(withIdentifier: .init(id)) else { continue }
            col.maxWidth = max(col.maxWidth, width)
            col.minWidth = width
            if col.width < width { col.width = width }
        }
        scroll.fitColumns()
    }
    private func orderRows() {
        guard !settingSort else { return }
        let sorter = table.sortDescriptors.first
        let key = sorter?.key ?? "bytes"
        let ascending = sorter?.ascending ?? false
        if let groups {
            sortRequest += 1
            let ticket = sortRequest
            sortQueue.cancelAllOperations()
            sortQueue.addOperation {
                let sorted = MapGroupOrder(groups.handle, key: key, ascending: ascending)
                DispatchQueue.main.async {
                    guard self.sortRequest == ticket, self.groups === groups else { return }
                    self.order = sorted; self.syncTableSelection(reload: true)
                    if let id = self.followed, let i = sorted.row(for: id) { self.table.scrollRowToVisible(i) }
                }
            }
            return
        }
        rows.sort { a, b in
            if key == "bytes" && a.bytes != b.bytes { return ascending ? a.bytes < b.bytes : a.bytes > b.bytes }
            if key == "files" && a.files != b.files { return ascending ? a.files < b.files : a.files > b.files }
            let cmp = a.kind.title.localizedStandardCompare(b.kind.title)
            if cmp == .orderedSame { return a.kind.identifier < b.kind.identifier }
            return key == "kind" && !ascending ? cmp == .orderedDescending : cmp == .orderedAscending
        }
        reloadRows()
    }
    private func reloadRows() {
        indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.kind.id, $0) })
        syncTableSelection(reload: true)
        restoreKindFocus()
        if let followed, let i = indices[followed] { table.scrollRowToVisible(i) }
    }
    func highlight(_ kind: UInt32?) {
        let next = kind.flatMap { index(of: $0) != nil ? $0 : nil }
        guard next != followed else { return }
        let old = followed
        followed = next
        if let old, let i = index(of: old) {
            (table.rowView(atRow: i, makeIfNecessary: false) as? LegendRow)?.followed = false
        }
        if let next, let i = index(of: next) {
            if focus == nil && !table.rows(in: table.visibleRect).contains(i) { table.scrollRowToVisible(i) }
            (table.rowView(atRow: i, makeIfNecessary: false) as? LegendRow)?.followed = true
        }
    }
    private func index(of id: UInt32) -> Int? { order?.row(for: id) ?? indices[id] }
    private func id(at row: Int) -> UInt32? { order?.group(at: row) ?? (rows.indices.contains(row) ? rows[row].kind.id : nil) }
    private func usage(at row: Int) -> KindUsage? {
        guard let groups, let order else { return rows.indices.contains(row) ? rows[row] : nil }
        let id = order.group(at: row)
        if let item = visibleGroups[id] { return item }
        let item = groups.usage(id)
        if visibleGroups.count >= 512 { visibleGroups.removeAll(keepingCapacity: true) }
        visibleGroups[id] = item
        return item
    }
    func numberOfRows(in tableView: NSTableView) -> Int { groups?.count ?? rows.count }
    private func syncTableSelection(reload: Bool = false) {
        updatingSelection = true
        defer { updatingSelection = false }
        if reload { table.reloadData() }
        let row = focusedID.flatMap(index(of:)) ?? -1
        guard row != table.selectedRow else { return }
        if row < 0 { table.deselectAll(nil) }
        else { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }
    private func setFocus(_ next: LegendFocus?, id: UInt32?) {
        focus = next; focusedID = id
        syncTableSelection()
        focusChanged?(next, id, groups)
    }
    func clearFocus() {
        if focus != nil { setFocus(nil, id: nil) }
    }
    var focusedUsage: KindUsage? {
        focusedID.flatMap(index(of:)).flatMap(usage(at:))
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        let row = table.selectedRow
        guard row >= 0, let id = id(at: row) else { clearFocus(); return }
        let next = groups?.focus(for: id) ?? LegendFocus(mode: .kind, id: id)
        setFocus(next, id: id)
    }
    private func restoreKindFocus() {
        guard let focus, focus.mode == .kind else { return }
        if indices[focus.id] == nil { clearFocus() }
        else { setFocus(focus, id: focus.id) }
    }
    private func restoreFocus(in breakdown: MapBreakdown) {
        guard let focus else { return }
        if breakdown.focus(for: focus.id) == focus {
            setFocus(focus, id: focus.id)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let id = focus.resolve(in: breakdown)
            DispatchQueue.main.async {
                guard self.focus == focus, self.groups === breakdown else { return }
                guard let id, let next = breakdown.focus(for: id) else { self.clearFocus(); return }
                self.setFocus(next, id: id)
            }
        }
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !settingSort, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        UserDefaults.standard.set(["key": key, "ascending": descriptor.ascending], forKey: sortPreferenceKey(groups?.mode ?? .kind))
        orderRows()
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("kindRow")
        let v = table.makeView(withIdentifier: id, owner: self) as? LegendRow ?? LegendRow()
        v.identifier = id
        v.followed = followed != nil && followed == self.id(at: row)
        return v
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let item = usage(at: row) else { return nil }
        let id = col.identifier
        if id.rawValue == "marker" {
            let cell = table.makeView(withIdentifier: id, owner: self) as? KindMarkerCell ?? KindMarkerCell()
            cell.identifier = id
            cell.configure(item.kind)
            return cell
        }
        let name = id.rawValue == "kind"
        let cell = TableTextCell.make(in: table, column: id, icon: false, numeric: !name)
        let text = name ? item.kind.title : id.rawValue == "bytes" ? item.formattedSize : item.formattedFiles
        cell.textField?.font = name ? .systemFont(ofSize: 12, weight: .medium) : numberFont
        cell.textField?.alignment = id.rawValue == "bytes" ? .right : .left
        cell.textField?.textColor = .labelColor
        cell.setText(text)
        return cell
    }
}
