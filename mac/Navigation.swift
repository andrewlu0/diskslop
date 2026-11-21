import AppKit

struct DirectoryID: Equatable {
    let device: UInt64, inode: UInt64
    init(_ model: ScanModel, _ folder: UInt32) {
        let id = dt_directory_identity(model.handle, folder)
        device = id.device; inode = id.inode
    }
}

final class SavedSelection: @unchecked Sendable {
    private let keys: Set<UInt64>
    private weak var source: ScanModel?
    private let lead: UInt64?
    private var bookmark: OpaquePointer?
    private let ready = DispatchGroup()

    init(_ model: ScanModel, keys: Set<UInt64>, lead: UInt64?) {
        self.keys = keys; self.lead = lead; source = model
        guard !keys.isEmpty else { return }
        let capture = { [self] in
            bookmark = Array(keys).withUnsafeBufferPointer { dt_bookmark_new(model.handle, $0.baseAddress, $0.count) }
        }
        if keys.count <= 64 { capture() }
        else { DispatchQueue.global(qos: .userInitiated).async(group: ready) { capture() } }
    }
    deinit { if let bookmark { dt_bookmark_free(bookmark) } }

    func matches(_ model: ScanModel, keys: Set<UInt64>) -> Bool {
        source === model && self.keys == keys
    }
    func lead(in model: ScanModel) -> UInt64? { source === model ? lead : nil }
    func resolve(in model: ScanModel) -> [UInt64] {
        ready.wait()
        guard let bookmark else { return [] }
        return Array(unsafeUninitializedCapacity: keys.count) { buf, count in
            count = dt_bookmark_resolve(model.handle, bookmark, source === model, buf.baseAddress, buf.count)
        }
    }
}

struct NavigationVisit {
    let root: URL, folder: URL
    private let rootID: DirectoryID, folderID: DirectoryID
    var viewport: CGRect

    init(model: ScanModel, root: URL, folder: URL, folderNumber: UInt32, viewport: CGRect) {
        self.root = root; self.folder = folder
        rootID = DirectoryID(model, 0); folderID = DirectoryID(model, folderNumber)
        self.viewport = viewport
    }
    func isSameFolder(as other: NavigationVisit) -> Bool {
        root == other.root && folder == other.folder && rootID == other.rootID && folderID == other.folderID
    }
    func resolve(in model: ScanModel) -> [DiskItem]? {
        guard DirectoryID(model, 0) == rootID, let route = model.route(to: folder),
              route.isEmpty || route.last?.isFolder == true, DirectoryID(model, route.last?.child ?? 0) == folderID else { return nil }
        return route
    }
}

struct FolderHistory {
    private var visits: [NavigationVisit] = []
    private var index = -1
    var current: NavigationVisit? { visits.indices.contains(index) ? visits[index] : nil }
    func adjacent(_ direction: Int) -> NavigationVisit? {
        let target = index + direction
        return visits.indices.contains(target) ? visits[target] : nil
    }
    mutating func record(_ entry: NavigationVisit, replace: Bool) {
        if let current, replace || entry.isSameFolder(as: current) {
            while adjacent(-1)?.isSameFolder(as: entry) == true { discard(-1) }
            while adjacent(1)?.isSameFolder(as: entry) == true { discard(1) }
            visits[index] = entry
            return
        }
        visits.removeSubrange((index + 1)..<visits.count)
        visits.append(entry)
        if visits.count > 128 { visits.removeFirst() }
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
