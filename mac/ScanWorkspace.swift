import AppKit

struct ScanMapRequest {
    let aspect: CGFloat, mode: MapColorMode, sort: (key: String, ascending: Bool)
    let settings: MapRenderSettings?, priorFrame: (FileMap, RenderedFiles)?
    let radial: Bool, dimensions: (radius: CGFloat, scale: CGFloat)

    func prepare(_ list: FolderListing, progress: ScanProgress) -> ScanMapFrame? {
        guard !dt_is_cancelled(progress.handle) else { return nil }
        let colors = mode == .kind ? nil : MapBreakdown(list, mode: mode, progress: progress)
        guard !dt_is_cancelled(progress.handle) else { return nil }
        var order: MapGroupOrder?
        if let colors, sort != (mode.ordered ? "kind" : "bytes", mode.ordered) {
            order = MapGroupOrder(colors.handle, key: sort.key, ascending: sort.ascending)
        }
        let frame = settings.flatMap { spec in
            spec.render(list.geometry, colors: colors).map { LiveMapFrame($0, geometry: list.geometry, settings: spec, source: priorFrame) }
        }
        let rings = radial ? Rings(list, colors: colors, radius: dimensions.radius, scale: dimensions.scale) {
            dt_is_cancelled(progress.handle)
        } : nil
        return ScanMapFrame(list: list, colors: colors, order: order, raster: frame, rings: rings)
    }
}

struct ScanMapFrame {
    let list: FolderListing, colors: MapBreakdown?, order: MapGroupOrder?
    let raster: LiveMapFrame?, rings: Rings?
}

final class ScanWorkspace: @unchecked Sendable {
    let root: URL, progress: ScanProgress
    var rankRevision: UInt64 = 0
    var indexed: ScanModel?, indexedRankingStarted = false, indexedRankingDisplayed = false
    var deferredFrame: (ScanMapRequest, ScanMapFrame)?
    private var preparing = false, earliest = 0.0
    private let lock = NSLock()
    private var enumerating = true
    private weak var geometry: FileMap?
    private static let queue = DispatchQueue(label: "local.diskslop.scan-workspace", qos: .userInitiated)

    init(root: URL, progress: ScanProgress) {
        self.root = root; self.progress = progress
        dt_enable_scan_workspace(progress.handle)
    }

    func update(request: () -> ScanMapRequest, publish: @escaping (ScanMapRequest, ScanMapFrame) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !preparing, now >= earliest, lock.withLock({ enumerating }) else { return }
        preparing = true
        let request = request()
        Self.queue.async {
            let previous = self.lock.withLock { self.geometry }
            let frame: ScanMapFrame? = autoreleasepool {
                guard !dt_is_cancelled(self.progress.handle),
                      let handle = dt_scan_workspace_next(self.progress.handle) else { return nil }
                let model = ScanModel(handle: handle, isScanPreview: true)
                let list = FolderListing(model, folder: 0, aspect: request.aspect, previous: previous)
                self.lock.withLock { self.geometry = list.geometry }
                return request.prepare(list, progress: self.progress)
            }
            DispatchQueue.main.async {
                self.preparing = false
                if let frame, !dt_is_cancelled(self.progress.handle) {
                    let end = ProcessInfo.processInfo.systemUptime
                    self.earliest = end + min(0.75, max(0.08, (end - now) * 0.3))
                    publish(request, frame)
                }
            }
        }
    }

    func finishEnumeration() -> FileMap? {
        let previous = lock.withLock { enumerating = false; return geometry }
        dt_close_scan_workspace(progress.handle)
        return previous
    }
}
