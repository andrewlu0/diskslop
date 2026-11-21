import AppKit

struct ScanMapRequest {
    let aspect: CGFloat, mode: MapColorMode, sort: (key: String, ascending: Bool)
    let settings: MapRenderSettings?, priorFrame: (FileMap, RenderedFiles)?
    let radial: Bool, dimensions: SunburstStyle

    func prepare(_ list: FolderListing, progress: ScanProgress, afterTrash: Bool = false) -> ScanMapFrame? {
        guard !dt_is_cancelled(progress.handle) else { return nil }
        let colors = mode == .kind ? nil : MapBreakdown(list, mode: mode, progress: progress)
        guard !dt_is_cancelled(progress.handle) else { return nil }
        var order: MapGroupOrder?
        if let colors, sort != (mode.ordered ? "kind" : "bytes", mode.ordered) {
            order = MapGroupOrder(colors.handle, key: sort.key, ascending: sort.ascending)
        }
        let frame = settings.flatMap { spec in
            spec.render(list.geometry, colors: colors).map { LiveMapFrame($0, geometry: list.geometry, settings: spec, colors: colors, source: priorFrame, afterTrash: afterTrash) }
        }
        let rings = radial ? Rings(list, colors: colors, radius: dimensions.radius, scale: dimensions.scale, style: dimensions) {
            dt_is_cancelled(progress.handle)
        } : nil
        return ScanMapFrame(list: list, colors: colors, order: order, raster: frame, rings: rings)
    }
}

struct ScanMapFrame {
    let list: FolderListing, colors: MapBreakdown?, order: MapGroupOrder?
    let raster: LiveMapFrame?, rings: Rings?
}

final class RestoredScanPreview: @unchecked Sendable {
    private let pending = DispatchGroup()
    private var listing: FolderListing?

    func prepare(_ model: ScanModel, aspect: CGFloat, progress: ScanProgress, publish: @escaping (FolderListing) -> Void) {
        pending.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.pending.leave() }
            guard !dt_is_cancelled(progress.handle) else { return }
            let list = FolderListing(model, folder: 0, aspect: aspect)
            self.listing = list
            publish(list)
        }
    }

    func ready() -> FolderListing? {
        pending.wait()
        return listing
    }
}

final class ScanWorkspace: @unchecked Sendable {
    let root: URL, progress: ScanProgress
    var rankRevision: UInt64 = 0
    var indexed: ScanModel?, indexedRankingStarted = false, indexedRankingDisplayed = false
    var deferredFrame: (ScanMapRequest, ScanMapFrame)?
    var visit: NavigationVisit?
    var navigationRequest: UUID?
    private var preparing = false, earliest = 0.0
    private let lock = NSLock()
    private var enumerating = true
    private weak var geometry: FileMap?
    private var geometryFolder: URL?
    private static let queue = DispatchQueue(label: "local.diskslop.scan-workspace", qos: .userInitiated)

    init(root: URL, progress: ScanProgress) {
        self.root = root; self.progress = progress
        dt_enable_scan_workspace(progress.handle)
    }

    func update(visit: NavigationVisit?, request: () -> ScanMapRequest,
                publish: @escaping (ScanMapRequest, ScanMapFrame) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        let scope: URL? = visit.flatMap { $0.folder == $0.root ? nil : $0.folder }
        guard !preparing, now >= earliest, lock.withLock({ enumerating }) else { return }
        preparing = true
        let request = request()
        Self.queue.async {
            let previous = self.lock.withLock { self.geometryFolder == scope ? self.geometry : nil }
            let frame: ScanMapFrame? = autoreleasepool {
                guard !dt_is_cancelled(self.progress.handle),
                      let handle = dt_scan_workspace_next(self.progress.handle) else { return nil }
                let model = ScanModel(handle: handle, isScanPreview: true)
                let folder: UInt32
                if let visit {
                    guard let route = visit.resolve(in: model) else { return nil }
                    folder = route.last?.child ?? 0
                } else { folder = 0 }
                let list = FolderListing(model, folder: folder, aspect: request.aspect, previous: previous)
                self.lock.withLock {
                    self.geometry = list.geometry
                    self.geometryFolder = scope
                }
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
        let previous = lock.withLock {
            enumerating = false
            return geometryFolder == nil ? geometry : nil
        }
        dt_close_scan_workspace(progress.handle)
        return previous
    }
}
