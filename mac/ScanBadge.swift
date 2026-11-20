import AppKit

final class ScanBadge: NSView {
    enum State: String {
        case idle = ""
        case scanning = "Scanning"
        case cancelling = "Cancelling"
        case complete = "Scan complete"
    }

    private var state = State.idle
    private let content = NSView()
    private let spinner = NSProgressIndicator()
    private let check = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private lazy var glass = glassShelf(content, cornerRadius: 13)

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.contentTintColor = .labelColor
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        let icon = NSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        for view in [spinner, check] as [NSView] {
            view.frame = icon.bounds
            view.autoresizingMask = [.width, .height]
            icon.addSubview(view)
        }
        let row = NSStackView(views: [icon, label])
        row.spacing = 5
        row.alignment = .centerY
        content.addSubview(row)
        addSubview(glass)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityChildren([])
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let textWidth = (State.complete.rawValue as NSString).size(withAttributes: [.font: label.font!]).width
        return NSSize(width: ceil(textWidth) + 39, height: 26)
    }

    func show(_ next: State) {
        guard next != state else { return }
        state = next
        isHidden = next == .idle
        label.stringValue = next.rawValue
        setAccessibilityLabel(next.rawValue)
        check.isHidden = next != .complete
        if next == .scanning || next == .cancelling { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
        updateTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    private func updateTint() {
        let tint: NSColor = state == .complete ? .systemGreen : .systemBlue
        if #available(macOS 26.0, *), let effect = glass as? NSGlassEffectView {
            effect.tintColor = tint.withAlphaComponent(0.65)
        } else {
            content.wantsLayer = true
            effectiveAppearance.performAsCurrentDrawingAppearance {
                content.layer?.backgroundColor = tint.withAlphaComponent(0.38).cgColor
            }
        }
    }
}
