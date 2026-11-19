import AppKit

private struct Location { let id: UInt32; let url: URL; var item: DiskItem? = nil }

final class DiskApp: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private let tree = Outline()
    private let map = Treemap()
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
    private var scanning: ScanProgress?
    private var timer: Timer?
    private var busy = false
    private var scanTime: Double = 0
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DiskTally"
        window.minSize = NSSize(width: 700, height: 410)
        window.center()
        window.setFrameAutosaveName("DiskTallyMain")
        toolbar = WindowToolbar(target: self, commands: [
            .init(id: "zoomOut", title: "Zoom Out", symbol: "minus.magnifyingglass", action: #selector(zoomOut)),
            .init(id: "zoomIn", title: "Zoom In", symbol: "plus.magnifyingglass", action: #selector(zoomIn)),
            .init(id: "back", title: "Enclosing Folder", symbol: "chevron.left", action: #selector(back)),
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
        func menu(_ name: String) -> NSMenu {
            let item = NSMenuItem()
            let sub = NSMenu(title: name)
            main.addItem(item)
            item.submenu = sub
            return sub
        }
        let app = menu("DiskTally")
        app.addItem(withTitle: "Quit DiskTally", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = menu("File")
        file.addItem(withTitle: "Choose Volume…", action: #selector(chooseVolume), keyEquivalent: "").target = self
        file.addItem(withTitle: "Choose Folder…", action: #selector(choose), keyEquivalent: "o").target = self
        file.addItem(withTitle: "Rescan", action: #selector(rescan), keyEquivalent: "r").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Open in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        file.addItem(withTitle: "Move to Trash…", action: #selector(trash), keyEquivalent: "\u{8}").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let view = menu("View")
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+").target = self
        let plus = view.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        plus.target = self; plus.isAlternate = true
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-").target = self
        view.addItem(withTitle: "Fit Map", action: #selector(fitMap), keyEquivalent: "0").target = self
        let fit = view.addItem(withTitle: "Zoom to Selection", action: #selector(fitSelection), keyEquivalent: "f")
        fit.target = self; fit.keyEquivalentModifierMask = [.command, .shift]
        menu("Go").addItem(withTitle: "Enclosing Folder", action: #selector(back), keyEquivalent: "[").target = self
        NSApp.mainMenu = main
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(trash), #selector(reveal): return !busy && tree.view.numberOfSelectedRows > 0
        case #selector(zoomIn): return listing != nil
        case #selector(zoomOut), #selector(fitMap): return listing != nil && map.zoom > 1
        case #selector(fitSelection): return tree.view.numberOfSelectedRows > 0
        case #selector(rescan): return !busy && !locations.isEmpty
        case #selector(back): return !busy && locations.count > 1
        default: return !busy
        }
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
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        let heading = row([folderLabel, spacer(), sizeLabel], spacing: 11)
        tree.selectionChanged = { [weak self] in
            guard let self, self.shelf != nil else { return }
            self.map.selection = self.tree.selectedKeys()
            self.controls()
        }
        tree.openFolder = { [weak self] route in self?.zoom(to: route) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tree.view
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 265).isActive = true
        map.widthAnchor.constraint(greaterThanOrEqualToConstant: 185).isActive = true
        map.zoomChanged = { [weak self] in
            guard let self else { return }
            self.toolbar.updateZoom(hasScan: self.listing != nil, scale: self.map.zoom)
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
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(map)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
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
        split.setPosition(350, ofDividerAt: 0)
        controls()
    }

    private var mainViews: [NSView] = []
    private func controls() {
        toolbar.update(busy: busy, scanning: scanning != nil, canGoBack: locations.count > 1, hasScan: model != nil)
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
    @objc private func cancel() {
        if let scanning { dt_cancel(scanning.handle); status.stringValue = "Cancelling…" }
    }
    private func scan(_ url: URL, force: Bool = false) {
        guard !busy else { return }
        busy = true
        let progress = ScanProgress()
        scanning = progress
        controls()
        let mapAspect = map.aspect
        let began = ProcessInfo.processInfo.systemUptime
        let cached = force ? nil : cache.read(url)
        let update = { [weak self] in
            self?.status.stringValue = "Scanning \(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent) · \(formatCount(dt_progress_count(progress.handle))) entries"
        }
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in update() }
        DispatchQueue.global(qos: .userInitiated).async {
            let identity = RootIdentity(url)
            let watcher = ChangeWatch(url: url.resolvingSymlinksInPath(), identity: identity)
            var changedPaths: Set<String>?
            if let cached, let identity, cached.identity == identity {
                DispatchQueue.main.async {
                    self.model = cached.model; self.scanTime = cached.elapsed
                    self.locations = [Location(id: 0, url: cached.root)]
                    self.display(cached.listing, message: "Checking cached scan")
                }
                let delta = cached.listing.summary.issues == 0 ? cached.watcher?.changes() ?? .full : .full
                if case .paths(let paths) = delta { changedPaths = paths }
                if case .clean = delta {
                    DispatchQueue.main.async {
                        self.timer?.invalidate(); self.timer = nil; self.scanning = nil; self.busy = false
                        self.status.stringValue = "Cached scan · \(formatCount(cached.listing.summary.entries)) entries"
                        self.controls()
                    }
                    return
                }
            }
            let result = Result {
                if let changedPaths, let cached { return try cached.model.refreshed(paths: changedPaths, progress: progress) }
                return try ScanModel(url: url, progress: progress)
            }
            let first = try? result.get()
            let list = first.map { FolderListing($0, folder: 0, aspect: mapAspect) }
            DispatchQueue.main.async {
                self.timer?.invalidate()
                self.timer = nil
                self.scanning = nil
                self.busy = false
                if let first, let list {
                    self.model = first
                    self.scanTime = ProcessInfo.processInfo.systemUptime - began
                    self.locations = [Location(id: 0, url: first.url(folder: 0, directory: true) ?? url)]
                    self.cache.put(RecentScan(model: first, listing: list, root: self.locations[0].url,
                        identity: identity, watcher: watcher, elapsed: self.scanTime), for: url)
                    self.display(list)
                } else if case .failure(let error) = result {
                    self.status.stringValue = error.localizedDescription
                    self.controls()
                }
            }
        }
    }
    private func display(_ list: FolderListing, message: String? = nil, reloadTree: Bool = false) {
        listing = list
        tree.show(list.model, refresh: reloadTree)
        welcome.isHidden = true
        for v in mainViews { v.isHidden = false }
        map.show(list, ancestors: Set(locations.compactMap { $0.item?.key }))
        map.selection = tree.selectedKeys()
        if let here = locations.last {
            folderLabel.stringValue = here.url.lastPathComponent.isEmpty ? here.url.path : here.url.lastPathComponent
            window.title = "\(folderLabel.stringValue) — DiskTally"
            pathLabel.stringValue = here.url.path
            pathLabel.toolTip = here.url.path
        }
        sizeLabel.stringValue = formatBytes(list.summary.bytes)
        var parts = [message, "\(formatCount(list.summary.entries)) \(list.summary.entries == 1 ? "entry" : "entries")", String(format: "Scan %.2f s", scanTime)].compactMap { $0 }
        if list.summary.issues > 0 { parts.append("\(formatCount(list.summary.issues)) scan errors") }
        if list.summary.boundaries > 0 { parts.append("\(formatCount(list.summary.boundaries)) mounts skipped") }
        status.stringValue = parts.joined(separator: " · ")
        status.toolTip = status.stringValue
        controls()
    }
    private func loadLocation() {
        guard !busy, let model, let here = locations.last else { return }
        let mapAspect = map.aspect
        busy = true
        controls()
        DispatchQueue.global(qos: .userInitiated).async {
            let list = FolderListing(model, folder: here.id, aspect: mapAspect)
            DispatchQueue.main.async { self.busy = false; self.display(list) }
        }
    }
    @objc private func back() {
        guard !busy, locations.count > 1 else { return }
        locations.removeLast()
        loadLocation()
    }
    private func zoom(to route: [DiskItem]) {
        guard !busy, let model, let root = locations.first, route.last?.isFolder == true else { return }
        var trail = [root]
        for item in route {
            guard let url = model.url(folder: item.folder, slot: item.slot, directory: true) else { return }
            trail.append(Location(id: item.child, url: url, item: item))
        }
        locations = trail
        tree.reveal(route)
        loadLocation()
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
        let selections = selectedURLs()
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
                let selected = selections.compactMap { updated.route(to: $0) }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                DispatchQueue.main.async {
                    self.cache.remove(old)
                    self.scanning = nil; self.busy = false; self.model = updated; self.locations = restored
                    self.display(list, message: String(format: "Refreshed in %.2f s", elapsed))
                    self.tree.restore(expansions: opened, selections: selected)
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
