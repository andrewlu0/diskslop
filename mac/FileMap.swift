import AppKit

extension DiskItem {
    var key: UInt64 { UInt64(folder) << 32 | UInt64(slot) }
}

extension DTKey {
    init(_ key: UInt64) {
        self.init(folder: UInt32(truncatingIfNeeded: key >> 32), slot: UInt32(truncatingIfNeeded: key))
    }
}
extension DTRect {
    init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, w: r.width, h: r.height) }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct FileLabel {
    let rect: CGRect, title: String, size: String
}
struct RenderedFiles {
    let image: CGImage, labels: [FileLabel], viewport: CGRect, dark: Bool
}

final class FileMap: @unchecked Sendable {
    let model: ScanModel
    let folder: UInt32, count: Int, memoryBytes: UInt64
    let kinds: [KindUsage]
    let aspect: CGFloat
    private let handle: OpaquePointer
    init(model: ScanModel, folder: UInt32, aspect: CGFloat) {
        self.model = model
        self.folder = folder
        self.aspect = aspect
        handle = dt_map_new(model.handle, folder, aspect, resolveFileKind)!
        count = dt_map_count(handle)
        memoryBytes = UInt64(dt_map_memory(handle))
        var length = 0
        let totals = dt_map_kinds(handle, &length)
        kinds = UnsafeBufferPointer(start:totals, count:length).map {
            KindUsage(kind:FileKindCatalog.shared.kind($0.kind), bytes:$0.bytes, files:$0.files)
        }.sorted { a,b in a.bytes == b.bytes ? a.kind.title.localizedStandardCompare(b.kind.title) == .orderedAscending : a.bytes > b.bytes }
    }
    private struct Retired: @unchecked Sendable {
        let pointer: OpaquePointer
        func releaseStorage() { dt_map_free(pointer) }
    }
    deinit {
        let retired = Retired(pointer: handle)
        DispatchQueue.global(qos: .utility).async { retired.releaseStorage() }
    }
    func bounds(of key: UInt64) -> CGRect? {
        var rect = DTRect()
        return dt_map_bounds(handle, DTKey(key), &rect) ? rect.rect : nil
    }
    func hit(_ p: CGPoint) -> DTKey? {
        var key = DTKey()
        return dt_map_hit(handle, p.x, p.y, &key) ? key : nil
    }
    func keys(in area: CGRect) -> [DTKey] {
        guard let selected = dt_map_selection(handle, DTRect(area)) else { return [] }
        defer { dt_selection_free(selected) }
        var count = 0
        let keys = dt_selection_keys(selected, &count)
        return Array(UnsafeBufferPointer(start: keys, count: count))
    }
    func routes(_ keys: [DTKey]) -> [[DiskItem]] {
        var parents: [UInt32: [DiskItem]] = [:]
        return keys.compactMap { key in
            if let parent = parents[key.folder] {
                var row = DTRow()
                guard dt_entry(model.handle, key.folder, key.slot, &row) else { return nil }
                return parent + [DiskItem(row, folder: key.folder)]
            }
            guard let path = model.route(to: key, from: folder) else { return nil }
            parents[key.folder] = Array(path.dropLast())
            return path
        }
    }
    func kind(at key: DTKey) -> UInt32 { dt_map_kind(handle, key) }
    func render(viewport: CGRect, width: Int, height: Int, scale: CGFloat, dark: Bool = true, shine: Bool = true) -> RenderedFiles? {
        let palette = FileKindCatalog.shared.palette(dark:dark)
        let frame = palette.withUnsafeBufferPointer {
            dt_map_render(handle, DTRect(viewport), UInt32(width), UInt32(height), scale, $0.baseAddress, $0.count, shine)
        }
        guard let frame else { return nil }
        var count = 0
        let rawLabels = dt_frame_labels(frame, &count)
        let labels: [FileLabel] = UnsafeBufferPointer(start: rawLabels, count: count).compactMap { raw in
            var item = DTRow()
            guard dt_entry(model.handle, raw.key.folder, raw.key.slot, &item) else { return nil }
            return FileLabel(rect: raw.rect.rect, title: item.title, size: formatBytes(item.bytes))
        }
        guard let provider = CGDataProvider(dataInfo: UnsafeMutableRawPointer(frame), data: dt_frame_pixels(frame),
            size: width * height * 4, releaseData: { p, _, _ in if let p { dt_frame_free(OpaquePointer(p)) } }) else {
            dt_frame_free(frame)
            return nil
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder32Big)
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return RenderedFiles(image: image, labels: labels, viewport: viewport, dark: dark)
    }
}
