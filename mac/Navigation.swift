import AppKit

struct DirectoryID: Equatable {
    let device: UInt64, inode: UInt64
    init(_ model: ScanModel, _ folder: UInt32) {
        let id = dt_directory_identity(model.handle, folder)
        device = id.device; inode = id.inode
    }
}

private final class SavedSelection: @unchecked Sendable {
    let keys: Set<UInt64>
    weak var source: ScanModel?
    private var bookmark: OpaquePointer?
    private let ready = DispatchGroup()

    init(_ model: ScanModel, keys: Set<UInt64>) {
        self.keys = keys; source = model
        guard !keys.isEmpty else { return }
        let capture = { [self] in
            bookmark = Array(keys).withUnsafeBufferPointer { dt_bookmark_new(model.handle, $0.baseAddress, $0.count) }
        }
        if keys.count <= 64 { capture() }
        else { DispatchQueue.global(qos: .userInitiated).async(group: ready) { capture() } }
    }
    deinit { if let bookmark { dt_bookmark_free(bookmark) } }

    func resolve(in model: ScanModel) -> [UInt64] {
        ready.wait()
        guard let bookmark else { return [] }
        return Array(unsafeUninitializedCapacity: keys.count) { buf, count in
            count = dt_bookmark_resolve(model.handle, bookmark, source === model, buf.baseAddress, buf.count)
        }
    }
}

struct NavigationVisit {
    let root: URL, folder: URL, rootID: DirectoryID, folderID: DirectoryID
    private let selection: SavedSelection
    private let folderNumber: UInt32
    let lead: UInt64?
    var viewport: CGRect
    var count: Int { selection.keys.count }

    init(model: ScanModel, root: URL, folder: URL, folderNumber: UInt32, keys: Set<UInt64>, lead: UInt64?, viewport: CGRect) {
        self.root = root; self.folder = folder
        self.folderNumber = folderNumber
        rootID = DirectoryID(model, 0); folderID = DirectoryID(model, folderNumber)
        selection = SavedSelection(model, keys: keys)
        self.lead = lead; self.viewport = viewport
    }
    func matches(_ model: ScanModel, folder: URL, keys: Set<UInt64>) -> Bool {
        selection.source === model && self.folder == folder && selection.keys == keys
    }
    func isIn(_ model: ScanModel, at id: UInt32) -> Bool {
        selection.source === model && folderNumber == id
    }
    func liveKeys(in model: ScanModel) -> [UInt64]? {
        let keys = selection.resolve(in: model)
        return selection.keys.isEmpty || !keys.isEmpty ? keys : nil
    }
    func resolve(in model: ScanModel) -> (route: [DiskItem], keys: [UInt64], lead: UInt64?)? {
        guard DirectoryID(model, 0) == rootID, let route = model.route(to: folder),
              route.isEmpty || route.last?.isFolder == true, DirectoryID(model, route.last?.child ?? 0) == folderID else { return nil }
        guard let keys = liveKeys(in: model) else { return nil }
        return (route, keys, selection.source === model ? lead : nil)
    }
}

struct SelectionHistory {
    private var visits: [NavigationVisit] = []
    private var index = -1
    var current: NavigationVisit? { visits.indices.contains(index) ? visits[index] : nil }
    func adjacent(_ direction: Int) -> NavigationVisit? {
        let target = index + direction
        return visits.indices.contains(target) ? visits[target] : nil
    }
    mutating func record(_ entry: NavigationVisit, replace: Bool) {
        if replace, visits.indices.contains(index) { visits[index] = entry; return }
        visits.removeSubrange((index + 1)..<visits.count)
        visits.append(entry)
        var total = visits.reduce(0) { $0 + $1.count }
        while visits.count > 128 || (visits.count > 2 && total > 262_144) {
            total -= visits.removeFirst().count
        }
        index = visits.count - 1
    }
    mutating func updateViewport(_ port: CGRect) {
        if visits.indices.contains(index) { visits[index].viewport = port }
    }
    mutating func step(_ direction: Int) { index += direction }
    mutating func discard(_ direction: Int) {
        visits.remove(at: index + direction)
        if direction < 0 { index -= 1 }
    }
}
