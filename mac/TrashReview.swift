import AppKit

struct TrashOutcome {
    let moved: Int, failed: Int
    let explanation: String?
    let firstUnmovedURL: URL?
}

final class TrashPlan: @unchecked Sendable {
    let model: ScanModel
    let impact: DTTrashImpact
    let roots: UnsafeBufferPointer<DTKey>
    private let handle: OpaquePointer

    init(model: ScanModel, keys: [DTKey]) throws {
        var impact = DTTrashImpact()
        var error: UnsafeMutablePointer<CChar>?
        let prepared = keys.withUnsafeBufferPointer { dt_trash_prepare(model.handle, $0.baseAddress, $0.count, &impact, &error) }
        guard let handle = prepared else { throw DiskError(message: takeError(error)) }
        self.handle = handle
        self.impact = impact
        self.model = model
        var count = 0
        let base = dt_trash_roots(handle, &count)
        roots = UnsafeBufferPointer(start: base, count: count)
    }
    deinit { dt_trash_plan_free(handle) }

    func item(at index: Int) -> (path: URL, size: UInt64)? {
        guard roots.indices.contains(index) else { return nil }
        let key = roots[index]
        var row = DTRow()
        guard dt_entry(model.handle, key.folder, key.slot, &row),
              let url = model.url(folder: key.folder, slot: key.slot, directory: row.isFolder) else { return nil }
        return (url, row.bytes)
    }
    func perform(acknowledged: Bool) -> TrashOutcome {
        var result = DTTrashResult()
        var error: UnsafeMutablePointer<CChar>?
        let started = dt_trash_perform(model.handle, handle, acknowledged, &result, &error)
        let description = error.map { takeError($0) }
        let key = result.first
        var row = DTRow()
        let url = key.slot != .max && dt_entry(model.handle, key.folder, key.slot, &row) ?
            model.url(folder: key.folder, slot: key.slot, directory: row.isFolder) : nil
        return TrashOutcome(moved: result.moved, failed: started ? result.failed : roots.count,
                            explanation: description, firstUnmovedURL: url)
    }
}

private final class TrashPanel: NSPanel {
    var dismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismiss?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if modifiers.isEmpty && [36, 76, 53].contains(event.keyCode) || modifiers == .command && event.charactersIgnoringModifiers == "." {
            dismiss?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class TrashReview: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let plan: TrashPlan
    private let panel: TrashPanel
    private let table = NSTableView()
    private var move: NSButton!, check: NSButton?
    private var completion: ((Bool?) -> Void)?

    init(_ plan: TrashPlan) {
        self.plan = plan
        panel = TrashPanel(contentRect: CGRect(x: 0, y: 0, width: 525, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
    }
    func present(on parent: NSWindow, completion: @escaping (Bool?) -> Void) {
        self.completion = completion
        panel.title = "Review Move to Trash"
        panel.dismiss = { [weak self] in self?.cancel() }
        let content = NSView()
        panel.contentView = content
        let first = plan.item(at: 0)?.path.lastPathComponent ?? "item"
        let what = plan.roots.count == 1 ? "“\(first)”" : "\(plan.roots.count.formatted()) selected items"
        let heading = NSTextField(wrappingLabelWithString: "Move \(what) to Trash?")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.maximumNumberOfLines = 2; heading.lineBreakMode = .byTruncatingMiddle
        let i = plan.impact
        let files = "\(formatCount(i.files)) \(i.files == 1 ? "file" : "files")"
        let folders = "\(formatCount(i.folders)) \(i.folders == 1 ? "folder" : "folders")"
        let total = NSTextField(wrappingLabelWithString: "\(files), \(folders) · \(formatBytes(i.bytes)) allocated in this scan."
            + (i.folders > 0 ? " Moving a folder includes everything currently inside it." : ""))
        total.textColor = .secondaryLabelColor
        let path = NSTableColumn(identifier: .init("path"))
        path.title = "Selected location"; path.minWidth = 180; path.width = 368
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Allocated"; size.minWidth = max(65, TableTextCell.sizeColumnMinimum); size.width = max(85, size.minWidth)
        table.addTableColumn(path); table.addTableColumn(size)
        path.headerCell.alignment = .left; size.headerCell.alignment = .right
        table.dataSource = self; table.delegate = self
        table.rowHeight = 25; table.style = .inset
        table.allowsColumnReordering = false
        table.setAccessibilityLabel("Selected locations to move to Trash")
        let scroll = FittingTableScrollView(table, flexibleColumn: "path")
        scroll.borderType = .bezelBorder
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        for view in [heading, total, scroll] as [NSView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(14, after: total)
        if dt_summary(plan.model.handle, 0).issues > 0 {
            let partial = NSTextField(wrappingLabelWithString: "The scan had read errors. Selected folders may contain additional items.")
            partial.font = .systemFont(ofSize: 12); partial.textColor = .secondaryLabelColor
            stack.addArrangedSubview(partial)
            partial.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if i.scope != 0 {
            let location = i.scope == 1 ? "on this volume" : "in this home folder"
            let acknowledge = NSButton(checkboxWithTitle: "Move \(i.percent)% of the scanned data \(location) to Trash.", target: self, action: #selector(checked))
            acknowledge.state = .off
            stack.addArrangedSubview(acknowledge); check = acknowledge
        }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        move = NSButton(title: "Move to Trash", target: self, action: #selector(confirm))
        move.hasDestructiveAction = true; move.keyEquivalent = ""
        move.isEnabled = check == nil
        let buttons = NSStackView(views: [cancel, move]); buttons.spacing = 8
        content.addSubview(stack); content.addSubview(buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor), total.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: CGFloat(min(6, plan.roots.count)) * 26 + 32),
            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 17),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        let height = max(164, content.fittingSize.height)
        panel.setContentSize(NSSize(width: 525, height: height))
        panel.defaultButtonCell = nil; panel.initialFirstResponder = cancel
        parent.beginSheet(panel)
        panel.makeFirstResponder(cancel)
    }

    @objc private func checked() { move.isEnabled = check?.state == .on }
    @objc private func cancel() { finish(nil) }
    @objc private func confirm() {
        guard check == nil || check?.state == .on else { return }
        finish(check?.state == .on)
    }
    private func finish(_ answer: Bool?) {
        guard let done = completion else { return }
        completion = nil
        panel.sheetParent?.endSheet(panel)
        done(answer)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { plan.roots.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let item = plan.item(at: row) else { return nil }
        let isSize = column.identifier.rawValue == "size"
        let cell = TableTextCell.make(in: tableView, column: column.identifier, icon: false, numeric: isSize)
        cell.setText(isSize ? formatBytes(item.size) : item.path.path)
        return cell
    }
}
