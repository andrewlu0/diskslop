import AppKit

final class NativeTableSurface: NSView {
    private let material: NSView
    init(_ table: NSTableView) {
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
        for column in table.tableColumns { column.headerCell.alignment = .center }
        let scroll = NSScrollView()
        scroll.borderType = .noBorder; scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = table
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

final class CenteredTableCell: NSTableCellView {
    static func make(in view: NSTableView, column: NSUserInterfaceItemIdentifier, icon: Bool, numeric: Bool) -> CenteredTableCell {
        if let cell = view.makeView(withIdentifier: column, owner: view) as? CenteredTableCell { return cell }
        let cell = CenteredTableCell()
        cell.identifier = column
        let label = NSTextField(labelWithString: "")
        label.alignment = .center; label.lineBreakMode = .byTruncatingMiddle
        label.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label; cell.addSubview(label)
        let inset: CGFloat = icon ? 22 : 3
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -inset)
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
