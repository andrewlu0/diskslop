import AppKit
import UniformTypeIdentifiers

final class ApplicationMenu: NSMenu, NSMenuDelegate {
    private let targets: () -> [URL]
    private let parentWindow: NSWindow
    private var started = false
    init(window: NSWindow, targets: @escaping () -> [URL]) {
        parentWindow = window
        self.targets = targets
        super.init(title: "Open With")
        delegate = self
        autoenablesItems = false
        addItem(withTitle: "Finding applications…", action: nil, keyEquivalent: "").isEnabled = false
        addPicker()
    }
    required init(coder: NSCoder) { fatalError() }
    private func addPicker() {
        addItem(.separator())
        addItem(withTitle: "Other…", action: #selector(other), keyEquivalent: "").target = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !started else { return }
        started = true
        let urls = targets()
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let workspace = NSWorkspace.shared
            var types = Set<String>()
            var common: Set<URL>?
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.contentTypeKey])
                let type = values?.contentType?.identifier ?? url.pathExtension
                guard types.insert(type).inserted else { continue }
                let apps = Set(workspace.urlsForApplications(toOpen: url))
                common = common.map { $0.intersection(apps) } ?? apps
                if common?.isEmpty == true { break }
            }
            let preferred = workspace.urlForApplication(toOpen: urls[0])
            let choices = (common ?? []).map { app in (app, FileManager.default.displayName(atPath: app.path)) }
                .sorted { left, right in
                    if left.0 == preferred { return right.0 != preferred }
                    if right.0 == preferred { return false }
                    return left.1.localizedStandardCompare(right.1) == .orderedAscending
                }
            RunLoop.main.perform(inModes: [.common, .eventTracking, .default]) { [weak self] in
                guard let self else { return }
                self.removeAllItems()
                for (url, name) in choices {
                    let item = self.addItem(withTitle: name, action: #selector(self.chosen(_:)), keyEquivalent: "")
                    item.representedObject = url
                    item.target = self
                }
                if choices.isEmpty {
                    self.addItem(withTitle: "No matching applications", action: nil, keyEquivalent: "").isEnabled = false
                }
                self.addPicker()
            }
        }
    }
    @objc private func chosen(_ item: NSMenuItem) {
        if let app = item.representedObject as? URL { open(with: app) }
    }
    @objc private func other() {
        let panel = NSOpenPanel()
        panel.title = "Open With"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: parentWindow) { result in
            if result == .OK, let app = panel.url { self.open(with: app) }
        }
    }
    private func open(with application: URL) {
        let urls = targets()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { NSApp.presentError(error) } }
        }
    }
}
