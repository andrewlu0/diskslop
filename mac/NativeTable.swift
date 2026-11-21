import AppKit

final class FittingTableScrollView: NSScrollView {
    private let table: NSTableView
    private let flexibleID: NSUserInterfaceItemIdentifier
    private struct Fit: Equatable {
        let width: CGFloat, viewport: CGFloat, count: Int, style: NSTableView.Style
        let control: NSControl.ControlSize, border: NSBorderType
    }
    private var lastFit: Fit?
    private var fitting = false
    private var insets: (style: NSTableView.Style, count: Int, leading: CGFloat, columns: CGFloat)?
    private var widthObservers: [NSKeyValueObservation] = []
    private let widthsKey: String
    private var preferredWidths: [String: Double]
    private var pendingResize: (column: NSTableColumn, width: CGFloat)?
    private var fitScheduled = false
    private(set) var minimumWidth: CGFloat = 0
    var minimumWidthChanged: ((CGFloat) -> Void)?

    init(_ table: NSTableView, preferencesName: String, flexibleColumn: String) {
        widthsKey = "DiskSlopColumnWidths." + preferencesName
        preferredWidths = UserDefaults.standard.dictionary(forKey: widthsKey) as? [String: Double] ?? [:]
        self.table = table
        flexibleID = .init(flexibleColumn)
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        documentView = table
        widthObservers = table.tableColumns.map { column in
            column.observe(\.width) { [weak self] column, _ in self?.scheduleFit(afterResizing: column) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(columnResized(_:)),
            name: NSTableView.columnDidResizeNotification, object: table)
    }
    required init?(coder: NSCoder) { nil }
    override func tile() { super.tile(); fitColumns(ifNeeded: true) }
    override func layout() { super.layout(); fitColumns(ifNeeded: true) }

    @objc private func columnResized(_ notification: Notification) {
        if let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn { scheduleFit(afterResizing: column) }
    }
    private func scheduleFit(afterResizing column: NSTableColumn) {
        guard !fitting else { return }
        lastFit = nil
        if let index = table.headerView?.resizedColumn, table.tableColumns.indices.contains(index),
           table.tableColumns[index] === column {
            pendingResize = (column, column.width)
        }
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.fitScheduled = false
            self?.fitColumns()
        }
    }

    func fitColumns(ifNeeded: Bool = false) {
        let columns = table.tableColumns
        guard !fitting, window != nil, let flex = table.tableColumn(withIdentifier: flexibleID),
              contentView.bounds.width > 0, !columns.isEmpty else { return }
        fitting = true
        defer { fitting = false }
        let viewport = floor(contentView.bounds.width)
        let controlSize = verticalScroller?.controlSize ?? .regular
        let fit = Fit(width: bounds.width, viewport: viewport, count: columns.count, style: table.effectiveStyle,
            control: controlSize, border: borderType)
        if ifNeeded, table.frame.width == viewport, pendingResize == nil, lastFit == fit { return }
        lastFit = fit
        if table.frame.width != viewport { table.frame.size.width = viewport }
        // Column rectangles can still reflect the preceding widths while AppKit is resizing.
        if insets?.style != table.effectiveStyle || insets?.count != columns.count {
            table.tile()
            let end = table.rect(ofColumn: columns.count - 1).maxX
            let padding = max(0, end - columns.reduce(0) { $0 + $1.width })
            insets = (table.effectiveStyle, columns.count, max(2, table.rect(ofColumn: 0).minX), padding)
        }
        guard let insets else { return }
        let nativeInsets = insets.columns
        let outerInset = insets.leading
        // Reserve the scrollbar lane even when every row fits.
        let usable = NSScrollView.contentSize(forFrameSize: bounds.size, horizontalScrollerClass: nil,
            verticalScrollerClass: NSScroller.self, borderType: borderType, controlSize: controlSize, scrollerStyle: .legacy)
        let room = floor(min(viewport, usable.width) - nativeInsets - outerInset)
        let minimum = columns.reduce(CGFloat.zero) { $0 + $1.minWidth }
        let needed = ceil(NSScrollView.frameSize(forContentSize: NSSize(width: minimum + nativeInsets + outerInset, height: 1),
            horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self, borderType: borderType,
            controlSize: controlSize, scrollerStyle: .legacy).width)
        if needed != minimumWidth { minimumWidth = needed; minimumWidthChanged?(needed) }

        for col in columns where col.resizingMask.contains(.userResizingMask) {
            let ceiling = max(col.minWidth, room - (minimum - col.minWidth))
            if col.maxWidth != ceiling { col.maxWidth = ceiling }
        }
        let others = columns.filter { $0 !== flex && $0.resizingMask.contains(.userResizingMask) }
        let resize = pendingResize
        pendingResize = nil
        let dragged = resize?.column
        for col in others {
            let desired = preferredWidths[col.identifier.rawValue].map { CGFloat($0) } ?? col.width
            let width = min(col.maxWidth, max(col.minWidth, desired))
            if col.width != width { col.width = width }
        }
        let widthsBeforeDrag = others.map(\.width)
        if let resize, columns.contains(resize.column) {
            resize.column.width = min(resize.column.maxWidth, max(resize.column.minWidth, resize.width))
        }
        let total = columns.reduce(CGFloat.zero) { $0 + $1.width }
        var adjustment = room - total
        if dragged !== flex { adjustment = min(0, adjustment + flex.width - flex.minWidth) }
        for col in others where adjustment != 0 {
            let next = min(col.maxWidth, max(col.minWidth, col.width + adjustment))
            adjustment -= next - col.width
            if col.width != next { col.width = next }
        }
        let remaining = room - columns.filter { $0 !== flex }.reduce(0) { $0 + $1.width }
        let next = max(flex.minWidth, remaining)
        if flex.width != next { flex.width = next }
        if let dragged {
            for (col, previous) in zip(others, widthsBeforeDrag) where col === dragged || col.width != previous {
                preferredWidths[col.identifier.rawValue] = Double(col.width)
            }
            UserDefaults.standard.set(preferredWidths, forKey: widthsKey)
        }
    }
}

final class NativeTableSurface: NSView {
    private let material: NSView
    let scroll: FittingTableScrollView
    init(_ table: NSTableView, preferencesName: String, flexibleColumn: String = "name") {
        scroll = FittingTableScrollView(table, preferencesName: preferencesName, flexibleColumn: flexibleColumn)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 14
            material = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .contentBackground; effect.blendingMode = .withinWindow
            material = effect
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        table.style = .inset
        table.backgroundColor = .clear
        scroll.borderType = .noBorder; scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        for child in [material, scroll] {
            child.frame = bounds; child.autoresizingMask = [.width, .height]
            addSubview(child)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appearanceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        appearanceChanged()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); appearanceChanged() }
    @objc private func appearanceChanged() {
        let workspace = NSWorkspace.shared
        material.isHidden = workspace.accessibilityDisplayShouldReduceTransparency
        layer?.borderWidth = workspace.accessibilityDisplayShouldIncreaseContrast ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = material.isHidden ? NSColor.controlBackgroundColor.cgColor : NSColor.clear.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

private final class NumberFlash: NSView, CAAnimationDelegate {
    private var tint = NSColor.clear
    private var revision = 0
    override var isFlipped: Bool { superview?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ color: NSColor) {
        tint = color
        isHidden = false
        needsDisplay = true
        revision &+= 1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.1, 1]
        fade.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        fade.duration = 1.2
        fade.preferredFrameRateRange = chartFrameRate(displayRefreshRate)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        fade.setValue(revision, forKey: "revision")
        fade.delegate = self
        layer?.add(fade, forKey: "liveChange")
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished, animation.value(forKey: "revision") as? Int == revision else { return }
        isHidden = true
        layer?.removeAnimation(forKey: "liveChange")
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.26).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 4, yRadius: 4).fill()
        (superview as? TableTextCell)?.drawChangeText(tint, in: self)
    }
}

class TableTextCell: NSTableCellView {
    private var flash: NumberFlash?
    override func prepareForReuse() {
        super.prepareForReuse()
        flash?.layer?.removeAnimation(forKey: "liveChange")
        flash?.removeFromSuperview()
        flash = nil
    }

    func highlightChange(from previous: UInt64?, to current: UInt64) {
        guard previous != current, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let overlay: NumberFlash
        if let flash { overlay = flash }
        else {
            overlay = NumberFlash(frame: bounds)
            overlay.wantsLayer = true
            overlay.autoresizingMask = [.width, .height]
            overlay.setAccessibilityElement(false)
            addSubview(overlay)
            flash = overlay
        }
        let tint: NSColor
        if let previous { tint = current > previous ? .systemGreen : .systemRed }
        else { tint = .controlAccentColor }
        overlay.show(tint)
    }

    func drawChangeText(_ tint: NSColor, in overlay: NSView) {
        guard let field = textField, let ink = field.cell?.copy() as? NSTextFieldCell,
              let context = NSGraphicsContext.current?.cgContext else { return }
        ink.backgroundStyle = .normal
        ink.textColor = tint
        let rect = overlay.convert(field.bounds, from: field)
        let flipped = overlay.isFlipped != field.isFlipped
        context.saveGState()
        context.translateBy(x: rect.minX, y: flipped ? rect.maxY : rect.minY)
        if flipped { context.scaleBy(x: 1, y: -1) }
        ink.drawInterior(withFrame: field.bounds, in: field)
        context.restoreGState()
    }

    static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let sizeColumnMinimum: CGFloat = {
        // Reserve the widest localized unit and precision before the first row is displayed.
        var samples: [UInt64] = [0, 1, 888, UInt64(Int64.max)]
        var unit: UInt64 = 1_000
        while unit <= 1_000_000_000_000_000 {
            samples += [unit, unit * 2, unit * 888 + unit / 100 * 88]
            unit *= 1_000
        }
        samples.append(unit * 8 + unit / 100 * 88)
        return samples.reduce(0) { max($0, numberWidth(formatBytes($1), font: sizeFont)) }
    }()

    static func numberWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12
    }

    func setText(_ text: String) {
        textField?.stringValue = text
        toolTip = text
    }

    static func make(in view: NSTableView, column: NSUserInterfaceItemIdentifier, icon: Bool, numeric: Bool) -> TableTextCell {
        if let cell = view.makeView(withIdentifier: column, owner: view) as? TableTextCell {
            return cell
        }
        let cell = TableTextCell()
        cell.identifier = column
        let label = NSTextField(labelWithString: "")
        label.alignment = numeric ? .right : .left; label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.font = numeric ? sizeFont : .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label; cell.addSubview(label)
        let inset: CGFloat = icon ? 22 : 3
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3)
        ])
        if icon {
            let image = NSImageView(); cell.imageView = image
            image.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16)
            ])
        }
        return cell
    }
}

extension NSTableView {
    var visibleRows: Range<Int> {
        guard !isHiddenOrHasHiddenAncestor, window != nil else { return 0..<0 }
        let range = rows(in: visibleRect)
        guard range.length > 0, range.location < numberOfRows else { return 0..<0 }
        return range.location..<min(NSMaxRange(range), numberOfRows)
    }
    func highlight(_ column: String, row: Int, previous: UInt64?, current: UInt64) {
        guard previous != current else { return }
        let index = self.column(withIdentifier: .init(column))
        guard index >= 0 else { return }
        (view(atColumn: index, row: row, makeIfNecessary: true) as? TableTextCell)?.highlightChange(from: previous, to: current)
    }
}
