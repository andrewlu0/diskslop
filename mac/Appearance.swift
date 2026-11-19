import AppKit

final class AppearanceSettings: NSObject {
    private enum Choice: String, CaseIterable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
    }
    private let key = "DiskTallyAppearance"
    private var window: NSWindow?
    private var control: NSSegmentedControl?
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
                contentRect: NSRect(x: 0, y: 0, width: 375, height: 104), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.center()
            let label = NSTextField(labelWithString: "Appearance")
            let modes = NSSegmentedControl(
                labels: Choice.allCases.map(\.rawValue), trackingMode: .selectOne, target: self, action: #selector(changed))
            modes.setAccessibilityLabel("Appearance")
            let row = NSStackView(views: [label, modes])
            row.spacing = 15
            row.alignment = .centerY
            let content = NSView()
            w.contentView = content
            content.addSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
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
