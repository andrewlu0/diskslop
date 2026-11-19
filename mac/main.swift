import AppKit

private struct Location { let id: UInt32; let url: URL; var item: DiskItem? = nil }

final class DiskApp: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    private var window: NSWindow!
    private let tree = Outline()
    private let map = Treemap()
    private let legend = KindLegend()
    private let split = NSSplitView()
    private var preferredPanes: [NSLayoutConstraint] = []
    private let appearance = AppearanceSettings()
    private let folderLabel = NSTextField(labelWithString: "DiskTally")
    private let pathLabel = NSTextField(labelWithString: "Choose a folder or scan your startup data volume.")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var toolbar: WindowToolbar!
    private var welcome: Welcome!
    private var shelf: NSView!
    private let selectionLabel = NSTextField(labelWithString: "")
    private var trashButton: NSButton!, revealButton: NSButton!
    private var model: ScanModel?
    private let cache = ScanCache()
    private var volumePicker: VolumePicker?
    private var trashReview: TrashReview?
    private var listing: FolderListing?
    private var locations: [Location] = []
    private var history = SelectionHistory()
    private var applyingNavigation = false
    private var scanning: ScanProgress?
    private var timer: Timer?
    private var busy = false
    private var scanTime: Double = 0
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearance.apply()
        buildMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DiskTally"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 770, height: 410)
        window.acceptsMouseMovedEvents = true
        window.center()
        window.setFrameAutosaveName("DiskTallyMain")
        toolbar = WindowToolbar(target: self, commands: [
            .init(id: "zoomOut", title: "Zoom Out", symbol: "minus.magnifyingglass", action: #selector(zoomOut)),
            .init(id: "zoomIn", title: "Zoom In", symbol: "plus.magnifyingglass", action: #selector(zoomIn)),
            .init(id: "back", title: "Back", symbol: "chevron.backward", action: #selector(back)),
            .init(id: "forward", title: "Forward", symbol: "chevron.forward", action: #selector(forward)),
            .init(id: "up", title: "Enclosing Folder", symbol: "arrow.up", action: #selector(folderUp)),
            .init(id: "down", title: "Enter Selected Folder", symbol: "arrow.down", action: #selector(folderDown)),
            .init(id: "choose", title: "Choose Folder…", symbol: "folder.badge.plus", action: #selector(choose)),
            .init(id: "home", title: "Scan Home", symbol: "house", action: #selector(home)),
            .init(id: "disk", title: "Choose Volume…", symbol: "externaldrive", action: #selector(chooseVolume)),
            .init(id: "refresh", title: "Rescan", symbol: "arrow.clockwise", action: #selector(refreshOrCancel))
        ], window: window)
        buildContent()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let argumentURL = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let url = pendingURL ?? argumentURL { scan(url) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if window == nil { pendingURL = url } else if !busy { scan(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(), submenu = NSMenu(title: title)
            main.addItem(item); item.submenu = submenu
            return submenu
        }
        @discardableResult
        func command(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                     _ modifiers: NSEvent.ModifierFlags = .command, responder: Bool = false) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = responder ? nil : self
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let app = menu("DiskTally")
        command(app, "About DiskTally", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), responder: true)
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppearanceSettings.show(_:)), keyEquivalent: ",").target = appearance
        app.addItem(.separator())
        command(app, "Hide DiskTally", #selector(NSApplication.hide(_:)), "h", responder: true)
        command(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], responder: true)
        command(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), responder: true)
        app.addItem(.separator())
        command(app, "Quit DiskTally", #selector(NSApplication.terminate(_:)), "q", responder: true)

        let file = menu("File")
        command(file, "Choose Folder…", #selector(choose), "o")
        command(file, "Choose Volume…", #selector(chooseVolume), "o", [.command, .shift])
        command(file, "Scan Home", #selector(home), "h", [.command, .shift])
        file.addItem(.separator())
        command(file, "Rescan", #selector(rescan), "r")
        command(file, "Refresh Selection", #selector(refreshSelection))
        command(file, "Cancel Scan", #selector(cancel))
        file.addItem(.separator())
        command(file, "Open Selected Items", #selector(openSelection))
        command(file, "Open in Finder", #selector(reveal))
        command(file, "Move to Trash…", #selector(trash), "\u{8}")
        file.addItem(.separator())
        command(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", responder: true)

        let edit = menu("Edit")
        command(edit, "Undo", Selector(("undo:")), "z", responder: true)
        command(edit, "Redo", Selector(("redo:")), "z", [.command, .shift], responder: true)
        edit.addItem(.separator())
        command(edit, "Cut", #selector(NSText.cut(_:)), "x", responder: true)
        command(edit, "Copy", #selector(NSText.copy(_:)), "c", responder: true)
        command(edit, "Copy Pathnames", #selector(copyPaths), "c", [.command, .option])
        command(edit, "Paste", #selector(NSText.paste(_:)), "v", responder: true)
        edit.addItem(.separator())
        command(edit, "Select All", #selector(NSText.selectAll(_:)), "a", responder: true)
        command(edit, "Deselect All", #selector(deselectAll), "a", [.command, .option])

        let view = menu("View")
        command(view, "Zoom In", #selector(zoomIn), "+")
        let unshiftedZoom = command(view, "Zoom In", #selector(zoomIn), "=")
        unshiftedZoom.isHidden = true
        unshiftedZoom.allowsKeyEquivalentWhenHidden = true
        command(view, "Zoom Out", #selector(zoomOut), "-")
        command(view, "Fit Map", #selector(fitMap), "0")
        command(view, "Zoom to Selection", #selector(fitSelection), "f", [.command, .shift])
        view.addItem(.separator())
        command(view, "Hide Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option], responder: true)
        command(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], responder: true)

        let go = menu("Go")
        command(go, "Back", #selector(back), "[")
        command(go, "Forward", #selector(forward), "]")
        go.addItem(.separator())
        command(go, "Enclosing Folder", #selector(folderUp), String(UnicodeScalar(NSUpArrowFunctionKey)!))
        command(go, "Enter Selected Folder", #selector(folderDown), String(UnicodeScalar(NSDownArrowFunctionKey)!))

        let windowMenu = menu("Window")
        command(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", responder: true)
        command(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)), responder: true)
        windowMenu.addItem(.separator())
        command(windowMenu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), responder: true)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
    private var browserIsKey: Bool { window?.isKeyWindow == true && window.attachedSheet == nil }
    private var hasSelection: Bool { tree.view.numberOfSelectedRows > 0 }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(cancel) { return browserIsKey && scanning != nil }
        guard browserIsKey, !busy else { return false }
        switch menuItem.action {
        case #selector(copyPaths):
            menuItem.title = tree.view.numberOfSelectedRows == 1 ? "Copy Pathname" : "Copy Pathnames"
            return hasSelection
        case #selector(copy(_:)), #selector(deselectAll), #selector(trash), #selector(reveal),
             #selector(openSelection), #selector(refreshSelection), #selector(fitSelection):
            return hasSelection
        case #selector(selectAll(_:)): return (listing?.summary.entries ?? 0) > 0
        case #selector(zoomIn): return listing != nil && map.zoom < CGFloat(1 << 30)
        case #selector(zoomOut), #selector(fitMap): return listing != nil && map.zoom > 1
        case #selector(rescan): return !locations.isEmpty
        case #selector(back): return history.adjacent(-1) != nil
        case #selector(forward): return history.adjacent(1) != nil
        case #selector(folderUp): return locations.count > 1
        case #selector(folderDown): return canEnterFolder
        default: return true
        }
    }
    @objc func selectAll(_ sender: Any?) {
        guard browserIsKey, !busy else { return }
        tree.selectAll(in: locations.compactMap(\.item))
    }
    @objc private func deselectAll() {
        guard browserIsKey, !busy, hasSelection else { return }
        tree.selectSaved([], lead: nil)
    }
    @objc func copy(_ sender: Any?) { copySelection(pathsOnly: false) }
    @objc private func copyPaths() { copySelection(pathsOnly: true) }
    private func copySelection(pathsOnly: Bool) {
        guard browserIsKey, !busy, hasSelection else { return }
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        if pathsOnly { board.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) }
        else { board.writeObjects(urls as [NSURL]) }
    }
    @objc private func zoomIn() { map.stepZoom(inward: true) }
    @objc private func zoomOut() { map.stepZoom(inward: false) }
    @objc private func fitMap() { map.fitMap() }
    @objc private func fitSelection() { map.fitSelection() }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }
    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }
    private func buildContent() {
        let content = NSView()
        window.contentView = content
        let chooseButton = button("Choose Folder…", #selector(choose))
        let homeButton = button("Scan Home", #selector(home))
        let diskButton = button("Choose Volume…", #selector(chooseVolume))
        for (b, symbol) in [(chooseButton, "folder"), (homeButton, "house"), (diskButton, "internaldrive")] {
            b.controlSize = .large
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
        }
        chooseButton.bezelColor = .controlAccentColor
        welcome = Welcome(buttons: [chooseButton, homeButton, diskButton])
        revealButton = button("Open in Finder", #selector(reveal))
        trashButton = button("Move to Trash", #selector(trash))
        let workspace = NSWorkspace.shared
        let finder = workspace.urlForApplication(withBundleIdentifier: "com.apple.finder")
        let finderIcon = finder.map { workspace.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        finderIcon?.size = NSSize(width: 19, height: 19)
        revealButton.image = finderIcon
        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        for b in [revealButton!, trashButton!] {
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            b.setAccessibilityLabel(b.title)
            b.toolTip = b.title
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        folderLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.setAccessibilityLabel("Path")
        map.hovered = { [weak self] url, kind in self?.showHover(url, kind: kind) }
        tree.hovered = { [weak self] url, key in
            guard let self else { return }
            self.showHover(url, kind: key.flatMap { self.listing?.geometry.kind(at: $0) })
        }
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        let heading = row([folderLabel, spacer(), sizeLabel], spacing: 11)
        tree.view.selectScope = { [weak self] in self?.selectAll(nil) }
        tree.selectionChanged = { [weak self] in
            guard let self, self.shelf != nil else { return }
            self.map.selection = self.tree.selectedKeys()
            if !self.tree.view.trackingSelection { self.recordVisit() }
            self.controls()
        }
        tree.view.gestureEnded = { [weak self] in self?.recordVisit(); self?.controls() }
        tree.openFolder = { [weak self] route in self?.enterFolder(route) }
        let sidebar = NSView()
        let surface = NativeTableSurface(tree.view)
        let sidebarMinimum = sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 265)
        let legendMinimum = legend.widthAnchor.constraint(greaterThanOrEqualToConstant: 225)
        let mapMinimum: CGFloat = 185
        let updateWindowMinimum = { [weak self] in
            guard let self else { return }
            let minimum = sidebarMinimum.constant + legendMinimum.constant + mapMinimum + self.split.dividerThickness * 2
            self.window.minSize.width = max(770, ceil(minimum))
        }
        surface.scroll.minimumWidthChanged = { required in
            sidebarMinimum.constant = max(265, required + 18)
            updateWindowMinimum()
        }
        legend.minimumWidthChanged = { required in
            legendMinimum.constant = max(225, required)
            updateWindowMinimum()
        }
        sidebar.addSubview(surface); surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            surface.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            surface.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 1),
            surface.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -1),
            sidebarMinimum
        ])
        map.widthAnchor.constraint(greaterThanOrEqualToConstant: mapMinimum).isActive = true
        map.zoomChanged = { [weak self] in
            guard let self else { return }
            self.toolbar.updateZoom(hasScan: self.listing != nil, scale: self.map.zoom)
            if !self.applyingNavigation && !self.busy { self.history.updateViewport(self.map.viewport) }
        }
        map.choose = { [weak self] routes, mode in
            guard let self, !self.busy || self.scanning != nil else { return }
            let prefix = self.locations.compactMap(\.item)
            self.tree.select(routes.map { prefix + $0 }, mode: mode)
            self.window.makeFirstResponder(self.tree.view)
        }
        map.menuForRoute = { [weak self] route in
            guard let self, !self.busy, let last = route.last else { return nil }
            if !self.tree.isSelected(last.key) { self.tree.reveal(self.locations.compactMap(\.item) + route) }
            return self.itemMenu()
        }
        tree.view.makeMenu = { [weak self] in self?.itemMenu() }
        split.isVertical = true
        split.delegate = self
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(map)
        split.addArrangedSubview(legend)
        legendMinimum.isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        status.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = row([spinner, status, spacer(), selectionLabel])
        for v in [heading, pathLabel, split, footer, welcome!] as [NSView] {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        for v in [heading, pathLabel] as [NSView] {
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 19),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -19)])
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 11),
            heading.heightAnchor.constraint(equalToConstant: 33),
            pathLabel.heightAnchor.constraint(equalToConstant: 17),
            footer.heightAnchor.constraint(equalToConstant: 42),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 15),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -300),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            pathLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 3),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 12),
            footer.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 4),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
            welcome.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            welcome.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            welcome.topAnchor.constraint(equalTo: content.topAnchor),
            welcome.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -3)
        ])
        welcome.wantsLayer = true
        for v in [heading, pathLabel, split] as [NSView] { v.isHidden = true }
        selectionLabel.lineBreakMode = .byTruncatingMiddle
        selectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        selectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 17).isActive = true
        let actions = row([revealButton, divider, trashButton], spacing: 8)
        actions.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 9)
        shelf = glassShelf(actions)
        content.addSubview(shelf)
        shelf.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([shelf.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            shelf.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            shelf.widthAnchor.constraint(equalToConstant: 275), shelf.heightAnchor.constraint(equalToConstant: 36)])
        mainViews = [heading, pathLabel, split]
        content.layoutSubtreeIfNeeded()
        controls()
    }

    private func showHover(_ url: URL?, kind: UInt32?) {
        let path = url?.path ?? locations.last?.url.path ?? ""
        if path != pathLabel.stringValue { pathLabel.stringValue = path; pathLabel.toolTip = path }
        legend.highlight(kind)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if preferredPanes.indices.contains(dividerIndex), let event = NSApp.currentEvent,
           event.type == .leftMouseDragged || event.type == .leftMouseDown {
            preferredPanes[dividerIndex].constant = dividerIndex == 0 ? proposedPosition
                : splitView.bounds.width - proposedPosition - splitView.dividerThickness
        }
        return proposedPosition
    }

    private var mainViews: [NSView] = []
    private func controls() {
        toolbar.update(busy: busy, scanning: scanning != nil, back: history.adjacent(-1) != nil,
            forward: history.adjacent(1) != nil, up: locations.count > 1, down: canEnterFolder, hasScan: model != nil)
        for b in welcome.actions { b.isEnabled = !busy }
        let count = tree.view.numberOfSelectedRows
        shelf.isHidden = model == nil
        if count == 1, let item = tree.firstSelected { selectionLabel.stringValue = "\(item.title)  ·  \(formatBytes(item.bytes))" }
        else { selectionLabel.stringValue = count > 1 ? "\(count.formatted()) selected" : "" }
        revealButton.isEnabled = !busy && count > 0
        trashButton.isEnabled = revealButton.isEnabled
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    @objc private func choose() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Scan"
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.scan(url) }
        }
    }
    @objc private func home() { scan(FileManager.default.homeDirectoryForCurrentUser) }
    @objc private func chooseVolume() {
        guard !busy && volumePicker == nil else { return }
        let picker = VolumePicker()
        volumePicker = picker
        picker.present(on: window) { [weak self] url in
            self?.volumePicker = nil
            if let url { self?.scan(url) }
        }
    }
    @objc private func rescan() { if let root = locations.first { scan(root.url, force: true) } }
    @objc private func refreshOrCancel() { if scanning == nil { rescan() } else { cancel() } }
    private var cancelledScan = false
    @objc private func cancel() {
        if let scanning {
            cancelledScan = true
            dt_cancel(scanning.handle)
            status.stringValue = "Cancelling…"
        }
    }

    private func scan(_ url: URL, force: Bool = false) {
        guard !busy else { return }
        let previous = force ? history.current : nil
        var previewed: ScanModel?
        obtainRoot(url, force: force, preview: { entry in
            previewed = entry.model
            self.showRoot(entry, message: "Checking cached scan")
        }) { result in
            switch result {
            case .success(let entry):
                if let previous {
                    self.restoreVisit(previous, in: entry.model, root: entry.root, rootList: entry.listing, elapsed: entry.elapsed) { restored in
                        if !restored { self.showRoot(entry) }
                        self.recordVisit(replace: true); self.controls()
                    }
                } else {
                    if previewed === entry.model {
                        self.status.stringValue = "Cached scan · \(formatCount(entry.listing.summary.entries)) entries"
                        self.status.toolTip = self.status.stringValue
                    } else { self.showRoot(entry) }
                    self.recordVisit(); self.controls()
                }
            case .failure(let error):
                self.status.stringValue = error.localizedDescription
                if previewed != nil { self.recordVisit() }
                self.controls()
            }
        }
    }
    private func showRoot(_ entry: RecentScan, message: String? = nil) {
        model = entry.model; scanTime = entry.elapsed
        locations = [Location(id: 0, url: entry.root)]
        applyingNavigation = true
        display(entry.listing, message: message)
        tree.selectSaved([], lead: nil)
        applyingNavigation = false
    }
    private func obtainRoot(_ url: URL, force: Bool = false, preview: ((RecentScan) -> Void)? = nil,
                            completion: @escaping (Result<RecentScan, Error>) -> Void) {
        busy = true; cancelledScan = false
        let progress = ScanProgress()
        scanning = progress; controls()
        let mapAspect = map.aspect
        let began = ProcessInfo.processInfo.systemUptime
        let cached = force ? nil : cache.read(url)
        let update = { [weak self] in
            guard let self, !self.cancelledScan else { return }
            self.status.stringValue = "Scanning \(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent) · \(formatCount(dt_progress_count(progress.handle))) entries"
        }
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in update() }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<RecentScan, Error> {
                let identity = RootIdentity(url)
                let watcher = ChangeWatch(url: url.resolvingSymlinksInPath(), identity: identity)
                var changes: Set<String>?
                if let cached, let identity, cached.identity == identity {
                    if let preview {
                        DispatchQueue.main.async { if !self.cancelledScan { preview(cached) } }
                    }
                    switch cached.listing.summary.issues == 0 ? cached.watcher?.changes() ?? .full : .full {
                    case .clean: return cached
                    case .paths(let paths): changes = paths
                    case .full: break
                    }
                }
                let scanned: ScanModel
                if let changes, let cached { scanned = try cached.model.refreshed(paths: changes, progress: progress) }
                else { scanned = try ScanModel(url: url, progress: progress) }
                let list = FolderListing(scanned, folder: 0, aspect: mapAspect)
                return RecentScan(model: scanned, listing: list, root: scanned.url(folder: 0, directory: true) ?? url,
                    identity: identity, watcher: watcher, elapsed: ProcessInfo.processInfo.systemUptime - began)
            }
            DispatchQueue.main.async {
                self.timer?.invalidate(); self.timer = nil; self.scanning = nil; self.busy = false
                if self.cancelledScan {
                    completion(.failure(DiskError(message: "Scan cancelled.")))
                    return
                }
                if case .success(let entry) = result, entry !== cached { self.cache.put(entry, for: url) }
                completion(result)
            }
        }
    }
    private func display(_ list: FolderListing, message: String? = nil, reloadTree: Bool = false) {
        let previous = applyingNavigation
        applyingNavigation = true
        defer { applyingNavigation = previous }
        listing = list
        tree.show(list.model, refresh: reloadTree)
        welcome.isHidden = true
        for v in mainViews { v.isHidden = false }
        if preferredPanes.isEmpty {
            window.contentView?.layoutSubtreeIfNeeded()
            let width = split.bounds.width
            if width > 0 {
                let left = split.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: max(265, min(320, width * 0.25)))
                let right = legend.widthAnchor.constraint(equalToConstant: max(245, min(345, width * 0.28)))
                left.priority = .init(900)
                right.priority = .init(910)
                preferredPanes = [left, right]
                NSLayoutConstraint.activate(preferredPanes)
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
        legend.show(list.geometry.kinds)
        showHover(nil, kind: nil)
        map.show(list, ancestors: Set(locations.compactMap { $0.item?.key }))
        map.selection = tree.selectedKeys()
        if let here = locations.last {
            folderLabel.stringValue = here.url.lastPathComponent.isEmpty ? here.url.path : here.url.lastPathComponent
            window.title = "\(folderLabel.stringValue) — DiskTally"
        }
        sizeLabel.stringValue = formatBytes(list.summary.bytes)
        var parts = [message, "\(formatCount(list.summary.entries)) \(list.summary.entries == 1 ? "entry" : "entries")", String(format: "Scan %.2f s", scanTime)].compactMap { $0 }
        if list.summary.issues > 0 { parts.append("\(formatCount(list.summary.issues)) scan errors") }
        if list.summary.boundaries > 0 { parts.append("\(formatCount(list.summary.boundaries)) mounts skipped") }
        status.stringValue = parts.joined(separator: " · ")
        status.toolTip = status.stringValue
        controls()
    }
    private func recordVisit(replace: Bool = false) {
        guard !applyingNavigation, !busy, let model, let root = locations.first, let here = locations.last else { return }
        let keys = map.selection
        if history.current?.matches(model, folder: here.url, keys: keys) == true {
            history.updateViewport(map.viewport)
            return
        }
        history.record(NavigationVisit(model: model, root: root.url, folder: here.url, folderNumber: here.id,
            keys: keys, lead: tree.leadKey, viewport: map.viewport), replace: replace)
    }
    private func trail(in model: ScanModel, root: URL, route: [DiskItem]) -> [Location]? {
        var trail = [Location(id: 0, url: root)]
        for item in route {
            guard item.isFolder, let url = model.url(folder: item.folder, slot: item.slot, directory: true) else { return nil }
            trail.append(Location(id: item.child, url: url, item: item))
        }
        return trail
    }
    private func restoreVisit(_ visit: NavigationVisit, in source: ScanModel, root: URL,
                              rootList: FolderListing?, elapsed: Double, completion: @escaping (Bool) -> Void) {
        let aspect = map.aspect, current = listing
        let apply = { (trail: [Location], list: FolderListing, keys: [UInt64], lead: UInt64?) in
            self.busy = false; self.applyingNavigation = true
            self.model = source; self.scanTime = elapsed; self.locations = trail
            if current !== list {
                self.display(list)
                self.tree.expand(trail.compactMap(\.item))
            }
            self.tree.selectSaved(keys, lead: lead)
            self.map.restoreViewport(visit.viewport)
            self.applyingNavigation = false
            completion(true)
        }
        let prepare = { () -> ([Location], FolderListing, [UInt64], UInt64?)? in
            guard let saved = visit.resolve(in: source), let trail = self.trail(in: source, root: root, route: saved.route),
                  let id = trail.last?.id else { return nil }
            let list: FolderListing
            if let current, current.model === source, current.folder == id { list = current }
            else if let rootList, id == 0, rootList.model === source { list = rootList }
            else { list = FolderListing(source, folder: id, aspect: aspect) }
            return (trail, list, saved.keys, saved.lead)
        }
        if let current, current.model === source, visit.isIn(source, at: current.folder), visit.count <= 64 {
            if let keys = visit.liveKeys(in: source) { apply(locations, current, keys, visit.lead) }
            else { completion(false) }
        } else {
            busy = true; controls()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = prepare()
                DispatchQueue.main.async {
                    if let (trail, list, keys, lead) = result { apply(trail, list, keys, lead) }
                    else { self.busy = false; completion(false) }
                }
            }
        }
    }
    @objc private func back() { travel(-1) }
    @objc private func forward() { travel(1) }
    private func travel(_ direction: Int) {
        guard !busy, let visit = history.adjacent(direction) else { return }
        let finish = { (restored: Bool) in
            if restored { self.history.step(direction) }
            else { self.history.discard(direction); self.travel(direction) }
            self.controls()
        }
        if visit.root == locations.first?.url, let model {
            restoreVisit(visit, in: model, root: visit.root, rootList: cache.read(visit.root)?.listing, elapsed: scanTime, completion: finish)
        } else {
            obtainRoot(visit.root) { result in
                switch result {
                case .success(let entry):
                    self.restoreVisit(visit, in: entry.model, root: entry.root, rootList: entry.listing, elapsed: entry.elapsed, completion: finish)
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                    if self.cancelledScan { self.controls() } else { finish(false) }
                }
            }
        }
    }
    private var canEnterFolder: Bool {
        guard tree.view.numberOfSelectedRows == 1, let item = tree.firstSelected else { return false }
        return item.isFolder && item.child != locations.last?.id
    }
    @objc private func folderDown() {
        guard canEnterFolder, let route = tree.selectedFolderRoute else { return }
        enterFolder(route)
    }
    @objc private func folderUp() {
        guard !busy, locations.count > 1 else { return }
        changeFolder(Array(locations.dropLast()), select: locations.compactMap(\.item))
    }
    private func enterFolder(_ route: [DiskItem]) {
        guard !busy, let model, let root = locations.first, let item = route.last, item.isFolder,
              item.child != locations.last?.id, let trail = trail(in: model, root: root.url, route: route) else { return }
        changeFolder(trail, select: route)
    }
    private func changeFolder(_ trail: [Location], select route: [DiskItem]) {
        guard !busy, let model, let here = trail.last else { return }
        let aspect = map.aspect
        let cached = here.id == 0 ? cache.read(here.url)?.listing : nil
        let apply = { (list: FolderListing) in
            self.busy = false; self.applyingNavigation = true; self.locations = trail
            self.display(list)
            if route.last?.child == here.id { self.tree.expand(route) }
            self.tree.reveal(route)
            self.applyingNavigation = false
            self.recordVisit(); self.controls()
        }
        if let cached, cached.model === model { apply(cached) }
        else {
            busy = true; controls()
            DispatchQueue.global(qos: .userInitiated).async {
                let list = FolderListing(model, folder: here.id, aspect: aspect)
                DispatchQueue.main.async { apply(list) }
            }
        }
    }
    @objc private func reveal() {
        guard !busy, let list = listing else { return }
        let selected = tree.selectedItems()
        let urls = selected.compactMap { item in
            list.model.url(folder: item.folder, slot: item.slot, directory: item.isFolder)
        }
        if let first = selected.first, first.isFolder, selected.count == 1, let url = urls.first,
           let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { NSApp.presentError(error) } }
            }
        } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    private func selectedURLs() -> [URL] {
        guard let model else { return [] }
        return tree.selectedItems().compactMap { model.url(folder: $0.folder, slot: $0.slot, directory: $0.isFolder) }
    }
    private func itemMenu() -> NSMenu? {
        guard !busy, tree.view.numberOfSelectedRows > 0 else { return nil }
        let menu = NSMenu()
        func command(_ name: String, _ symbol: String, _ action: Selector) {
            let item = menu.addItem(withTitle: name, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        command("Open", "arrow.up.forward.app", #selector(openSelection))
        menu.addItem(withTitle: "Open With", action: nil, keyEquivalent: "").submenu = ApplicationMenu(window: window) { [weak self] in self?.selectedURLs() ?? [] }
        command("Open in Finder", "magnifyingglass", #selector(reveal))
        menu.addItem(.separator())
        command("Refresh", "arrow.clockwise", #selector(refreshSelection))
        menu.addItem(.separator())
        command("Move to Trash…", "trash", #selector(trash))
        return menu
    }
    @objc private func openSelection() {
        guard !busy else { return }
        for url in selectedURLs() {
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { NSApp.presentError(error) } }
            }
        }
    }
    @objc private func refreshSelection() {
        guard !busy, let old = model, let root = locations.first else { return }
        let items = tree.selectedItems(rootsOnly: true)
        guard !items.isEmpty else { return }
        recordVisit()
        let previous = history.current
        let expansions = tree.expandedURLs
        let mapAspect = map.aspect
        let focus = locations
        let progress = ScanProgress()
        scanning = progress; busy = true; controls()
        status.stringValue = "Refreshing selection…"
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let updated = try old.refreshed(items, progress: progress)
                let trail = focus.reversed().compactMap { updated.route(to: $0.url) }.first ?? []
                var locations = [root]
                for item in trail {
                    if let url = updated.url(folder: item.folder, slot: item.slot, directory: true) {
                        locations.append(Location(id: item.child, url: url, item: item))
                    }
                }
                let restored = locations
                let list = FolderListing(updated, folder: restored.last!.id, aspect: mapAspect)
                let opened = expansions.compactMap { updated.route(to: $0) }
                let selected = previous?.liveKeys(in: updated) ?? []
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                DispatchQueue.main.async {
                    self.cache.remove(old)
                    self.scanning = nil; self.busy = false; self.model = updated; self.locations = restored
                    self.display(list, message: String(format: "Refreshed in %.2f s", elapsed))
                    self.applyingNavigation = true
                    for route in opened { self.tree.expand(route) }
                    self.tree.selectSaved(selected, lead: nil)
                    if previous?.folder == restored.last?.url, let previous { self.map.restoreViewport(previous.viewport) }
                    self.applyingNavigation = false
                    self.recordVisit(replace: true)
                    self.controls()
                }
            } catch {
                DispatchQueue.main.async {
                    self.scanning = nil; self.busy = false; self.status.stringValue = error.localizedDescription; self.controls()
                }
            }
        }
    }
    @objc private func trash() {
        guard !busy, let list = listing else { return }
        let selected = tree.selectedIDs()
        guard !selected.isEmpty else { return }
        let previousStatus = status.stringValue
        busy = true; status.stringValue = "Reviewing selection…"; controls()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try TrashPlan(model: list.model, keys: selected) }
            DispatchQueue.main.async {
                self.status.stringValue = previousStatus
                switch result {
                case .failure(let error):
                    self.busy = false; self.controls()
                    self.trashProblem(title: "This selection can’t be moved to Trash", detail: error.localizedDescription)
                case .success(let plan):
                    let sheet = TrashReview(plan)
                    self.trashReview = sheet
                    self.spinner.stopAnimation(nil)
                    sheet.present(on: self.window) { acknowledged in
                        self.trashReview = nil
                        guard let acknowledged else { self.busy = false; self.controls(); return }
                        self.moveReviewed(plan, acknowledged: acknowledged)
                    }
                }
            }
        }
    }

    private func moveReviewed(_ plan: TrashPlan, acknowledged: Bool) {
        let trail = locations, aspect = map.aspect
        status.stringValue = "Moving selection to Trash…"; controls()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = plan.perform(acknowledged: acknowledged)
            let surviving = Array(trail.prefix { location in
                guard let item = location.item else { return true }
                return plan.model.url(folder: item.folder, slot: item.slot, directory: true) != nil
            })
            let fresh = result.moved > 0 ? FolderListing(plan.model, folder: surviving.last?.id ?? 0, aspect: aspect) : nil
            DispatchQueue.main.async {
                self.busy = false
                let message = "\(result.moved.formatted()) moved to Trash"
                if let fresh {
                    self.cache.remove(plan.model)
                    self.locations = surviving
                    self.display(fresh, message: message, reloadTree: true)
                    self.recordVisit(replace: true)
                } else {
                    self.status.stringValue = "Selection stayed in place"
                    self.controls()
                }
                if let detail = result.explanation {
                    let title = result.moved == 0 ? "Couldn’t move selection to Trash" : "\(result.moved.formatted()) moved · \(result.failed.formatted()) couldn’t be moved"
                    self.trashProblem(title: title, detail: detail, url: result.firstUnmovedURL)
                }
            }
        }
    }

    private func trashProblem(title: String, detail: String, url: URL? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if url != nil { alert.addButton(withTitle: "Show in Finder") }
        alert.beginSheetModal(for: window) { answer in
            if answer == .alertSecondButtonReturn, let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

let application = NSApplication.shared
let delegate = DiskApp()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
