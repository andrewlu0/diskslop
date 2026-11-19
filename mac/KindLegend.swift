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

private final class KindCell: NSTableCellView {
    private let swatch = NSView()
    private let glyph = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private var kind: FileKind?
    private static var icons = [String: NSImage]()
    override init(frame: NSRect) {
        super.init(frame: frame)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 2
        glyph.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        for v in [swatch, glyph, name] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            swatch.widthAnchor.constraint(equalToConstant: 8),
            swatch.heightAnchor.constraint(equalToConstant: 15), swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 5),
            glyph.widthAnchor.constraint(equalToConstant: 17),
            glyph.heightAnchor.constraint(equalToConstant: 17), glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ next: FileKind) {
        kind = next
        name.stringValue = next.title
        if Self.icons[next.glyph] == nil,
            let url = Bundle.main.url(forResource: next.glyph, withExtension: "svg", subdirectory: "KindIcons"),
            let icon = NSImage(contentsOf: url)
        {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            Self.icons[next.glyph] = icon
        }
        glyph.image = Self.icons[next.glyph]
        setAccessibilityLabel(next.title)
        toolTip = next.title
        updateColor()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }
    private func updateColor() {
        guard let kind else { return }
        let dark = effectiveAppearance.usesDarkColors
        swatch.layer?.backgroundColor = NSColor(rgb: kind.fill(darkMode: dark)).cgColor
        glyph.contentTintColor = kind.tint(darkMode: dark)
    }
}

final class KindLegend: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var columnSpace: CGFloat = -1
    private var rows: [KindUsage] = []
    private var indices: [UInt32: Int] = [:]
    private var followed: UInt32?
    override init(frame: NSRect) {
        super.init(frame: frame)
        let pane = NSView()
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 14
            glass.contentView = pane
            background = glass
        } else {
            let visual = NSVisualEffectView()
            visual.material = .sidebar
            visual.blendingMode = .withinWindow
            visual.addSubview(pane)
            pane.frame = visual.bounds
            pane.autoresizingMask = [.width, .height]
            background = visual
        }
        addSubview(background)
        background.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "File Kinds")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.style = .plain
        table.rowHeight = 27
        table.intercellSpacing = .init(width: 2, height: 0)
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("File kinds, allocated sizes and file counts")
        for (id, title, width, minWidth) in [
            ("kind", "Kind", 138, 70), ("bytes", "Size", 68, 52), ("files", "Files", 57, 39),
        ] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = CGFloat(width)
            col.minWidth = CGFloat(minWidth)
            col.resizingMask = id == "kind" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            col.headerCell.alignment = id == "kind" ? .left : .right
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "kind")
            table.addTableColumn(col)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "bytes", ascending: false)]
        scroll.documentView = table
        for v in [title, scroll] {
            pane.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            title.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: pane.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 5),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -5),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let available = scroll.contentView.bounds.width
        guard available > 0, available != columnSpace, table.tableColumns.count == 3 else { return }
        columnSpace = available
        let cols = table.tableColumns
        let overhead = max(0, table.rect(ofColumn: 2).maxX - cols.reduce(0) { $0 + $1.width })
        cols[0].width = max(cols[0].minWidth, available - cols[1].width - cols[2].width - overhead - 3)
        table.frame.size.width = available
    }
    func show(_ kinds: [KindUsage]) {
        followed = nil
        rows = kinds
        orderRows()
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
        if id.rawValue == "kind" {
            let cell = table.makeView(withIdentifier: id, owner: self) as? KindCell ?? KindCell()
            cell.identifier = id
            cell.configure(item.kind)
            return cell
        }
        let field = table.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        field.identifier = id
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.stringValue = id.rawValue == "bytes" ? formatBytes(item.bytes) : formatCount(item.files)
        return field
    }
}
