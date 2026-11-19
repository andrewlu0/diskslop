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
    private let background: NSView
    private let title = NSTextField(labelWithString: "File Kinds")
    private let table = NSTableView()
    private lazy var scroll = FittingTableScrollView(table, flexibleColumn: "kind")
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var minimumWidthChanged: ((CGFloat) -> Void)? {
        didSet { minimumWidthChanged?(scroll.minimumWidth + 23) }
    }
    private var rows: [KindUsage] = []
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
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        table.style = .inset
        table.rowHeight = 27
        table.intercellSpacing = .init(width: 2, height: 0)
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
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
        table.sortDescriptors = [NSSortDescriptor(key: "bytes", ascending: false)]
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.minimumWidthChanged = { [weak self] width in self?.minimumWidthChanged?(width + 23) }
        addSubview(scroll)
        addSubview(title)
        positionContents()
    }
    required init?(coder: NSCoder) { nil }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        positionContents()
    }
    private func positionContents() {
        guard title.superview === self else { return }
        let panel = NSRect(x: 6, y: 0, width: max(0, bounds.width - 13), height: bounds.height)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let titleY = panel.maxY - 10 - titleHeight
        background.frame = panel
        title.frame = NSRect(x: panel.minX + 10, y: titleY, width: max(0, panel.width - 20), height: titleHeight)
        scroll.frame = NSRect(x: panel.minX + 5, y: 6, width: max(0, panel.width - 10), height: max(0, titleY - 13))
    }
    func show(_ kinds: [KindUsage]) {
        followed = nil
        rows = kinds
        let byteWidth = kinds.reduce(CGFloat(52)) { max($0, TableTextCell.numberWidth($1.formattedSize, font: numberFont)) }
        let largestCount = kinds.max { $0.files < $1.files }?.formattedFiles ?? formatCount(0)
        let countWidth = max(39, TableTextCell.numberWidth(largestCount, font: numberFont))
        for (id, width) in [("bytes", byteWidth), ("files", countWidth)] {
            guard let col = table.tableColumn(withIdentifier: .init(id)) else { continue }
            col.maxWidth = max(col.maxWidth, width)
            col.minWidth = width
            if col.width < width { col.width = width }
        }
        scroll.fitColumns()
        if let sort = table.sortDescriptors.first, sort.key == "bytes" && !sort.ascending {
            reloadRows()
        } else {
            orderRows()
        }
    }
    private func orderRows() {
        let sorter = table.sortDescriptors.first
        let key = sorter?.key ?? "bytes"
        let ascending = sorter?.ascending ?? false
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
        table.reloadData()
        if let followed, let i = indices[followed] { table.scrollRowToVisible(i) }
    }
    func highlight(_ kind: UInt32?) {
        let next = kind.flatMap { indices[$0] != nil ? $0 : nil }
        guard next != followed else { return }
        let old = followed
        followed = next
        if let old, let i = indices[old] {
            (table.rowView(atRow: i, makeIfNecessary: false) as? LegendRow)?.followed = false
        }
        if let next, let i = indices[next] {
            if !table.rows(in: table.visibleRect).contains(i) { table.scrollRowToVisible(i) }
            (table.rowView(atRow: i, makeIfNecessary: false) as? LegendRow)?.followed = true
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { orderRows() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("kindRow")
        let v = table.makeView(withIdentifier: id, owner: self) as? LegendRow ?? LegendRow()
        v.identifier = id
        v.followed = rows.indices.contains(row) && followed == rows[row].kind.id
        return v
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, rows.indices.contains(row) else { return nil }
        let item = rows[row]
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
