import AppKit

final class WindowToolbar: NSObject, NSToolbarDelegate {
    struct Command { let id: String; let title: String; let symbol: String; let action: Selector }
    private weak var target: AnyObject?
    private let commands: [Command]
    private var items: [String: NSToolbarItem] = [:]
    init(target: AnyObject, commands: [Command], window: NSWindow) {
        self.target = target
        self.commands = commands
        super.init()
        let toolbar = NSToolbar(identifier: "DiskSlopTools")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.titlebarSeparatorStyle = .none
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("history"), .init("folders"), .space, .init("zoom"), .flexibleSpace, .init("choose"), .init("home"), .init("disk"), .space, .init("refresh")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let pair: (String, [String])
        switch id.rawValue {
        case "history": pair = ("Selection History", ["back", "forward"])
        case "folders": pair = ("Folder Navigation", ["up", "down"])
        case "zoom": pair = ("Map Zoom", ["zoomOut", "zoomIn"])
        default: return makeItem(id)
        }
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.label = pair.0; group.paletteLabel = pair.0
        group.selectionMode = .momentary; group.controlRepresentation = .expanded
        group.isBordered = true; group.isNavigational = true; group.autovalidates = false
        group.subitems = pair.1.compactMap { makeItem(.init($0)) }
        return group
    }
    private func makeItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let spec = commands.first(where: { $0.id == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = spec.title
        item.paletteLabel = spec.title
        item.toolTip = spec.title
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.title)
        item.target = target
        item.action = spec.action
        item.isBordered = true
        item.autovalidates = false
        if ["back", "forward", "up", "down", "zoomIn", "zoomOut"].contains(spec.id) { item.isEnabled = false }
        items[spec.id] = item
        return item
    }
    func updateZoom(hasScan: Bool, scale: CGFloat) {
        items["zoomIn"]?.isEnabled = hasScan && scale < CGFloat(1 << 30)
        items["zoomOut"]?.isEnabled = hasScan && scale > 1
    }
    func update(busy: Bool, scanning: Bool, back: Bool, forward: Bool, up: Bool, down: Bool, hasScan: Bool) {
        for name in ["choose", "home", "disk"] { items[name]?.isEnabled = !busy }
        for (id, enabled) in [("back", back), ("forward", forward), ("up", up), ("down", down)] {
            items[id]?.isEnabled = !busy && enabled
        }
        guard let item = items["refresh"] else { return }
        let label = scanning ? "Cancel Scan" : "Rescan"
        if item.label != label {
            item.label = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: scanning ? "xmark" : "arrow.clockwise", accessibilityDescription: label)
        }
        item.isEnabled = scanning || (!busy && hasScan)
    }
}

func glassShelf(_ content: NSView) -> NSView {
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 21
        glass.contentView = content
        return glass
    }
    let visual = NSVisualEffectView()
    visual.material = .popover
    visual.state = .active
    visual.wantsLayer = true
    visual.layer?.cornerRadius = 21
    visual.layer?.masksToBounds = true
    content.frame = visual.bounds
    content.autoresizingMask = [.width, .height]
    visual.addSubview(content)
    return visual
}

final class Welcome: NSView {
    let actions: [NSButton]
    init(buttons: [NSButton]) {
        actions = buttons
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 105), icon.heightAnchor.constraint(equalToConstant: 105)])
        let title = NSTextField(labelWithString: "DiskSlop")
        title.font = .systemFont(ofSize: 34, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Choose a location to map its disk usage.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 15)
        let buttonRow = NSStackView(views: buttons)
        buttonRow.alignment = .centerY
        buttonRow.spacing = 9
        let stack = NSStackView(views: [icon, title, subtitle, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.setCustomSpacing(23, after: subtitle)
        if let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
           let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity, total > 0 {
            let capacity = NSTextField(labelWithString: "\(formatBytes(UInt64(max(0, available)))) available of \(formatBytes(UInt64(total))) on this Mac")
            capacity.textColor = .secondaryLabelColor
            capacity.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(capacity)
            stack.setCustomSpacing(20, after: buttonRow)
        }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -9)])
    }
    required init?(coder: NSCoder) { nil }
}
