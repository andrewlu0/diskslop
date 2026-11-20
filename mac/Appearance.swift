import AppKit
import Sparkle

final class AppearanceSettings: NSObject {
    private enum Choice: String, CaseIterable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
    }
    private let key = "DiskSlopAppearance"
    private var window: NSWindow?
    private var control: NSSegmentedControl?
    private let updater: SPUUpdater
    init(updater: SPUUpdater) { self.updater = updater }
    private var choice: Choice { UserDefaults.standard.string(forKey: key).flatMap(Choice.init(rawValue:)) ?? .system }
    func apply() {
        switch choice {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    @objc func show(_ sender: Any?) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 395, height: 148), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.center()
            let label = NSTextField(labelWithString: "Appearance")
            let modes = NSSegmentedControl(
                labels: Choice.allCases.map(\.rawValue), trackingMode: .selectOne, target: self, action: #selector(changed))
            modes.setAccessibilityLabel("Appearance")
            let checks = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
            checks.bind(.value, to: updater, withKeyPath: #keyPath(SPUUpdater.automaticallyChecksForUpdates), options: nil)
            let installs = NSButton(checkboxWithTitle: "Install updates automatically", target: nil, action: nil)
            installs.bind(.value, to: updater, withKeyPath: #keyPath(SPUUpdater.automaticallyDownloadsUpdates), options: nil)
            installs.bind(.enabled, to: updater, withKeyPath: #keyPath(SPUUpdater.allowsAutomaticUpdates), options: nil)
            let grid = NSGridView(views: [
                [label, modes],
                [NSTextField(labelWithString: "Updates"), checks],
                [NSGridCell.emptyContentView, installs]
            ])
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .leading
            grid.rowAlignment = .firstBaseline
            grid.row(at: 0).bottomPadding = 8
            grid.columnSpacing = 12
            grid.rowSpacing = 4
            let content = NSView()
            w.contentView = content
            content.addSubview(grid)
            grid.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
            window = w
            control = modes
        }
        control?.selectedSegment = Choice.allCases.firstIndex(of: choice) ?? 0
        window?.makeKeyAndOrderFront(sender)
    }
    @objc private func changed(_ sender: NSSegmentedControl) {
        guard Choice.allCases.indices.contains(sender.selectedSegment) else { return }
        UserDefaults.standard.set(Choice.allCases[sender.selectedSegment].rawValue, forKey: key)
        apply()
    }
}
