import AppKit
import Sparkle

private struct Location { let id: UInt32; let url: URL; var item: DiskItem? = nil }

private struct PriorWorkspace {
    let list: FolderListing?, locations: [Location], expanded: [URL], keys: [UInt64], lead: UInt64?
    let viewport: CGRect, ranked: Set<URL>
}

private struct LiveSnapshot {
    let scan: RecentScan, list: FolderListing, trail: [Location]
    let colors: MapBreakdown?, order: MapGroupOrder?, ranked: [RankedFile]?
    let frame: LiveMapFrame?, settings: MapRenderSettings?, rings: Rings?
    let sort: (key: String, ascending: Bool)
    let checkpointNotices: Int
}

final class DiskApp: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSSplitViewDelegate {
    private var window: PreviewWindow!
    private let tree = Outline()
    private let map = Treemap()
    private let sunburst = Sunburst()
    private let mapStyle = NSSegmentedControl(labels: ["Treemap", "Sunburst"], trackingMode: .selectOne, target: nil, action: nil)
    private let sidebarTabs = NSSegmentedControl(labels: ["Folders", "Largest Files"], trackingMode: .selectOne, target: nil, action: nil)
    private let largest = LargestFiles()
    private let liveSwitch = NSSwitch()
    private let liveDot = LiveStatusDot()
    private let updates = LiveUpdates()
    private let liveCheckpoints = LiveCheckpointWriter()
    private var publishingLive = false
    private let listHost = NSView()
    private var treeSurface: NativeTableSurface!
    private var scanWorkspace: ScanWorkspace?
    private var finishedScanFrame: (ScanMapRequest, ScanMapFrame)?
    private var browsedDuringScan = false
    private weak var rankedScope: FolderListing?
    private var rankingWork: UUID?
    private var pendingRankSelection: Set<URL>?
    private var usingSunburst: Bool { mapStyle.selectedSegment == 1 }
    private var showingLargest: Bool { sidebarTabs.selectedSegment == 1 }
    private let legend = KindLegend()
    private var colorMode = MapColorMode(rawValue: UserDefaults.standard.integer(forKey: "DiskSlopColorMode")) ?? .kind
    private var colorWork: ScanProgress?
    private var recentColors: [MapBreakdown] = []
    private let colorQueue = DispatchQueue(label: "local.diskslop.color-groups", qos: .userInitiated)
    private let split = NSSplitView()
    private let sidebarWidthKey = "DiskSlopSidebarWidth"
    private let legendWidthKey = "DiskSlopLegendWidth"
    private var preferredPanes: [NSLayoutConstraint] = []
    private let updateDriver = AppUpdateDriver(hostBundle: .main, delegate: nil)
    private lazy var appUpdater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                             userDriver: updateDriver, delegate: updateDriver)
    private lazy var appearance = AppearanceSettings(updater: appUpdater)
    private let folderIcon = NSImageView()
    private let folderLabel = NSTextField(labelWithString: "DiskSlop")
    private let pathLabel = NSTextField(labelWithString: "Choose a folder or scan your startup data volume.")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let scanBadge = ScanBadge()
    private var toolbar: WindowToolbar!
    private var welcome: Welcome!
    private var shelf: NSView!
    private let selectionLabel = NSTextField(labelWithString: "")
    private var trashButton: NSButton!, revealButton: NSButton!, parentButton: NSButton!
    private var pendingParentFile: URL?
    private var model: ScanModel?
    private let cache = ScanCache()
    private var volumePicker: VolumePicker?
    private var trashReview: TrashReview?
    private let trashGlass = TrashGlass()
    private var listing: FolderListing?
    private var locations: [Location] = []
    private var history = SelectionHistory()
    private var applyingNavigation = false
    private var scanning: ScanProgress?
    private var timer: Timer?
    private var busy = false
    private var scanTime: Double = 0
    private var pendingURL: URL?
    private var movingToTrash = false
    private var waitingToQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearance.apply()
        buildMenus()
        window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DiskSlop"
        window.clearBrowserSelection = { [weak self] in self?.clearSelection() ?? false }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 770, height: 410)
        window.acceptsMouseMovedEvents = true
        window.center()
        window.setFrameAutosaveName("DiskSlopMain")
        toolbar = WindowToolbar(target: self, commands: [
            .init(id: "zoomOut", title: "Zoom Out", symbol: "minus.magnifyingglass", action: #selector(zoomOut)),
            .init(id: "zoomIn", title: "Zoom In", symbol: "plus.magnifyingglass", action: #selector(zoomIn)),
            .init(id: "back", title: "Back", symbol: "chevron.backward", action: #selector(back)),
            .init(id: "forward", title: "Forward", symbol: "chevron.forward", action: #selector(forward)),
            .init(id: "update", title: "Update available", symbol: "arrow.down.circle.fill", action: #selector(installAvailableUpdate)),
            .init(id: "choose", title: "Choose Folder…", symbol: "folder.badge.plus", action: #selector(choose)),
            .init(id: "home", title: "Scan Home", symbol: "house", action: #selector(home)),
            .init(id: "disk", title: "Choose Volume…", symbol: "externaldrive", action: #selector(chooseVolume)),
            .init(id: "refresh", title: "Rescan", symbol: "arrow.clockwise", action: #selector(refreshOrCancel))
        ], window: window)
        buildContent()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateDriver.availabilityChanged = { [weak self] available in self?.toolbar.setUpdateAvailable(available) }
        DispatchQueue.main.async {
            do {
                try self.appUpdater.start()
                if self.appUpdater.automaticallyChecksForUpdates { self.appUpdater.checkForUpdatesInBackground() }
            } catch { NSApp.presentError(error) }
        }
        let argumentURL = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let url = pendingURL ?? argumentURL { scan(url) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if window == nil { pendingURL = url } else if !busy { scan(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard movingToTrash else { return .terminateNow }
        waitingToQuit = true
        return .terminateLater
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        trashGlass.dock.prepare()
        if let welcome, !welcome.isHidden { welcome.refreshCapacity() }
    }
    func applicationWillTerminate(_ notification: Notification) { updates.follow(nil); liveCheckpoints.cancel() }

    @objc private func installAvailableUpdate() { updateDriver.installAvailableUpdate() }
    @objc private func checkForAppUpdates() { updateDriver.checkFromMenu(using: appUpdater) }

    private func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""), submenu = NSMenu(title: title)
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
        let app = menu("DiskSlop")
        command(app, "About DiskSlop", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), responder: true)
        command(app, "Check for Updates…", #selector(checkForAppUpdates))
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppearanceSettings.show(_:)), keyEquivalent: ",").target = appearance
        app.addItem(.separator())
        command(app, "Hide DiskSlop", #selector(NSApplication.hide(_:)), "h", responder: true)
        command(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], responder: true)
        command(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), responder: true)
        app.addItem(.separator())
        command(app, "Quit DiskSlop", #selector(NSApplication.terminate(_:)), "q", responder: true)

        let file = menu("File")
        command(file, "Choose Folder…", #selector(choose), "o")
        command(file, "Choose Volume…", #selector(chooseVolume), "o", [.command, .shift])
        command(file, "Scan Home", #selector(home), "h", [.command, .shift])
        file.addItem(.separator())
        command(file, "Rescan", #selector(rescan), "r")
        command(file, "Force Full Scan", #selector(forceFullScan), "r", [.command, .shift])
        command(file, "Refresh Selection", #selector(refreshSelection))
        command(file, "Cancel Scan", #selector(cancel))
        file.addItem(.separator())
        command(file, "Open Selected Items", #selector(openSelection))
        command(file, "Quick Look", #selector(quickLook), " ", [])
        command(file, "Open in Finder", #selector(reveal))
        command(file, "Move to Trash", #selector(trash), "\u{8}")
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
        command(view, "Treemap", #selector(chooseTreemap), "1")
        command(view, "Sunburst", #selector(chooseSunburst), "2")
        command(view, "Largest Files", #selector(showLargest), "3")
        view.addItem(.separator())
        let colors = NSMenu(title: "Color By")
        MapColorMode.populate(colors, target: self, action: #selector(chooseColorMode(_:)))
        view.addItem(withTitle: "Color By", action: nil, keyEquivalent: "").submenu = colors
        view.addItem(.separator())
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
        command(go, "Show Parent Folder", #selector(showParentFolder))
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
    private var hasSelection: Bool { showingLargest ? largest.table.numberOfSelectedRows > 0 : tree.view.numberOfSelectedRows > 0 }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForAppUpdates) {
            menuItem.title = updateDriver.menuTitle
            return updateDriver.hasOffer || appUpdater.canCheckForUpdates
        }
        if menuItem.action == #selector(quickLook) {
            return browserIsKey && !(window.firstResponder is NSTextView) && (showingLargest ? !largest.selected.isEmpty : hasSelection)
        }
        if scanWorkspace != nil, menuItem.action == #selector(reveal) || menuItem.action == #selector(openSelection) {
            return browserIsKey && hasSelection
        }
        if menuItem.action == #selector(showParentFolder) { return browserIsKey && canShowParent }
        if menuItem.action == #selector(chooseSunburst) || menuItem.action == #selector(chooseTreemap) {
            menuItem.state = (menuItem.action == #selector(chooseSunburst)) == usingSunburst ? .on : .off
            return browserIsKey && (scanWorkspace != nil || (listing != nil && !busy))
        }
        if menuItem.action == #selector(showLargest) {
            menuItem.state = showingLargest ? .on : .off
            return browserIsKey && (scanWorkspace != nil || (listing != nil && !busy))
        }
        if menuItem.action == #selector(chooseColorMode(_:)) {
            menuItem.state = menuItem.tag == colorMode.rawValue ? .on : .off
            return browserIsKey && listing != nil
        }
        if menuItem.action == #selector(cancel) { return browserIsKey && scanning != nil }
        guard browserIsKey, !busy else { return false }
        switch menuItem.action {
        case #selector(copyPaths):
            menuItem.title = tree.view.numberOfSelectedRows == 1 ? "Copy Pathname" : "Copy Pathnames"
            return hasSelection
        case #selector(trash):
            menuItem.title = tree.view.numberOfSelectedRows > 1 ? "Move to Trash…" : "Move to Trash"
            return hasSelection && !tree.isSelected(DiskItem.scanRootKey)
        case #selector(copy(_:)), #selector(deselectAll), #selector(reveal),
             #selector(openSelection), #selector(refreshSelection), #selector(fitSelection):
            return hasSelection
        case #selector(selectAll(_:)): return (listing?.summary.entries ?? 0) > 0
        case #selector(zoomIn): return usingSunburst ? canDrill : listing != nil && map.zoom < CGFloat(1 << 30)
        case #selector(zoomOut), #selector(fitMap): return usingSunburst ? locations.count > 1 : listing != nil && map.zoom > 1
        case #selector(rescan), #selector(forceFullScan): return !locations.isEmpty
        case #selector(back): return history.adjacent(-1) != nil
        case #selector(forward): return history.adjacent(1) != nil
        case #selector(folderUp): return locations.count > 1
        case #selector(folderDown): return canEnterFolder
        default: return true
        }
    }
    @objc func selectAll(_ sender: Any?) {
        guard browserIsKey, !busy else { return }
        if showingLargest { largest.table.selectAll(nil); return }
        tree.selectAll(in: locations.compactMap(\.item))
    }
    @objc private func deselectAll() { _ = clearSelection() }
    private func clearSelection() -> Bool {
        guard browserIsKey, !busy || scanning != nil,
              hasSelection || tree.view.numberOfSelectedRows > 0 || (showingLargest && pendingRankSelection?.isEmpty == false) else { return false }
        pendingParentFile = nil
        pendingRankSelection = rankingWork == nil ? nil : []
        if largest.table.numberOfSelectedRows > 0 { largest.table.deselectAll(nil) }
        if tree.view.numberOfSelectedRows > 0 { tree.selectSaved([], lead: nil) }
        return true
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
    @objc private func zoomIn() { if usingSunburst { drillSelection() } else { map.stepZoom(inward: true) } }
    @objc private func zoomOut() { if usingSunburst { folderUp() } else { map.stepZoom(inward: false) } }
    @objc private func fitMap() {
        if usingSunburst, let root = locations.first { changeFolder([root], select: []) } else { map.fitMap() }
    }
    @objc private func fitSelection() { if usingSunburst { drillSelection() } else { map.fitSelection() } }
    private var canDrill: Bool {
        if canEnterFolder { return true }
        if let item = tree.firstSelected, item.folder != locations.last?.id { return true }
        return false
    }
    private func drillSelection() {
        guard !busy, let item = tree.firstSelected, let model, var route = model.route(to: DTKey(item.key), from: 0) else { return }
        if !item.isFolder { route.removeLast() }
        enterFolder(route)
    }
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
        parentButton = button("Show Parent Folder", #selector(showParentFolder))
        trashButton = button("Move to Trash", #selector(trash))
        let workspace = NSWorkspace.shared
        let finder = workspace.urlForApplication(withBundleIdentifier: "com.apple.finder")
        let finderIcon = finder.map { workspace.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        finderIcon?.size = NSSize(width: 19, height: 19)
        revealButton.image = finderIcon
        parentButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        for b in [revealButton!, parentButton!, trashButton!] {
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            b.setAccessibilityLabel(b.title)
            b.toolTip = b.title
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        parentButton.toolTip = "Select the parent of this file or folder and highlight its contents on the map."
        parentButton.setAccessibilityHelp(parentButton.toolTip)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        folderIcon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([folderIcon.widthAnchor.constraint(equalToConstant: 30),
            folderIcon.heightAnchor.constraint(equalTo: folderIcon.widthAnchor)])
        folderLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.setAccessibilityLabel("Path")
        map.hovered = { [weak self] url, kind in self?.showHover(url, kind: kind) }
        legend.choosing(colorMode, loading: false)
        legend.modeChanged = { [weak self] mode in self?.selectColorMode(mode) }
        map.coloringDidDisplay = { [weak self] colors in
            guard let self, let list = self.listing else { return }
            if let colors { self.legend.show(colors) } else { self.legend.show(list.geometry.kinds) }
            if self.usingSunburst { self.sunburst.show(list, colors: colors) }
            self.legend.choosing(self.colorMode, loading: (colors?.mode ?? .kind) != self.colorMode)
        }
        tree.hovered = { [weak self] url, key in
            guard let self else { return }
            self.showHover(url, kind: key.flatMap { self.map.colorGroup(for: $0, directory: url?.hasDirectoryPath == true) })
        }
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        mapStyle.target = self; mapStyle.action = #selector(switchMap)
        mapStyle.selectedSegment = UserDefaults.standard.bool(forKey: "DiskSlopSunburst") ? 1 : 0
        mapStyle.setAccessibilityLabel("Map style")
        liveSwitch.controlSize = .small
        liveSwitch.target = self; liveSwitch.action = #selector(toggleLive)
        liveSwitch.state = UserDefaults.standard.bool(forKey: "DiskSlopLiveUpdates") ? .on : .off
        liveSwitch.setAccessibilityLabel("Live updates")
        let liveLabel = NSTextField(labelWithString: "Live")
        liveLabel.font = .systemFont(ofSize: 12, weight: .medium)
        liveLabel.setAccessibilityElement(false)
        updates.refresh = { [weak self] entry, progress, changes in self?.refreshLive(entry, progress: progress, changes: changes) }
        let heading = row([row([folderIcon, folderLabel], spacing: 7), spacer(), row([liveDot, liveLabel, liveSwitch], spacing: 5), mapStyle, sizeLabel], spacing: 11)
        tree.view.selectScope = { [weak self] in self?.selectAll(nil) }
        tree.selectionChanged = { [weak self] in
            guard let self, self.shelf != nil, !self.publishingLive else { return }
            if self.scanWorkspace != nil, !self.applyingNavigation { self.browsedDuringScan = true }
            self.map.selection = self.tree.selectedKeys()
            self.sunburst.selection = self.map.selection
            self.window.selectionDidChange { self.selectedURLs() }
            if !self.tree.view.trackingSelection { self.recordVisit() }
            self.controls()
        }
        tree.view.gestureEnded = { [weak self] in self?.recordVisit(); self?.controls() }
        tree.openFolder = { [weak self] route in self?.enterFolder(route) }
        let sidebar = NSView()
        let surface = NativeTableSurface(tree.view, preferencesName: "Folders")
        treeSurface = surface
        sidebarTabs.target = self; sidebarTabs.action = #selector(chooseSidebar)
        sidebarTabs.selectedSegment = UserDefaults.standard.bool(forKey: "DiskSlopLargestFilesTab") ? 1 : 0
        sidebarTabs.setAccessibilityLabel("File list")
        largest.selectionChanged = { [weak self] in
            guard let self else { return }
            if self.rankingWork != nil { self.pendingRankSelection = Set(self.largest.selected.map(\.url)) }
            self.rankedSelectionChanged()
        }
        largest.openFile = { [weak self] in self?.quickLook() }
        largest.table.makeMenu = { [weak self] in
            guard let self else { return nil }
            return self.itemMenu()
        }
        largest.table.hovered = { [weak self] i in
            guard let self, self.showingLargest else { return }
            let row = self.largest.rows.indices.contains(i) ? self.largest.rows[i] : nil
            self.showHover(row?.url, kind: row.flatMap(self.rankedColorGroup))
        }
        let sidebarMinimum = sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 265)
        let legendMinimum = legend.widthAnchor.constraint(greaterThanOrEqualToConstant: 225)
        let mapMinimum: CGFloat = 185
        // Keep table measurements below AppKit's priority for preserving the window frame.
        sidebarMinimum.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        legendMinimum.priority = sidebarMinimum.priority
        surface.scroll.minimumWidthChanged = { required in
            sidebarMinimum.constant = max(265, required + 18)
        }
        legend.minimumWidthChanged = { required in
            legendMinimum.constant = max(225, required)
        }
        sidebar.addSubview(sidebarTabs); sidebarTabs.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(listHost); listHost.translatesAutoresizingMaskIntoConstraints = false
        place(surface, in: listHost)
        place(largest.view, in: listHost)
        largest.view.isHidden = !showingLargest
        surface.isHidden = showingLargest
        NSLayoutConstraint.activate([
            sidebarTabs.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
            sidebarTabs.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 1),
            listHost.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            listHost.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            listHost.topAnchor.constraint(equalTo: sidebarTabs.bottomAnchor, constant: 6),
            listHost.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -1),
            sidebarMinimum
        ])
        let mapHost = NSView()
        mapHost.widthAnchor.constraint(greaterThanOrEqualToConstant: mapMinimum).isActive = true
        place(map, in: mapHost); place(sunburst, in: mapHost)
        map.setPresented(!usingSunburst); sunburst.isHidden = !usingSunburst
        map.zoomChanged = { [weak self] in
            guard let self else { return }
            if self.scanWorkspace != nil, !self.publishingLive, !self.applyingNavigation { self.browsedDuringScan = true }
            self.updateZoom()
            if !self.applyingNavigation && !self.busy { self.history.updateViewport(self.map.viewport) }
        }
        map.choose = { [weak self] routes, mode in
            guard let self, !self.busy || self.scanning != nil else { return }
            self.showFolders()
            let prefix = self.locations.compactMap(\.item)
            self.tree.select(routes.map { prefix + $0 }, mode: mode)
            self.window.makeFirstResponder(self.tree.view)
        }
        map.menuForRoute = { [weak self] route in
            guard let self, !self.busy || self.scanWorkspace != nil, let last = route.last else { return nil }
            self.showFolders()
            if !self.tree.isSelected(last.key) { self.tree.reveal(self.locations.compactMap(\.item) + route) }
            return self.itemMenu()
        }
        tree.view.makeMenu = { [weak self] in self?.itemMenu() }
        sunburst.choose = map.choose; sunburst.menuForRoute = map.menuForRoute; sunburst.hovered = map.hovered
        sunburst.enter = { [weak self] route in
            guard let self else { return }
            self.enterFolder(self.locations.compactMap(\.item) + route)
        }
        sunburst.up = { [weak self] in self?.folderUp() }
        sunburst.open = { [weak self] in self?.quickLook() }
        split.isVertical = true
        split.delegate = self
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(mapHost)
        split.addArrangedSubview(legend)
        legendMinimum.isActive = true
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.setHoldingPriority(.init(260), forSubviewAt: 2)
        status.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = row([scanBadge, spinner, status, spacer(), selectionLabel])
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
        let actions = row([revealButton, parentButton, divider, trashButton], spacing: 8)
        actions.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 9)
        shelf = glassShelf(actions)
        content.addSubview(shelf)
        shelf.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([footer.trailingAnchor.constraint(equalTo: shelf.leadingAnchor, constant: -12),
            shelf.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            shelf.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            shelf.widthAnchor.constraint(equalToConstant: ceil(actions.fittingSize.width)), shelf.heightAnchor.constraint(equalToConstant: 36)])
        mainViews = [heading, pathLabel, split]
        content.layoutSubtreeIfNeeded()
        controls()
    }

    private func place(_ child: NSView, in host: NSView) {
        if child.superview !== host { child.removeFromSuperview(); host.addSubview(child) }
        child.frame = host.bounds; child.autoresizingMask = [.width, .height]
    }
    @objc private func chooseTreemap() { mapStyle.selectedSegment = 0; switchMap() }
    @objc private func chooseSunburst() { mapStyle.selectedSegment = 1; switchMap() }
    @objc private func switchMap() {
        map.setPresented(!usingSunburst); sunburst.isHidden = !usingSunburst
        UserDefaults.standard.set(usingSunburst, forKey: "DiskSlopSunburst")
        showHover(nil, kind: nil)
        sunburst.show(usingSunburst ? listing : nil, colors: map.displayedColors)
        updateZoom()
    }
    private func updateZoom() {
        if usingSunburst { toolbar.updateZoom(inward: !busy && canDrill, outward: !busy && locations.count > 1) }
        else { toolbar.updateZoom(hasScan: listing != nil, scale: map.zoom) }
    }
    @objc private func showLargest() { sidebarTabs.selectedSegment = 1; chooseSidebar(); window.makeFirstResponder(largest.table) }
    private func showFolders() { if sidebarTabs.selectedSegment != 0 { sidebarTabs.selectedSegment = 0; switchSidebar() } }
    @objc private func chooseSidebar() {
        UserDefaults.standard.set(sidebarTabs.selectedSegment == 1, forKey: "DiskSlopLargestFilesTab")
        switchSidebar()
    }
    private func switchSidebar() {
        let ranked = sidebarTabs.selectedSegment == 1
        treeSurface.isHidden = ranked; largest.view.isHidden = !ranked
        if ranked, let scanWorkspace {
            updateScanRanking(scanWorkspace)
            rankedSelectionChanged()
        } else if ranked, let listing {
            if rankedScope === listing && rankingWork == nil { rankedSelectionChanged() }
            else { loadLargest(listing) }
        }
        if !ranked { window.makeFirstResponder(tree.view) }
        controls()
    }
    private func loadLargest(_ list: FolderListing, keepingRows: Bool = false) {
        guard rankedScope !== list else { return }
        rankedScope = list
        if pendingRankSelection == nil { pendingRankSelection = Set(largest.selected.map(\.url)) }
        if !keepingRows { largest.replace([], keeping: []) }
        let token = UUID(); rankingWork = token
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = dt_largest_files(list.model.handle, list.folder).map(RankedFile.read) ?? []
            DispatchQueue.main.async {
                guard self.rankingWork == token, self.listing === list, self.scanWorkspace == nil else { return }
                self.rankingWork = nil
                self.largest.replace(rows, keeping: self.pendingRankSelection ?? [])
                self.pendingRankSelection = nil
                if self.showingLargest { self.rankedSelectionChanged() }
            }
        }
    }
    private func rankedSelectionChanged() {
        if scanWorkspace != nil, pendingParentFile != largest.singleSelection?.url { pendingParentFile = nil }
        syncRankedSelection()
        if let selected = largest.selected.first { showHover(selected.url, kind: rankedColorGroup(selected)) }
        window.selectionDidChange { self.selectedURLs() }
        controls()
    }
    private func rankedColorGroup(_ file: RankedFile) -> UInt32? {
        let key = file.key ?? model?.route(to: file.url)?.last?.key
        return key.flatMap { map.colorGroup(for: DTKey($0)) }
    }
    private func syncRankedSelection() {
        guard let model, showingLargest else { return }
        let routes = largest.selected.compactMap { file in
            file.key.flatMap { model.route(to: DTKey($0), from: 0) } ?? model.route(to: file.url)
        }
        guard tree.selectedKeys() != Set(routes.compactMap { $0.last?.key }) else { return }
        if routes.isEmpty { tree.selectSaved([], lead: nil) } else { tree.select(routes, mode: .replace) }
    }
    private func beginScanWorkspace(_ workspace: ScanWorkspace) -> PriorWorkspace {
        let prior = PriorWorkspace(list: listing, locations: locations, expanded: tree.expandedURLs,
            keys: Array(tree.selectedKeys()), lead: tree.leadKey, viewport: map.viewport, ranked: Set(largest.selected.map(\.url)))
        scanWorkspace = workspace
        browsedDuringScan = false
        publishingLive = true
        defer { publishingLive = false }
        clearWorkspace()
        locations = [Location(id: 0, url: workspace.root)]
        setHeading(workspace.root)
        showHover(nil, kind: nil)
        revealWorkspace()
        controls()
        return prior
    }

    private func clearWorkspace() {
        if let work = colorWork { dt_cancel(work.handle); colorWork = nil }
        rankingWork = nil; rankedScope = nil; pendingRankSelection = nil
        model = nil; listing = nil; locations = []; recentColors.removeAll()
        largest.replace([], keeping: [])
        tree.clear(); map.clear(); sunburst.show(nil, colors: nil); sunburst.selection = []
        legend.show([]); legend.choosing(colorMode, loading: false)
        sizeLabel.stringValue = ""
    }

    private func restoreWorkspace(_ prior: PriorWorkspace) {
        applyingNavigation = true
        defer { applyingNavigation = false }
        clearWorkspace()
        if let list = prior.list {
            model = list.model; locations = prior.locations; pendingRankSelection = prior.ranked
            display(list)
            for url in prior.expanded { if let route = list.model.route(to: url) { tree.expand(route) } }
            tree.selectSaved(prior.keys, lead: prior.lead, scroll: false)
            map.restoreViewport(prior.viewport)
        } else {
            window.title = "DiskSlop"
            welcome.isHidden = false; mainViews.forEach { $0.isHidden = true }
        }
        window.selectionDidChange { self.selectedURLs() }
    }

    private func updateScanRanking(_ workspace: ScanWorkspace) {
        guard showingLargest else { return }
        if let model = workspace.indexed {
            guard !workspace.indexedRankingStarted else { return }
            workspace.indexedRankingStarted = true
            DispatchQueue.global(qos: .userInitiated).async {
                let rows = dt_largest_files(model.handle, 0).map(RankedFile.read) ?? []
                DispatchQueue.main.async {
                    guard self.scanWorkspace === workspace, !self.cancelledScan else { return }
                    self.largest.replace(rows, live: true)
                    workspace.indexedRankingDisplayed = true
                    if self.showingLargest { self.rankedSelectionChanged() }
                }
            }
            return
        }
        guard let rows = dt_live_largest(workspace.progress.handle, &workspace.rankRevision) else { return }
        let selected = largest.selected.map(\.url)
        largest.replace(RankedFile.read(rows), live: !largest.rows.isEmpty)
        if selected != largest.selected.map(\.url) { rankedSelectionChanged() }
    }

    private func updateScanWorkspace(_ workspace: ScanWorkspace) {
        updateScanRanking(workspace)
        guard !tree.view.trackingSelection, !map.trackingSelection, !sunburst.trackingSelection else { return }
        if let (request, frame) = workspace.deferredFrame {
            workspace.deferredFrame = nil
            publishScanFrame(request, frame, in: workspace)
        }
        workspace.update(request: scanMapRequest) { [weak self] request, next in
            guard let self, self.scanWorkspace === workspace, !self.cancelledScan else { return }
            self.publishScanFrame(request, next, in: workspace)
        }
    }

    private func scanMapRequest() -> ScanMapRequest {
        ScanMapRequest(aspect: map.aspect, mode: colorMode, sort: legend.sort, settings: map.renderSettings,
            priorFrame: map.motionSource, radial: usingSunburst, dimensions: sunburst.liveDimensions)
    }

    private func publishScanFrame(_ request: ScanMapRequest, _ next: ScanMapFrame, in workspace: ScanWorkspace) {
        guard scanWorkspace === workspace, !cancelledScan, model == nil || model?.isScanPreview == true else { return }
        if tree.view.trackingSelection || map.trackingSelection || sunburst.trackingSelection {
            workspace.deferredFrame = (request, next)
            return
        }
        workspace.deferredFrame = nil
        let list = next.list, previous = listing
        let keys = Array(tree.selectedKeys()), lead = tree.leadKey
        publishingLive = true
        if let work = colorWork { dt_cancel(work.handle); colorWork = nil }
        recentColors.removeAll()
        model = list.model; listing = list
        if previous == nil, let root = list.model.url(folder: 0, directory: true) { locations = [Location(id: 0, url: root)] }
        tree.showLive(list.model, keys: keys, lead: lead)
        if previous == nil { setHeading(workspace.root) }
        installScanCharts(request, next, continuing: previous != nil)
        if showingLargest, !largest.selected.isEmpty { syncRankedSelection() }
        if let file = pendingParentFile, let parent = list.model.route(to: file.deletingLastPathComponent()) {
            pendingParentFile = nil; selectParent(parent, in: list.model); browsedDuringScan = true
        }
        map.selection = tree.selectedKeys(); sunburst.selection = map.selection
        if showingLargest { largest.table.refreshHover() } else { tree.view.refreshHover() }
        sizeLabel.stringValue = formatBytes(list.summary.bytes)
        publishingLive = false
        controls()
    }

    private func installScanCharts(_ request: ScanMapRequest, _ next: ScanMapFrame, continuing: Bool, animate: Bool = true) {
        let list = next.list
        let scope = Set(locations.compactMap { $0.item?.key }).union([DiskItem.scanRootKey])
        let matches = colorMode == request.mode, colors = matches ? next.colors : nil
        legend.showLive(list.geometry.kinds, colors: colors, sorted: legend.sort == request.sort ? next.order : nil)
        legend.choosing(colorMode, loading: (colors?.mode ?? .kind) != colorMode)
        map.showLive(list, ancestors: scope, colors: colors, frame: matches ? next.raster : nil,
            settings: request.settings, sameFolder: continuing)
        sunburst.scopeKeys = scope
        if usingSunburst {
            if matches, let rings = next.rings, request.dimensions == sunburst.liveDimensions {
                sunburst.showLive(list, colors: colors, layout: rings, sameFolder: continuing && animate)
            } else { sunburst.show(list, colors: colors, keepingLayout: continuing) }
        }
        if !matches { updateColors(for: list) }
    }

    private func setHeading(_ url: URL) {
        folderLabel.stringValue = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        window.title = "\(folderLabel.stringValue) — DiskSlop"
        tree.icons.displayFolder(url, in: folderIcon)
    }

    private func showHover(_ url: URL?, kind: UInt32?) {
        let path = url?.path ?? locations.last?.url.path ?? scanWorkspace?.root.path ?? ""
        if path != pathLabel.stringValue { pathLabel.stringValue = path; pathLabel.toolTip = path }
        legend.highlight(kind)
    }
    @objc private func chooseColorMode(_ item: NSMenuItem) {
        if let mode = MapColorMode(rawValue: item.tag) { selectColorMode(mode) }
    }
    private func selectColorMode(_ mode: MapColorMode) {
        guard mode != colorMode else { return }
        colorMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "DiskSlopColorMode")
        if let listing { updateColors(for: listing) }
    }
    private func updateColors(for list: FolderListing) {
        if let work = colorWork { dt_cancel(work.handle); colorWork = nil }
        let mode = colorMode
        map.useColors(map.displayedColors)
        let matches = (map.displayedColors?.mode ?? .kind) == mode
        legend.choosing(mode, loading: !matches)
        guard !matches else { return }
        guard mode != .kind else { map.useColors(nil); return }
        if let i = recentColors.firstIndex(where: { $0.mode == mode }) {
            let cached = recentColors.remove(at: i); recentColors.append(cached)
            map.useColors(cached)
            return
        }
        let work = ScanProgress()
        colorWork = work
        colorQueue.async {
            let result = MapBreakdown(list, mode: mode, progress: work)
            DispatchQueue.main.async {
                guard self.colorWork === work, self.listing === list else { return }
                self.colorWork = nil
                guard let result else { self.legend.choosing(mode, loading: false); return }
                if result.memoryBytes <= 64 * 1024 * 1024 {
                    self.recentColors.append(result)
                    while self.recentColors.count > 3 || self.recentColors.reduce(0, { $0 + $1.memoryBytes }) > 64 * 1024 * 1024 {
                        self.recentColors.removeFirst()
                    }
                }
                self.map.useColors(result)
            }
        }
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if preferredPanes.indices.contains(dividerIndex), let event = NSApp.currentEvent,
           event.type == .leftMouseDragged || event.type == .leftMouseDown {
            let width = dividerIndex == 0 ? proposedPosition
                : splitView.bounds.width - proposedPosition - splitView.dividerThickness
            if width.isFinite && width > 0 {
                preferredPanes[dividerIndex].constant = width
                if event.type == .leftMouseDragged {
                    UserDefaults.standard.set(Double(width), forKey: dividerIndex == 0 ? sidebarWidthKey : legendWidthKey)
                }
            }
        }
        return proposedPosition
    }

    private var mainViews: [NSView] = []
    private func controls() {
        if !publishingLive { syncLive() }
        toolbar.update(busy: busy, scanning: scanning != nil, back: history.adjacent(-1) != nil,
            forward: history.adjacent(1) != nil, hasScan: model != nil)
        for b in welcome.actions { b.isEnabled = !busy }
        let count = showingLargest ? largest.table.numberOfSelectedRows : tree.view.numberOfSelectedRows
        shelf.isHidden = model == nil && scanWorkspace == nil
        if showingLargest && count == 1, let file = largest.selected.first { selectionLabel.stringValue = "\(file.url.lastPathComponent)  ·  \(formatBytes(file.bytes))" }
        else if count == 1, let item = tree.firstSelected { selectionLabel.stringValue = "\(item.title)  ·  \(formatBytes(item.bytes))" }
        else { selectionLabel.stringValue = count > 1 ? "\(count.formatted()) selected" : "" }
        revealButton.isEnabled = (!busy || scanWorkspace != nil) && count > 0
        parentButton.isEnabled = canShowParent
        trashButton.isEnabled = !busy && count > 0 && !tree.isSelected(DiskItem.scanRootKey)
        updateZoom()
        spinner.isHidden = !busy || scanning != nil
        if spinner.isHidden { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
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
    @objc private func rescan() { if let root = locations.first { scan(root.url, preserve: true) } }
    @objc private func toggleLive() {
        UserDefaults.standard.set(liveSwitch.state == .on, forKey: "DiskSlopLiveUpdates")
        if liveSwitch.state == .off { liveCheckpoints.cancel() }
        syncLive()
    }
    private func syncLive() {
        liveDot.isOn = liveSwitch.state == .on
        let entry = liveSwitch.state == .on && !busy && scanWorkspace == nil
            ? locations.first.flatMap { cache.read($0.url) } : nil
        let current = entry?.model === model ? entry : nil
        if liveSwitch.toolTip == nil || current !== updates.source {
            let help = current != nil && current?.watcher == nil
                ? "This volume uses periodic background scans for live updates."
                : "Update the tables and map as files change on disk."
            liveSwitch.toolTip = help; liveSwitch.setAccessibilityHelp(help)
        }
        updates.follow(current)
    }
    private func currentVisit(_ list: FolderListing) -> NavigationVisit {
        let root = locations[0], here = locations[locations.count - 1]
        let keys = tree.selectedKeys()
        if let visit = history.current, visit.matches(list.model, folder: here.url, keys: keys) { return visit }
        return NavigationVisit(model: list.model, root: root.url, folder: here.url, folderNumber: here.id,
            keys: keys, lead: tree.leadKey, viewport: map.viewport)
    }
    private func refreshLive(_ entry: RecentScan, progress: ScanProgress, changes: CacheChanges) {
        guard !busy, let current = listing, current.model === entry.model, !locations.isEmpty else {
            updates.finish(progress, retry: true); return
        }
        let root = entry.root, focus = locations
        let scope = focus.map { ($0.url, DirectoryID(entry.model, $0.id)) }
        let visit = currentVisit(current), request = scanMapRequest(), ranked = showingLargest
        let began = ProcessInfo.processInfo.systemUptime
        updates.queue.async {
            do {
                let identity = RootIdentity(root)
                let watcher: ChangeWatch?, next: ScanModel
                let diskSnapshot: StartupSnapshot?, checkpointNotices: Int
                if case .paths(let paths) = changes, let identity, identity == entry.identity {
                    watcher = entry.watcher
                    diskSnapshot = entry.startupSnapshot.map { StartupSnapshot($0, through: paths.throughEvent) }
                    checkpointNotices = paths.outsideSnapshotDirectory ? paths.shallow.count + paths.recursive.count : 0
                    next = try entry.model.refreshed(changes: paths, progress: progress)
                } else {
                    watcher = ChangeWatch(url: root, identity: identity)
                    diskSnapshot = watcher == nil ? nil : StartupSnapshot.forStartupVolume(root, identity: identity)
                    checkpointNotices = 512
                    next = try ScanModel(url: root, progress: progress, preview: false)
                }
                guard !dt_is_cancelled(progress.handle) else { return }
                if next === entry.model || (entry.watcher == nil && watcher == nil && dt_same_inventory(entry.model.handle, next.handle, progress.handle)) {
                    DispatchQueue.main.async { self.updates.finish(progress) }
                    return
                }
                var trail = [Location(id: 0, url: root)]
                for (url, identity) in scope.dropFirst().reversed() {
                    if let route = next.route(to: url), let folder = route.last, folder.isFolder,
                       DirectoryID(next, folder.child) == identity, let resolved = self.trail(in: next, root: root, route: route) {
                        trail = resolved; break
                    }
                }
                let list = FolderListing(next, folder: trail.last!.id, aspect: request.aspect, previous: current.geometry)
                guard let charts = request.prepare(list, progress: progress) else { return }
                let rows = ranked ? dt_largest_files(next.handle, list.folder).map(RankedFile.read) ?? [] : nil
                guard !dt_is_cancelled(progress.handle) else { return }
                let scan = RecentScan(model: next, listing: list.folder == 0 ? list : nil, root: root, identity: identity,
                    watcher: watcher, elapsed: ProcessInfo.processInfo.systemUptime - began, startupSnapshot: diskSnapshot)
                let snapshot = LiveSnapshot(scan: scan, list: list, trail: trail, colors: charts.colors, order: charts.order,
                    ranked: rows, frame: charts.raster, settings: request.settings, rings: charts.rings, sort: request.sort, checkpointNotices: checkpointNotices)
                let keys = visit.liveKeys(in: next) ?? []
                DispatchQueue.main.async {
                    guard self.updates.work === progress else { return }
                    guard self.listing === current, self.colorMode == request.mode, self.legend.sort == request.sort,
                          self.usingSunburst == request.radial, !self.showingLargest || ranked else {
                        self.updates.finish(progress, retry: true); return
                    }
                    self.publishLive(snapshot, progress: progress, visit: visit, keys: keys)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.updates.work === progress else { return }
                    self.status.stringValue = "Live update delayed · \(error.localizedDescription)"
                    self.status.toolTip = self.status.stringValue
                    self.updates.finish(progress, failed: true)
                }
            }
        }
    }

    private func publishLive(_ next: LiveSnapshot, progress: ScanProgress, visit: NavigationVisit, keys: [UInt64]) {
        guard updates.work === progress, let current = listing else { return }
        guard locations.last?.url == visit.folder, colorMode == (next.colors?.mode ?? .kind), legend.sort == next.sort,
              usingSunburst == (next.rings != nil), !showingLargest || next.ranked != nil else {
            updates.finish(progress, retry: true); return
        }
        if window.attachedSheet != nil || tree.view.trackingSelection || map.trackingSelection || sunburst.trackingSelection {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                self.publishLive(next, progress: progress, visit: visit, keys: keys)
            }
            return
        }
        guard visit.matches(current.model, folder: locations.last!.url, keys: tree.selectedKeys()) else {
            let latest = currentVisit(current)
            updates.queue.async {
                let keys = latest.liveKeys(in: next.scan.model) ?? []
                DispatchQueue.main.async { self.publishLive(next, progress: progress, visit: latest, keys: keys) }
            }
            return
        }
        let sameFolder = next.trail.last?.url == locations.last?.url && next.scan.identity == updates.source?.identity
        let lead = tree.leadKey.flatMap { packed -> UInt64? in
            guard packed != DiskItem.scanRootKey else { return packed }
            let key = DTKey(packed)
            return current.model.url(folder: key.folder, slot: key.slot, directory: false)
                .flatMap { next.scan.model.route(to: $0)?.last?.key }
        }
        updates.finish(progress)
        publishingLive = true; applyingNavigation = true
        if let work = colorWork { dt_cancel(work.handle); colorWork = nil }
        recentColors = next.colors.map { $0.memoryBytes <= 64 * 1024 * 1024 ? [$0] : [] } ?? []
        rankingWork = nil; pendingRankSelection = nil
        model = next.scan.model; listing = next.list; locations = next.trail
        cache.put(next.scan, for: next.scan.root)
        liveCheckpoints.consider(next.scan, notices: next.checkpointNotices)
        if let rows = next.ranked {
            largest.replace(rows, live: true); rankedScope = next.list
        } else { rankedScope = nil }
        tree.showLive(next.scan.model, keys: showingLargest ? largest.selected.compactMap(\.key) : keys, lead: lead)
        let scopeKeys = Set(next.trail.compactMap { $0.item?.key }).union([DiskItem.scanRootKey])
        legend.showLive(next.list.geometry.kinds, colors: next.colors, sorted: next.order)
        legend.choosing(colorMode, loading: false)
        showHover(nil, kind: nil)
        map.showLive(next.list, ancestors: scopeKeys, colors: next.colors, frame: next.frame,
            settings: next.settings, sameFolder: sameFolder)
        sunburst.scopeKeys = scopeKeys
        if usingSunburst, let rings = next.rings { sunburst.showLive(next.list, colors: next.colors, layout: rings, sameFolder: sameFolder) }
        map.selection = tree.selectedKeys(); sunburst.selection = map.selection
        if showingLargest { largest.table.refreshHover() } else { tree.view.refreshHover() }
        if let here = next.trail.last?.url {
            setHeading(here)
        }
        sizeLabel.stringValue = formatBytes(next.list.summary.bytes)
        setScanStatus(["\(formatCount(next.list.summary.entries)) entries", "Updated \(Date().formatted(date: .omitted, time: .standard))"], summary: next.list.summary)
        window.selectionDidChange { self.selectedURLs() }
        publishingLive = false; applyingNavigation = false
        recordVisit(replace: true); controls()
    }
    @objc private func forceFullScan() { if let root = locations.first { scan(root.url, force: true, preserve: true) } }
    @objc private func refreshOrCancel() { if scanning == nil { rescan() } else { cancel() } }
    private var cancelledScan = false
    @objc private func cancel() {
        if let scanning {
            pendingParentFile = nil
            cancelledScan = true
            dt_cancel(scanning.handle)
            scanBadge.show(.cancelling)
            status.stringValue = ""
        }
    }

    private func scan(_ url: URL, force: Bool = false, preserve: Bool = false) {
        guard !busy else { return }
        if preserve { recordVisit() }
        let previous = preserve ? history.current : nil
        let priorExpansions = preserve ? tree.expandedURLs : []
        let began = ProcessInfo.processInfo.systemUptime
        var previewed: ScanModel?
        obtainRoot(url, force: force, keeping: preserve ? model : nil, preview: { entry in
            guard !preserve else { return }
            previewed = entry.model
            self.showRoot(entry, message: "Checking cached scan")
        }) { result in
            switch result {
            case .success(let entry):
                if self.showPendingParent(in: entry) { return }
                if preserve, self.model === entry.model {
                    let ms = (ProcessInfo.processInfo.systemUptime - began) * 1000
                    let result = entry.summary.issues == 0 ? "Up to date" : "Checked readable items"
                    self.setScanStatus([result, "\(formatCount(entry.summary.entries)) entries", String(format: "%.0f ms", ms)], summary: entry.summary)
                    self.controls()
                } else if let previous, !(self.browsedDuringScan && self.model?.isScanPreview == true) {
                    let expanded = Set(priorExpansions + self.tree.expandedURLs)
                    self.restoreVisit(previous, in: entry.model, root: entry.root, rootList: entry.listing, elapsed: entry.elapsed) { restored in
                        if !restored { self.showRoot(entry) }
                        for url in expanded { if let route = entry.model.route(to: url) { self.tree.expand(route) } }
                        self.recordVisit(replace: true); self.controls()
                    }
                } else {
                    if previewed === entry.model {
                        self.setScanStatus(["Cached scan", "\(formatCount(entry.summary.entries)) entries"], summary: entry.summary)
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
        guard let list = entry.listing else { return }
        let continuing = (model?.isScanPreview == true || (model === entry.model && listing == nil))
            && locations.first?.url == entry.root
        model = entry.model; scanTime = entry.elapsed
        locations = [Location(id: 0, url: entry.root)]
        applyingNavigation = true
        display(list, message: message, continuingScan: continuing)
        if !continuing { tree.selectSaved([], lead: nil) }
        applyingNavigation = false
    }
    private func beginScan() -> ScanProgress {
        let progress = ScanProgress()
        scanning = progress
        busy = true
        cancelledScan = false
        scanBadge.show(.scanning)
        return progress
    }

    private func endScan(completed: Bool) {
        scanning = nil
        busy = false
        scanBadge.show(completed && !cancelledScan ? .complete : .idle)
    }

    private func obtainRoot(_ url: URL, force: Bool = false, keeping current: ScanModel? = nil, preview: ((RecentScan) -> Void)? = nil,
                            completion: @escaping (Result<RecentScan, Error>) -> Void) {
        pendingParentFile = nil
        browsedDuringScan = false
        let progress = beginScan()
        let began = ProcessInfo.processInfo.systemUptime
        let cached = force ? nil : cache.read(url)
        let workspace = cached == nil && (current == nil || (force && locations.count <= 1))
            ? ScanWorkspace(root: url, progress: progress) : nil
        let prior = workspace.map(beginScanWorkspace)
        let mapAspect = map.aspect
        controls()
        let update = { [weak self] in
            guard let self, self.scanning === progress, !self.cancelledScan else { return }
            if let indexed = workspace?.indexed {
                self.status.stringValue = "Preparing map · \(formatCount(dt_summary(indexed.handle, 0).entries)) entries"
            } else {
                self.status.stringValue = "\(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent) · \(formatCount(dt_progress_count(progress.handle))) entries"
            }
            if let file = self.pendingParentFile { self.status.stringValue += " · Will show \(file.deletingLastPathComponent().lastPathComponent) when ready" }
            if let workspace { self.updateScanWorkspace(workspace) }
        }
        update()
        if let workspace {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
                if self.scanWorkspace === workspace, self.listing == nil, !self.cancelledScan {
                    self.updateScanWorkspace(workspace)
                }
            }
        }
        let pulse = Timer(timeInterval: 0.15, repeats: true) { _ in update() }
        RunLoop.main.add(pulse, forMode: .common); timer = pulse
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<RecentScan, Error> {
                let identity = RootIdentity(url)
                var previousWatch: ChangeWatch?
                if let cached, let identity, cached.identity == identity {
                    if let preview, cached.listing != nil {
                        DispatchQueue.main.async { if !self.cancelledScan { preview(cached) } }
                    }
                    if let watch = cached.watcher {
                        if cached.summary.issues == 0, case .clean = watch.changes() {
                            if cached.listing != nil || cached.model === current { return cached }
                            return RecentScan(model: cached.model, listing: FolderListing(cached.model, folder: 0, aspect: mapAspect),
                                root: cached.root, identity: identity, watcher: watch, elapsed: cached.elapsed, startupSnapshot: cached.startupSnapshot)
                        }
                        previousWatch = watch
                    }
                }
                let watcher = ChangeWatch(url: url, identity: identity)
                let snapshot = watcher == nil ? nil : StartupSnapshot.forStartupVolume(url, identity: identity)
                let observedInode = snapshot?.fileInode ?? 0
                var replacingInode: UInt64 = 0
                var shouldSave = snapshot?.needsRenewal == true
                let scanned: ScanModel
                if let previousWatch, let cached {
                    switch previousWatch.changes() {
                    case .full:
                        scanned = try ScanModel(url: url, progress: progress)
                        shouldSave = true
                    case .clean:
                        scanned = try cached.model.refreshed(changes: ChangedDirectories(), retryIssues: true, progress: progress)
                    case .paths(let paths):
                        scanned = try cached.model.refreshed(changes: paths, retryIssues: true, progress: progress)
                    }
                } else if !force, let snapshot, let restored = try snapshot.restore(progress: progress) {
                    scanned = restored
                } else {
                    scanned = try ScanModel(url: url, progress: progress)
                    shouldSave = true
                    if !force { replacingInode = observedInode }
                }
                let priorGeometry = workspace?.finishEnumeration()
                if let workspace {
                    let root = scanned.url(folder: 0, directory: true) ?? url
                    DispatchQueue.main.async {
                        guard self.scanWorkspace === workspace, !self.cancelledScan else { return }
                        workspace.indexed = scanned
                        self.updateScanRanking(workspace)
                        if self.listing == nil {
                            self.model = scanned; self.locations = [Location(id: 0, url: root)]
                            self.tree.show(scanned, refresh: false)
                            self.sizeLabel.stringValue = formatBytes(dt_summary(scanned.handle, 0).bytes)
                            self.showHover(nil, kind: nil); self.controls()
                        }
                    }
                }
                if shouldSave, let snapshot {
                    snapshot.save(scanned, progress: progress, replacingInode: replacingInode)
                }
                let list: FolderListing?
                if let cached, scanned === cached.model, cached.listing != nil || scanned === current {
                    list = cached.listing
                } else {
                    list = FolderListing(scanned, folder: 0, aspect: mapAspect, previous: priorGeometry ?? cached?.listing?.geometry)
                }
                return RecentScan(model: scanned, listing: list, root: scanned.url(folder: 0, directory: true) ?? url,
                    identity: identity, watcher: watcher, elapsed: ProcessInfo.processInfo.systemUptime - began, startupSnapshot: snapshot)
            }
            if case .failure = result { _ = workspace?.finishEnumeration() }
            let finished: (ScanMapRequest, ScanMapFrame)?
            if workspace != nil, case .success(let entry) = result, let list = entry.listing, !dt_is_cancelled(progress.handle) {
                let request = DispatchQueue.main.sync { self.scanMapRequest() }
                finished = request.prepare(list, progress: progress).map { (request, $0) }
            } else { finished = nil }
            DispatchQueue.main.async {
                self.timer?.invalidate(); self.timer = nil
                self.endScan(completed: (try? result.get()) != nil)
                if workspace != nil {
                    self.pendingRankSelection = Set(self.largest.selected.map(\.url))
                    self.scanWorkspace = nil
                }
                if self.cancelledScan {
                    if let prior { self.restoreWorkspace(prior) }
                    completion(.failure(DiskError(message: "Scan cancelled.")))
                    return
                }
                if case .success(let entry) = result, entry !== cached { self.cache.put(entry, for: url) }
                if case .success(let entry) = result, workspace?.indexedRankingDisplayed == true, workspace?.indexed === entry.model {
                    self.rankedScope = entry.listing; self.pendingRankSelection = nil
                }
                if case .failure = result {
                    self.pendingParentFile = nil
                    if let prior { self.restoreWorkspace(prior) }
                }
                self.finishedScanFrame = finished
                completion(result)
                self.finishedScanFrame = nil
            }
        }
    }
    private func revealWorkspace() {
        welcome.isHidden = true
        for v in mainViews { v.isHidden = false }
        if preferredPanes.isEmpty {
            window.contentView?.layoutSubtreeIfNeeded()
            let width = split.bounds.width
            if width > 0 {
                func preferredWidth(forKey key: String, fallback: CGFloat) -> CGFloat {
                    let saved = CGFloat(UserDefaults.standard.double(forKey: key))
                    return saved.isFinite && saved > 0 ? saved : fallback
                }
                let sidebarWidth = preferredWidth(forKey: sidebarWidthKey, fallback: max(265, min(320, width * 0.25)))
                let legendWidth = preferredWidth(forKey: legendWidthKey, fallback: max(245, min(345, width * 0.28)))
                let left = split.arrangedSubviews[0].widthAnchor.constraint(equalToConstant: sidebarWidth)
                let right = legend.widthAnchor.constraint(equalToConstant: legendWidth)
                left.priority = .init(470)
                right.priority = .init(471)
                preferredPanes = [left, right]
                NSLayoutConstraint.activate(preferredPanes)
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
    }
    private func display(_ list: FolderListing, message: String? = nil, reloadTree: Bool = false, continuingScan: Bool = false,
                         trashFrame: (ScanMapRequest, ScanMapFrame)? = nil) {
        let previous = applyingNavigation
        applyingNavigation = true
        defer { applyingNavigation = previous }
        let sameFolder = listing?.folder == list.folder && listing?.model === list.model
        if listing !== list { recentColors.removeAll() }
        listing = list
        if continuingScan { tree.showLive(list.model, keys: Array(tree.selectedKeys()), lead: tree.leadKey) }
        else { tree.show(list.model, refresh: reloadTree) }
        revealWorkspace()
        showHover(nil, kind: nil)
        if let (request, frame) = trashFrame ?? finishedScanFrame, frame.list === list {
            if let work = colorWork { dt_cancel(work.handle); colorWork = nil }
            installScanCharts(request, frame, continuing: continuingScan || (trashFrame != nil && sameFolder), animate: trashFrame == nil)
        } else {
            legend.show(list.geometry.kinds)
            let scopeKeys = Set(locations.compactMap { $0.item?.key }).union([DiskItem.scanRootKey])
            if continuingScan { map.showLive(list, ancestors: scopeKeys, colors: nil, frame: nil, settings: nil, sameFolder: true) }
            else { map.show(list, ancestors: scopeKeys) }
            sunburst.scopeKeys = scopeKeys
            if usingSunburst { sunburst.show(list, colors: nil, keepingLayout: continuingScan) }
            updateColors(for: list)
        }
        if showingLargest { loadLargest(list, keepingRows: continuingScan) }
        map.selection = tree.selectedKeys()
        sunburst.selection = map.selection
        if let here = locations.last {
            setHeading(here.url)
        }
        sizeLabel.stringValue = formatBytes(list.summary.bytes)
        let parts = [message, "\(formatCount(list.summary.entries)) \(list.summary.entries == 1 ? "entry" : "entries")", String(format: "Scan %.2f s", scanTime)].compactMap { $0 }
        setScanStatus(parts, summary: list.summary)
        controls()
    }
    private func setScanStatus(_ details: [String], summary: DTSummary) {
        var parts = details
        if summary.issues > 0 { parts.append("\(formatCount(summary.issues)) \(summary.issues == 1 ? "scan error" : "scan errors")") }
        if summary.boundaries > 0 { parts.append("\(formatCount(summary.boundaries)) \(summary.boundaries == 1 ? "mount" : "mounts") skipped") }
        status.stringValue = parts.joined(separator: " · ")
        status.toolTip = status.stringValue
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
                    if self.showPendingParent(in: entry) { return }
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
    private var canShowParent: Bool {
        if scanWorkspace != nil {
            guard !cancelledScan else { return false }
            if !showingLargest { return tree.selectedChildKey != nil }
            guard let file = largest.singleSelection else { return false }
            return pendingParentFile != file.url
        }
        guard !busy, listing != nil else { return false }
        if showingLargest { return rankedScope === listing && largest.singleSelection?.key != nil }
        return tree.selectedChildKey != nil
    }
    @objc private func showParentFolder() {
        guard canShowParent else { return }
        if scanWorkspace != nil, showingLargest, let file = largest.singleSelection {
            if let model, let route = model.route(to: file.url.deletingLastPathComponent()) {
                selectParent(route, in: model)
            } else {
                pendingParentFile = file.url; controls()
            }
            return
        }
        let key = showingLargest ? largest.singleSelection?.key : tree.selectedChildKey
        guard let model, let key, var route = model.route(to: DTKey(key), from: 0), route.popLast() != nil else { return }
        selectParent(route, in: model)
    }
    private func selectParent(_ route: [DiskItem], in model: ScanModel) {
        guard let root = locations.first else { return }
        let scope = listing?.folder ?? 0
        let parent = route.last
        let key = parent?.key ?? DiskItem.scanRootKey
        let inScope = scope == 0 || route.contains { $0.child == scope }
        let visible = !usingSunburst || scope == (parent?.child ?? 0) || sunburst.containsWedge(for: key)
        showFolders()
        window.makeFirstResponder(tree.view)
        if inScope && (visible || scanWorkspace != nil) {
            tree.reveal(route)
            if !usingSunburst { map.revealSelection() }
            showHover(model.url(folder: parent?.child ?? 0, directory: true), kind: nil)
        } else if let trail = trail(in: model, root: root.url, route: route) {
            changeFolder(trail, select: route, expandSelection: false)
        }
    }
    private func showPendingParent(in entry: RecentScan) -> Bool {
        guard let file = pendingParentFile else { return false }
        pendingParentFile = nil
        showFolders()
        guard let route = entry.model.route(to: file.deletingLastPathComponent()), route.last?.isFolder != false else {
            showRoot(entry, message: "The enclosing folder is no longer available.")
            recordVisit(); controls()
            return true
        }
        showRoot(entry)
        selectParent(route, in: entry.model)
        return true
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
        guard !busy, let model, let root = locations.first, route.last?.isFolder != false,
              (route.last?.child ?? 0) != locations.last?.id, let trail = trail(in: model, root: root.url, route: route) else { return }
        changeFolder(trail, select: route)
    }
    private func changeFolder(_ trail: [Location], select route: [DiskItem], expandSelection: Bool = true) {
        guard !busy, let model, let here = trail.last else { return }
        let aspect = map.aspect
        let cached = here.id == 0 ? cache.read(here.url)?.listing : nil
        let apply = { (list: FolderListing) in
            self.busy = false; self.applyingNavigation = true; self.locations = trail
            self.display(list)
            if expandSelection && route.last?.child == here.id { self.tree.expand(route) }
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
        if showingLargest {
            let urls = largest.selected.map(\.url)
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            return
        }
        guard !busy || scanWorkspace != nil, let model else { return }
        let selected = tree.selectedItems()
        let urls = selected.compactMap { item in
            model.url(folder: item.folder, slot: item.slot, directory: item.isFolder)
        }
        if let first = selected.first, first.isFolder, selected.count == 1, let url = urls.first,
           let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { NSApp.presentError(error) } }
            }
        } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    private func selectedURLs() -> [URL] {
        if showingLargest { return largest.selected.map(\.url) }
        guard let model else { return [] }
        return tree.selectedItems().compactMap { model.url(folder: $0.folder, slot: $0.slot, directory: $0.isFolder) }
    }
    @objc private func quickLook() { window.togglePreview(selectedURLs()) }
    private func itemMenu() -> NSMenu? {
        guard !busy || scanWorkspace != nil, hasSelection else { return nil }
        let menu = NSMenu()
        func command(_ name: String, _ symbol: String, _ action: Selector) {
            let item = menu.addItem(withTitle: name, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        command("Open", "arrow.up.forward.app", #selector(openSelection))
        command("Quick Look", "eye", #selector(quickLook))
        menu.addItem(withTitle: "Open With", action: nil, keyEquivalent: "").submenu = ApplicationMenu(window: window) { [weak self] in self?.selectedURLs() ?? [] }
        command("Open in Finder", "magnifyingglass", #selector(reveal))
        command("Show Parent Folder", "folder", #selector(showParentFolder))
        if busy { return menu }
        menu.addItem(.separator())
        command("Refresh", "arrow.clockwise", #selector(refreshSelection))
        menu.addItem(.separator())
        command(tree.view.numberOfSelectedRows > 1 ? "Move to Trash…" : "Move to Trash", "trash", #selector(trash))
        return menu
    }
    @objc private func openSelection() {
        guard !busy || scanWorkspace != nil else { return }
        for url in selectedURLs() {
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { NSApp.presentError(error) } }
            }
        }
    }
    @objc private func refreshSelection() {
        guard !busy, let old = model, let root = locations.first else { return }
        if tree.isSelected(DiskItem.scanRootKey) { rescan(); return }
        let items = tree.selectedItems(rootsOnly: true)
        guard !items.isEmpty else { return }
        let prior = cache.read(root.url)
        if let cached = prior, cached.model === old, cached.watcher != nil, cached.summary.issues == 0 {
            rescan()
            return
        }
        recordVisit()
        let previous = history.current
        let expansions = tree.expandedURLs
        let mapAspect = map.aspect
        let focus = locations
        let progress = beginScan()
        controls()
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
                    self.endScan(completed: true)
                    guard !self.cancelledScan else {
                        self.status.stringValue = "Scan cancelled."
                        self.controls()
                        return
                    }
                    if let prior, prior.model === old {
                        self.cache.put(RecentScan(model: updated, listing: list.folder == 0 ? list : nil, root: root.url,
                            identity: prior.identity, watcher: prior.watcher, elapsed: elapsed, startupSnapshot: prior.startupSnapshot), for: root.url)
                    }
                    self.model = updated; self.locations = restored
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
                    self.endScan(completed: false)
                    self.status.stringValue = error.localizedDescription
                    self.controls()
                }
            }
        }
    }
    @objc private func trash() {
        guard !busy, let list = listing, !tree.isSelected(DiskItem.scanRootKey) else { return }
        let selected = tree.selectedIDs()
        guard !selected.isEmpty else { return }
        let single = selected.count == 1
        let previousStatus = status.stringValue
        trashGlass.dock.prepare()
        busy = true; status.stringValue = single ? "Moving to Trash…" : "Reviewing selection…"; controls()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try TrashPlan(model: list.model, keys: selected) }
            DispatchQueue.main.async {
                self.status.stringValue = previousStatus
                switch result {
                case .failure(let error):
                    self.busy = false; self.controls()
                    self.trashProblem(title: "This selection can’t be moved to Trash", detail: error.localizedDescription)
                case .success(let plan):
                    if single {
                        self.moveToTrash(plan, acknowledged: false)
                        return
                    }
                    let sheet = TrashReview(plan)
                    self.trashReview = sheet
                    self.spinner.stopAnimation(nil)
                    sheet.present(on: self.window) { acknowledged in
                        self.trashReview = nil
                        guard let acknowledged else { self.busy = false; self.controls(); return }
                        self.moveToTrash(plan, acknowledged: acknowledged)
                    }
                }
            }
        }
    }

    private func moveToTrash(_ plan: TrashPlan, acknowledged: Bool) {
        movingToTrash = true
        let trail = locations, request = scanMapRequest()
        let prior = trail.first.flatMap { cache.read($0.url) }
        let geometry = listing?.geometry, scope = sunburst.scopeKeys
        let viewport = usingSunburst ? CGRect(x: 0, y: 0, width: 1, height: 1) : map.viewport
        if plan.roots.count > 1 { trashGlass.dock.prepare() }
        status.stringValue = "Moving selection to Trash…"; controls()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = plan.perform(acknowledged: acknowledged)
            if let geometry, result.moved > 0 {
                let keys = plan.visibleMovedKeys(result, geometry: geometry, viewport: viewport, scope: scope)
                if !keys.isEmpty {
                    DispatchQueue.main.async {
                        guard self.listing?.model === plan.model else { return }
                        let radial = self.usingSunburst
                        let regions = radial ? self.sunburst.trashRegions(for: keys) : self.map.trashRegions(for: keys)
                        self.trashGlass.play(regions, from: radial ? self.sunburst : self.map)
                    }
                }
            }
            let surviving = Array(trail.prefix { location in
                guard let item = location.item else { return true }
                return plan.model.url(folder: item.folder, slot: item.slot, directory: true) != nil
            })
            let fresh = result.moved > 0 ? FolderListing(plan.model, folder: surviving.last?.id ?? 0, aspect: request.aspect) : nil
            let frame = fresh.flatMap { request.prepare($0, progress: ScanProgress(), animate: false) }
            DispatchQueue.main.async {
                defer {
                    self.movingToTrash = false
                    if self.waitingToQuit {
                        self.waitingToQuit = false
                        NSApp.reply(toApplicationShouldTerminate: result.failed == 0)
                    }
                }
                self.busy = false
                let message = "\(result.moved.formatted()) moved to Trash"
                if let fresh {
                    if let prior, prior.model === plan.model {
                        self.cache.put(RecentScan(model: plan.model, listing: fresh.folder == 0 ? fresh : nil, root: prior.root,
                            identity: prior.identity, watcher: prior.watcher, elapsed: prior.elapsed, startupSnapshot: prior.startupSnapshot), for: prior.root)
                    }
                    self.locations = surviving
                    self.display(fresh, message: message, reloadTree: true, trashFrame: frame.map { (request, $0) })
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

private func importPreviousPreferences() {
    let defaults = UserDefaults.standard
    let marker = "ImportedPreviousPreferences"
    guard !defaults.bool(forKey: marker),
          let previous = defaults.persistentDomain(forName: "local.disktally.app") else { return }
    for (key, value) in previous where key.contains("DiskTally") {
        let newKey = key.replacingOccurrences(of: "DiskTally", with: "DiskSlop")
        if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
    }
    defaults.set(true, forKey: marker)
}

importPreviousPreferences()
let application = NSApplication.shared
let delegate = DiskApp()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
