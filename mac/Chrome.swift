import AppKit

final class WindowToolbar: NSObject, NSToolbarDelegate {
    struct Command { let id: String; let title: String; let symbol: String; let action: Selector }
    private weak var target: AnyObject?
    private let commands: [Command]
    private var items: [String: NSToolbarItem] = [:]
    private let toolbar = NSToolbar(identifier: "DiskSlopTools")
    init(target: AnyObject, commands: [Command], window: NSWindow) {
        self.target = target
        self.commands = commands
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.titlebarSeparatorStyle = .none
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("history"), .space, .init("zoom"), .flexibleSpace, .init("choose"), .init("home"), .init("disk"), .space, .init("refresh")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.init("update")]
    }
    func setUpdateAvailable(_ available: Bool) {
        let id = NSToolbarItem.Identifier("update")
        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == id }) {
            if !available {
                toolbar.removeItem(at: index)
                items.removeValue(forKey: id.rawValue)
            }
        } else if available, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier.rawValue == "choose" }) {
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let pair: (String, [String])
        switch id.rawValue {
        case "history": pair = ("Selection History", ["back", "forward"])
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
        if spec.id == "update" {
            let tint = NSColor(srgbRed: 83/255, green: 189/255, blue: 164/255, alpha: 1)
            item.visibilityPriority = .high
            if #available(macOS 26.0, *) {
                item.style = .prominent
                item.backgroundTintColor = tint
            } else if let image = item.image {
                let button = NSButton(image: image, target: target, action: spec.action)
                button.bezelStyle = .rounded
                button.bezelColor = tint
                button.toolTip = spec.title
                button.setAccessibilityLabel(spec.title)
                button.sizeToFit()
                item.view = button
            }
        }
        if ["back", "forward", "zoomIn", "zoomOut"].contains(spec.id) { item.isEnabled = false }
        items[spec.id] = item
        return item
    }
    func updateZoom(hasScan: Bool, scale: CGFloat) {
        updateZoom(inward: hasScan && scale < CGFloat(1 << 30), outward: hasScan && scale > 1)
    }
    func updateZoom(inward: Bool, outward: Bool) {
        items["zoomIn"]?.isEnabled = inward; items["zoomOut"]?.isEnabled = outward
    }
    func update(busy: Bool, scanning: Bool, back: Bool, forward: Bool, hasScan: Bool) {
        for name in ["choose", "home", "disk"] { items[name]?.isEnabled = !busy }
        items["back"]?.isEnabled = !busy && back
        items["forward"]?.isEnabled = !busy && forward
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

final class LiveStatusDot: NSImageView {
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            contentTintColor = isOn ? .systemGreen : .systemGray
            updatePulse()
        }
    }
    private var pulsing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        contentTintColor = .systemGray
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updatePulse),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.removeObserver(self, name: name, object: nil)
            if let window { center.addObserver(self, selector: #selector(updatePulse), name: name, object: window) }
        }
        updatePulse()
    }
    override func viewDidHide() { super.viewDidHide(); updatePulse() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePulse() }

    @objc private func updatePulse() {
        let presented = window.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let shouldPulse = isOn && presented && !isHiddenOrHasHiddenAncestor
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldPulse != pulsing else { return }
        pulsing = shouldPulse
        if #available(macOS 14.0, *) {
            if pulsing { addSymbolEffect(.pulse, options: .repeating.speed(0.7)) }
            else { removeAllSymbolEffects(animated: false) }
        } else if pulsing {
            wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.45
            pulse.duration = 1; pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulse, forKey: "pulse")
        } else { layer?.removeAnimation(forKey: "pulse") }
    }
}

final class Welcome: NSView {
    let actions: [NSButton]
    private let capacityBar = VolumeUsageBar()
    private let capacityLabel = NSTextField(labelWithString: "")
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
        capacityLabel.textColor = .secondaryLabelColor
        capacityLabel.font = .systemFont(ofSize: 11)
        capacityBar.widthAnchor.constraint(equalToConstant: 236).isActive = true
        let stack = NSStackView(views: [icon, title, subtitle, buttonRow, capacityBar, capacityLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.setCustomSpacing(23, after: subtitle)
        stack.setCustomSpacing(20, after: buttonRow)
        stack.setCustomSpacing(4, after: capacityBar)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -9)])
        refreshCapacity()
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidUnhide() { super.viewDidUnhide(); refreshCapacity() }

    func refreshCapacity() {
        let capacity = VolumeCapacity.startup()
        capacityBar.show(capacity)
        capacityLabel.stringValue = capacity?.summary.map { "\($0) on this Mac" } ?? ""
        capacityLabel.isHidden = capacityLabel.stringValue.isEmpty
        capacityLabel.toolTip = capacity?.detail
        capacityLabel.setAccessibilityLabel(capacity?.detail)
    }
}
