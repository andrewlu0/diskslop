import AppKit
import Darwin

private struct MountedVolume {
    let url: URL, name: String, symbol: String
    let available: UInt64?, hidden: Bool, startup: Bool
    static func all() -> [MountedVolume] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count >= 0 else { return [] }
        var stores: [Darwin.statfs] = .init(repeating: .init(), count: Int(count) + 8)
        let actual = stores.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard actual >= 0 else { return [] }
        let dataPath = "/System/Volumes/Data"
        let startOnData = FileManager.default.fileExists(atPath: dataPath)
        return stores.prefix(Int(actual)).map { value in
            var m = value
            let url = withUnsafeBytes(of: &m.f_mntonname) { bytes in
                URL(fileURLWithFileSystemRepresentation: bytes.baseAddress!.assumingMemoryBound(to: CChar.self), isDirectory: true, relativeTo: nil)
            }
            let path = url.path
            let boot = startOnData ? path == dataPath : path == "/"
            let local = m.f_flags & UInt32(MNT_LOCAL) != 0
            let ownName = path == "/" ? "System volume" : url.lastPathComponent
            let hidden = !boot && (path == "/" || m.f_flags & UInt32(MNT_DONTBROWSE) != 0 || path == "/dev" || path.hasPrefix("/System/Volumes/"))
            let symbol = boot || path == "/" ? "internaldrive.fill" : local ? "externaldrive.fill" : "network"
            let capacity = UInt64(m.f_bavail).multipliedReportingOverflow(by: UInt64(m.f_bsize))
            return MountedVolume(url: url, name: boot ? "Startup disk · Data" : ownName, symbol: symbol,
                available: capacity.overflow ? nil : capacity.partialValue, hidden: hidden, startup: boot)
        }.sorted {
            if $0.startup != $1.startup { return $0.startup }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
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
        for (id, title, width) in [("name","Volume",190),("path","Mount point",245),("free","Available",110)] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title; col.minWidth = id == "free" ? max(82, TableTextCell.sizeColumnMinimum) : 82
            col.width = max(CGFloat(width), col.minWidth)
            col.headerCell.alignment = id == "free" ? .right : .left
            table.addTableColumn(col)
        }
        table.rowHeight = 30; table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(choose)
        table.setAccessibilityLabel("Mounted volumes")
        let surface = NativeTableSurface(table, flexibleColumn: "path")
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
        let text = id.rawValue == "name" ? volume.name : id.rawValue == "path" ? volume.url.path : (volume.available.map(formatBytes) ?? "—")
        let isName = id.rawValue == "name"
        let cell = TableTextCell.make(in: table, column: id, icon: isName, numeric: id.rawValue == "free")
        cell.setText(text)
        cell.textField?.textColor = isName ? .labelColor : .secondaryLabelColor
        if isName {
            cell.imageView?.image = NSImage(systemSymbolName: volume.symbol, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = .controlAccentColor
        }
        return cell
    }
}
