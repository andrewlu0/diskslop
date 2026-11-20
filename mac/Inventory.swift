import AppKit

final class ScanProgress: @unchecked Sendable {
    let handle = dt_progress_new()!
    deinit { dt_progress_free(handle) }
}

func takeError(_ error: UnsafeMutablePointer<CChar>?) -> String {
    guard let error else { return "The operation could not be completed." }
    defer { dt_string_free(error) }
    return String(cString: error)
}

struct DiskError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ScanModel: @unchecked Sendable {
    let observedAt: Int64
    let isScanPreview: Bool
    private struct Release: @unchecked Sendable {
        let pointer: OpaquePointer
        func run() { dt_model_free(pointer) }
    }
    let handle: OpaquePointer
    init(handle: OpaquePointer, isScanPreview: Bool = false) {
        self.handle = handle
        self.isScanPreview = isScanPreview
        observedAt = Int64(Date().timeIntervalSince1970)
    }
    private func encodePaths(_ paths: Set<String>) -> [UInt8] {
        var bytes: [UInt8] = []
        for path in paths {
            URL(fileURLWithPath: path).withUnsafeFileSystemRepresentation { p in
                if let p { bytes.append(contentsOf: UnsafeRawBufferPointer(start: p, count: strlen(p) + 1)) }
            }
        }
        return bytes
    }
    func refreshed(changes: ChangedDirectories, retryIssues: Bool = false, progress: ScanProgress) throws -> ScanModel {
        var error: UnsafeMutablePointer<CChar>?
        var unchanged = false
        let new = encodePaths(changes.shallow).withUnsafeBufferPointer { shallow in
            encodePaths(changes.recursive).withUnsafeBufferPointer { recursive in
                dt_revalidate_changes(handle, shallow.baseAddress, shallow.count, recursive.baseAddress, recursive.count, retryIssues, progress.handle, &unchanged, &error)
            }
        }
        if unchanged { return self }
        guard let new else { throw DiskError(message: takeError(error)) }
        return ScanModel(handle: new)
    }
    func refreshed(_ items: [DiskItem], progress: ScanProgress) throws -> ScanModel {
        let keys = items.map { DTKey(folder: $0.folder, slot: $0.slot) }
        var error: UnsafeMutablePointer<CChar>?
        let new = keys.withUnsafeBufferPointer { dt_refresh(handle, $0.baseAddress, $0.count, progress.handle, &error) }
        guard let new else { throw DiskError(message: takeError(error)) }
        return ScanModel(handle: new)
    }
    func route(to url: URL) -> [DiskItem]? {
        guard let list = url.withUnsafeFileSystemRepresentation({ dt_route(handle, $0) }) else { return nil }
        return readRoute(list, from: 0)
    }
    func route(to key: DTKey, from folder: UInt32) -> [DiskItem]? {
        guard let list = dt_key_route(handle, folder, key) else { return nil }
        return readRoute(list, from: folder)
    }
    private func readRoute(_ list: OpaquePointer, from root: UInt32) -> [DiskItem] {
        defer { dt_list_free(list) }
        var count = 0
        let start = dt_rows(list, &count)
        var folder = root
        return UnsafeBufferPointer(start: start, count: count).map { row in
            let item = DiskItem(row, folder: folder)
            folder = row.child
            return item
        }
    }
    init(url: URL, progress: ScanProgress, preview: Bool = true) throws {
        var error: UnsafeMutablePointer<CChar>?
        let model = url.withUnsafeFileSystemRepresentation { dt_scan_with_preview($0, progress.handle, preview, &error) }
        guard let model else { throw DiskError(message: takeError(error)) }
        handle = model
        isScanPreview = false
        observedAt = Int64(Date().timeIntervalSince1970)
    }
    deinit {
        let release = Release(pointer: handle)
        DispatchQueue.global(qos: .utility).async { release.run() }
    }

    func url(folder: UInt32, slot: UInt32 = .max, directory: Bool) -> URL? {
        guard let path = dt_path(handle, folder, slot) else { return nil }
        defer { dt_string_free(path) }
        return URL(fileURLWithFileSystemRepresentation: path, isDirectory: directory, relativeTo: nil)
    }

}

struct DiskItem: Equatable {
    let folder: UInt32, slot: UInt32, child: UInt32
    let title: String, bytes: UInt64
    var isFolder: Bool { child != .max }
    init(_ row: DTRow, folder: UInt32) {
        self.folder = folder; slot = row.slot; child = row.child; bytes = row.bytes; title = row.title
    }
}

final class FolderListing: @unchecked Sendable {
    let model: ScanModel
    let folder: UInt32
    let summary: DTSummary
    let geometry: FileMap
    init(_ model: ScanModel, folder: UInt32, aspect: CGFloat = 1.4, previous: FileMap? = nil) {
        self.model = model
        self.folder = folder
        summary = dt_summary(model.handle, folder)
        geometry = FileMap(model: model, folder: folder, aspect: aspect, previous: previous)
    }
}

extension DTRow {
    var title: String { String(decoding: UnsafeBufferPointer(start: name, count: name_len), as: UTF8.self) }
    var isFolder: Bool { child != UInt32.max }
    var symbol: String {
        if partial { return "folder.badge.questionmark" }
        if isFolder { return "folder" }
        return kind == 2 ? "link" : "doc"
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

func formatCount(_ count: UInt64) -> String { count.formatted(.number) }
