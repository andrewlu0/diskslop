import AppKit
import Quartz

final class PreviewWindow: NSWindow, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewURLs: [URL] = []
    private weak var controlledPanel: QLPreviewPanel?
    var clearBrowserSelection: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           isKeyWindow, attachedSheet == nil, !(firstResponder is NSTextView) {
            if let panel = controlledPanel, panel.isVisible { panel.close(); return }
            if clearBrowserSelection?() == true { return }
        }
        super.sendEvent(event)
    }

    func togglePreview(_ urls: [URL]) {
        if let panel = controlledPanel, panel.isVisible { panel.close(); return }
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        previewURLs = urls
        panel.makeKeyAndOrderFront(nil)
        panel.updateController()
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    func selectionDidChange(_ urls: () -> [URL]) {
        guard let panel = controlledPanel, panel.isVisible else { return }
        let next = urls()
        guard next != previewURLs else { return }
        previewURLs = next
        if next.isEmpty { panel.close() } else { panel.reloadData() }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controlledPanel = panel
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        controlledPanel = nil
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers == " " else { return false }
        panel.close()
        return true
    }
}
