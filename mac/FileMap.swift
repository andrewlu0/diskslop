import AppKit

extension DiskItem {
    static let scanRootKey = UInt64(UInt32.max)
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

struct MapItemName: Hashable {
    let parent: UInt64, name: String
}
struct FileLabel {
    let key: UInt64, identity: MapItemName
    let rect: CGRect, title: String, size: String, lightInk: Bool
}
struct RenderedFiles {
    let image: CGImage, labels: [FileLabel], viewport: CGRect, focus: LegendFocus?
    fileprivate let pixels: UnsafePointer<UInt8>

    func rgb(at point: CGPoint) -> UInt32 {
        let x = min(image.width - 1, max(0, Int((point.x - viewport.minX) / viewport.width * CGFloat(image.width))))
        let y = min(image.height - 1, max(0, Int((point.y - viewport.minY) / viewport.height * CGFloat(image.height))))
        return withExtendedLifetime(image) {
            let pixel = pixels + y * image.bytesPerRow + x * 4
            return UInt32(pixel[0]) << 16 | UInt32(pixel[1]) << 8 | UInt32(pixel[2])
        }
    }
}

final class FileMap: @unchecked Sendable {
    let model: ScanModel
    let folder: UInt32, count: Int
    var memoryBytes: UInt64 { UInt64(dt_map_memory(handle)) }
    let kinds: [KindUsage]
    let aspect: CGFloat
    private let handle: OpaquePointer
    init(model: ScanModel, folder: UInt32, aspect: CGFloat, previous: FileMap? = nil) {
        self.model = model
        self.folder = folder
        self.aspect = aspect
        handle = previous.flatMap { dt_map_refresh($0.handle, $0.model.handle, model.handle, folder, aspect, resolveFileKind) }
            ?? dt_map_new(model.handle, folder, aspect, resolveFileKind)!
        count = dt_map_count(handle)
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
    func reflow(from previous: FileMap, in settings: MapRenderSettings) -> [ChartPatch] {
        guard previous.model === model, previous.folder == folder else { return [] }
        let scale = min(1, 192 / Double(max(settings.width, settings.height)))
        let w = max(1, Int(Double(settings.width) * scale)), h = max(1, Int(Double(settings.height) * scale))
        let tiles = [DTReflowTile](unsafeUninitializedCapacity: w * h) { buffer, count in
            count = dt_map_reflow(previous.handle, handle, DTRect(settings.viewport), UInt32(w), UInt32(h), buffer.baseAddress, buffer.count)
        }
        return tiles.map { ChartPatch(from: $0.from.vector, to: $0.to.vector) }
    }
    func kind(at key: DTKey) -> UInt32 { dt_map_kind(handle, key) }
    func motionTiles(in frame: RenderedFiles) -> [MapItemName: (key: UInt64, rect: CGRect)] {
        var tiles = Dictionary(frame.labels.map { ($0.identity, (key: $0.key, rect: $0.rect)) }, uniquingKeysWith: { first, _ in first })
        guard tiles.count < count else { return tiles }
        var seen = Set(tiles.values.map(\.key))
        let port = frame.viewport
        for y in 0..<6 {
            for x in 0..<8 {
                let point = CGPoint(x: port.minX + (CGFloat(x)+0.5)*port.width/8, y: port.minY + (CGFloat(y)+0.5)*port.height/6)
                guard let key = hit(point) else { continue }
                let packed = UInt64(key.folder) << 32 | UInt64(key.slot)
                guard seen.insert(packed).inserted, let rect = bounds(of: packed) else { continue }
                var row = DTRow()
                guard dt_entry(model.handle, key.folder, key.slot, &row) else { continue }
                tiles[MapItemName(parent: dt_directory_identity(model.handle, key.folder).inode, name: row.title)] = (packed, rect)
            }
        }
        return tiles
    }
    func render(viewport: CGRect, width: Int, height: Int, scale: CGFloat, dark: Bool = true, shine: Bool = true, coloring: MapBreakdown? = nil, focus: LegendFocus? = nil) -> RenderedFiles? {
        let palette = coloring?.palette(dark: dark) ?? FileKindCatalog.shared.palette(dark:dark)
        let frame = palette.withUnsafeBufferPointer {
            dt_map_render_focused(handle, DTRect(viewport), UInt32(width), UInt32(height), scale, $0.baseAddress, $0.count,
                shine, coloring?.handle, focus?.resolve(in: coloring) ?? .max)
        }
        guard let frame else { return nil }
        var count = 0
        let rawLabels = dt_frame_labels(frame, &count)
        let labels: [FileLabel] = UnsafeBufferPointer(start: rawLabels, count: count).compactMap { raw in
            var item = DTRow()
            guard dt_entry(model.handle, raw.key.folder, raw.key.slot, &item) else { return nil }
            let title = item.title
            let identity = MapItemName(parent: dt_directory_identity(model.handle, raw.key.folder).inode, name: title)
            return FileLabel(key: UInt64(raw.key.folder) << 32 | UInt64(raw.key.slot), identity: identity,
                rect: raw.rect.rect, title: title, size: formatBytes(item.bytes), lightInk: raw.light_ink)
        }
        let pixels = dt_frame_pixels(frame)!
        guard let provider = CGDataProvider(dataInfo: UnsafeMutableRawPointer(frame), data: pixels,
            size: width * height * 4, releaseData: { p, _, _ in if let p { dt_frame_free(OpaquePointer(p)) } }) else {
            dt_frame_free(frame)
            return nil
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder32Big)
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return RenderedFiles(image: image, labels: labels, viewport: viewport, focus: focus, pixels: pixels)
    }
}

private extension DTBox {
    var vector: SIMD4<Float> { SIMD4(x0, y0, x1, y1) }
}
