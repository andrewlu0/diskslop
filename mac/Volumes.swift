import AppKit
import Darwin

struct VolumeCapacity {
    let available: UInt64?, total: UInt64?

    init(_ stats: statfs) {
        let blockSize = UInt64(stats.f_bsize)
        func bytes(_ blocks: UInt64) -> UInt64? {
            guard blockSize > 0, blocks != .max else { return nil }
            let (value, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
            return overflow ? nil : value
        }
        total = stats.f_blocks > 0 ? bytes(stats.f_blocks) : nil
        available = total == nil && stats.f_bavail == 0 ? nil : bytes(stats.f_bavail)
    }

    static func startup() -> Self? {
        var stats = statfs()
        guard statfs(StartupSnapshot.startupPath, &stats) == 0 else { return nil }
        return Self(stats)
    }

    var usedFraction: Double? {
        guard let available, let total, total > 0 else { return nil }
        return Double(total - min(available, total)) / Double(total)
    }
    var summary: String? {
        guard let available else { return nil }
        let free = "\(formatBytes(available)) available"
        guard let total, let usedFraction else { return free }
        let percent = usedFraction.formatted(.percent.precision(.fractionLength(0...1)))
        return "\(percent) used · \(free) of \(formatBytes(total))"
    }
    var detail: String {
        summary ?? "Available space unknown"
    }
}

final class VolumeUsageBar: NSView {
    private var fraction: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }
    required init?(coder: NSCoder) { nil }

    func show(_ capacity: VolumeCapacity?) {
        let used = capacity?.usedFraction
        isHidden = used == nil
        let next = CGFloat(used ?? 0)
        if fraction != next {
            fraction = next
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !bounds.isEmpty else { return }
        let radius = min(bounds.height, bounds.width) / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let width = bounds.width * fraction
        guard width > 0 else { return }
        let height = min(bounds.height, width)
        let x = userInterfaceLayoutDirection == .rightToLeft ? bounds.maxX - width : bounds.minX
        let fill = NSRect(x: x, y: bounds.midY - height / 2, width: width, height: height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct MountedVolume {
    let url: URL, name: String, symbol: String
    let capacity: VolumeCapacity, hidden: Bool, startup: Bool
    static func all() -> [MountedVolume] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count >= 0 else { return [] }
        var stores: [Darwin.statfs] = .init(repeating: .init(), count: Int(count) + 8)
        let actual = stores.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard actual >= 0 else { return [] }
        return stores.prefix(Int(actual)).map { value in
            var m = value
            let url = withUnsafeBytes(of: &m.f_mntonname) { bytes in
                URL(fileURLWithFileSystemRepresentation: bytes.baseAddress!.assumingMemoryBound(to: CChar.self), isDirectory: true, relativeTo: nil)
            }
            let path = url.path
            let boot = path == StartupSnapshot.startupPath
            let local = m.f_flags & UInt32(MNT_LOCAL) != 0
            let ownName = path == "/" ? "System volume" : url.lastPathComponent
            let hidden = !boot && (path == "/" || m.f_flags & UInt32(MNT_DONTBROWSE) != 0 || path == "/dev" || path.hasPrefix("/System/Volumes/"))
            let symbol = boot || path == "/" ? "internaldrive.fill" : local ? "externaldrive.fill" : "network"
            return MountedVolume(url: url, name: boot ? "Startup disk · Data" : ownName, symbol: symbol,
                capacity: VolumeCapacity(m), hidden: hidden, startup: boot)
        }.sorted {
            if $0.startup != $1.startup { return $0.startup }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private final class AvailableSpaceCell: NSTableCellView {
    static let minimumWidth = TableTextCell.sizeColumnMinimum + 58
    private let bar = VolumeUsageBar()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let amount = NSTextField(labelWithString: "")
        amount.font = TableTextCell.sizeFont
        amount.alignment = .right
        amount.textColor = .secondaryLabelColor
        amount.translatesAutoresizingMaskIntoConstraints = false
        textField = amount
        addSubview(bar); addSubview(amount)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            bar.trailingAnchor.constraint(equalTo: amount.leadingAnchor, constant: -8),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            amount.widthAnchor.constraint(equalToConstant: TableTextCell.sizeColumnMinimum),
            amount.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            amount.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func show(_ capacity: VolumeCapacity) {
        bar.show(capacity)
        textField?.stringValue = capacity.available.map(formatBytes) ?? "—"
        let detail = capacity.detail
        textField?.setAccessibilityLabel(detail)
        toolTip = detail
    }
}

final class VolumePicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 620, height: 362), styleMask: [.titled], backing: .buffered, defer: false)
    private let table = NSTableView()
    private var volumes: [MountedVolume] = [], visible: [MountedVolume] = []
    private var showAll: NSButton!, scanButton: NSButton!
    private var callback: ((URL?) -> Void)?
    private var observations: [NSObjectProtocol] = []

    func present(on window: NSWindow, completion: @escaping (URL?) -> Void) {
        callback = completion
        panel.title = "Choose a Volume"
        let content = NSView()
        panel.contentView = content
        showAll = NSButton(checkboxWithTitle: "Show hidden volumes", target: self, action: #selector(filter))
        scanButton = NSButton(title: "Scan Volume", target: self, action: #selector(choose))
        scanButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
        cancel.keyEquivalent = "\u{1b}"
        for (id, title, width) in [("name","Volume",170),("path","Mount point",220),("free","Usage / Available",174)] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title; col.minWidth = id == "free" ? AvailableSpaceCell.minimumWidth : 82
            col.width = max(CGFloat(width), col.minWidth)
            col.headerCell.alignment = id == "free" ? .right : .left
            table.addTableColumn(col)
        }
        table.rowHeight = 30; table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(choose)
        table.setAccessibilityLabel("Mounted volumes")
        let surface = NativeTableSurface(table, preferencesName: "Volumes", flexibleColumn: "path")
        let buttons = NSStackView(views: [cancel,scanButton]); buttons.spacing = 8
        scanButton.setContentHuggingPriority(.required, for: .vertical)
        for v in [surface,showAll!,buttons] as [NSView] { content.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            buttons.heightAnchor.constraint(equalTo: scanButton.heightAnchor),
            surface.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10), surface.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            surface.topAnchor.constraint(equalTo: content.topAnchor, constant: 8), surface.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            showAll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), showAll.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)])
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.load() })
        }
        load()
        window.beginSheet(panel)
    }
    deinit { for observer in observations { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    private func load() { volumes = MountedVolume.all(); filter() }
    @objc private func filter() {
        let current = visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].url : nil
        visible = volumes.filter { showAll.state == .on || !$0.hidden }
        table.reloadData()
        if !visible.isEmpty { table.selectRowIndexes(IndexSet(integer: visible.firstIndex(where: { $0.url == current }) ?? 0), byExtendingSelection: false) }
        scanButton.isEnabled = table.selectedRow >= 0
    }
    private func finish(_ url: URL?) {
        panel.sheetParent?.endSheet(panel)
        let done = callback; callback = nil; done?(url)
    }
    @objc private func choose() {
        if visible.indices.contains(table.selectedRow) { finish(visible[table.selectedRow].url) }
    }
    @objc private func dismiss() { finish(nil) }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row), let tableColumn else { return nil }
        let id = tableColumn.identifier
        let volume = visible[row]
        if id.rawValue == "free" {
            let cell = table.makeView(withIdentifier: id, owner: self) as? AvailableSpaceCell ?? AvailableSpaceCell()
            cell.identifier = id
            cell.show(volume.capacity)
            return cell
        }
        let isName = id.rawValue == "name"
        let cell = TableTextCell.make(in: table, column: id, icon: isName, numeric: false)
        cell.setText(isName ? volume.name : volume.url.path)
        cell.textField?.textColor = isName ? .labelColor : .secondaryLabelColor
        if isName {
            cell.imageView?.image = NSImage(systemSymbolName: volume.symbol, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .controlAccentColor
        }
        return cell
    }
}
