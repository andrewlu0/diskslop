import AppKit

func shadeUnselected(in context: CGContext, chart: CGPath, selected: CGPath) {
    guard !selected.isEmpty else { return }
    context.saveGState()
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.addPath(chart)
    context.setFillColor(CGColor(gray: 0, alpha: 0.12))
    context.drawPath(using: .eoFill)
    context.setBlendMode(.clear)
    context.addPath(selected)
    context.fillPath()
    context.setBlendMode(.normal)
    context.endTransparencyLayer()
    context.restoreGState()
}

enum MapColorMode: Int, CaseIterable {
    case kind, created, modified, accessed, folder, topFolder, fileExtension, depth, size, name

    var title: String {
        switch self {
        case .kind: return "File Kind"
        case .created: return "Creation Date"
        case .modified: return "Last Modified"
        case .accessed: return "Last Accessed"
        case .folder: return "Folder"
        case .topFolder: return "Top-Level Folder"
        case .fileExtension: return "File Extension"
        case .depth: return "Folder Depth"
        case .size: return "Allocated Size"
        case .name: return "File Name"
        }
    }
    var column: String {
        switch self {
        case .created, .modified, .accessed: return "Age"
        case .folder, .topFolder: return "Folder"
        case .fileExtension: return "Extension"
        case .depth: return "Depth"
        case .size: return "Size Range"
        case .name: return "Name"
        case .kind: return "Kind"
        }
    }
    var ordered: Bool { [.created, .modified, .accessed, .depth, .size].contains(self) }
    var help: String {
        switch self {
        case .created, .modified, .accessed: return "Age at scan time. Recent files use warm colors and older files use cool colors."
        case .folder: return "Files directly inside the same folder share a color."
        case .topFolder: return "Each folder directly below the map root shares its color with all its descendants."
        case .fileExtension: return "Group files by their final filename extension."
        case .depth: return "Depth counts folders below the current map root."
        case .size: return "Group files by the bytes they occupy on disk."
        case .name: return "Group files with the same full filename across folders."
        case .kind: return "Group by Finder file kind and recognized package."
        }
    }
    var glyph: String {
        switch self {
        case .created, .modified: return "calendar"
        case .accessed: return "clock"
        case .folder, .topFolder, .depth: return "folder"
        case .size: return "hard-drive"
        default: return "file"
        }
    }
    static func populate(_ menu: NSMenu, target: AnyObject?, action: Selector?) {
        for section in [[Self.kind, .fileExtension, .name], [.folder, .topFolder, .depth], [.created, .modified, .accessed], [.size]] {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            for mode in section {
                let item = menu.addItem(withTitle: mode.title, action: action, keyEquivalent: "")
                item.tag = mode.rawValue
                item.target = target
            }
        }
    }
    fileprivate var palette: MapPalette {
        switch self {
        case .created, .modified, .accessed: return .age
        case .size: return .size
        case .depth: return .depth
        default: return .categories
        }
    }
    func label(tag: UInt32, text: String) -> String {
        switch self {
        case .created, .modified, .accessed:
            return ["Past 24 hours", "1–6 days", "7–29 days", "30–89 days", "90–364 days",
                "1–2 years", "3–4 years", "5–9 years", "10 years or older", "Future date", "Unknown date"][Int(tag)]
        case .depth:
            return ["At map root", "1 level deep", "2 levels deep", "3 levels deep", "4–7 levels deep",
                "8–15 levels deep", "16+ levels deep"][Int(tag)]
        case .size:
            return ["Zero bytes", "Under 1 MB", "1–<10 MB", "10–<100 MB", "100 MB–<1 GB",
                "1–<10 GB", "10–<100 GB", "100 GB–<1 TB", "1 TB or more"][Int(tag)]
        case .folder, .topFolder: return text.isEmpty ? "This folder" : text
        case .fileExtension: return text.isEmpty ? "No extension" : "." + text
        default: return text
        }
    }
}

private struct MapPalette {
    let tones: [KindTone], light: [DTGlassTint], dark: [DTGlassTint]
    init(_ tones: [KindTone]) {
        self.tones = tones
        light = tones.map { dt_glass_tint($0.light) }
        dark = tones.map { dt_glass_tint($0.dark) }
    }
    static let age = Self([.red, .orange, .amber, .lime, .emerald, .teal, .sky, .blue, .indigo, .fuchsia, .neutral])
    static let size = Self([.neutral, .indigo, .blue, .sky, .teal, .lime, .amber, .orange, .red])
    static let depth = Self([.amber, .lime, .emerald, .teal, .sky, .indigo, .violet])
    static let categories = Self(KindTone.categories)
}

final class MapGroupOrder: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ groups: OpaquePointer, key: String, ascending: Bool) {
        handle = dt_groups_sorted(groups, key == "bytes" ? 2 : key == "files" ? 1 : 0, ascending)!
    }
    func group(at row: Int) -> UInt32 { dt_order_group(handle, row) }
    func row(for id: UInt32) -> Int? {
        let rank = dt_order_rank(handle, id)
        return rank == .max ? nil : Int(rank)
    }
    deinit { dt_order_free(handle) }
}

final class MapBreakdown: @unchecked Sendable {
    let handle: OpaquePointer, mode: MapColorMode, defaultOrder: MapGroupOrder
    let count: Int, memoryBytes: Int, maximumCount: UInt64
    init?(_ list: FolderListing, mode: MapColorMode, progress: ScanProgress) {
        guard let result = dt_groups_new(list.model.handle, list.folder, UInt8(mode.rawValue), list.model.observedAt, progress.handle) else { return nil }
        handle = result
        self.mode = mode
        count = dt_groups_count(result)
        maximumCount = dt_groups_max_files(result)
        defaultOrder = MapGroupOrder(result, key: mode.ordered ? "kind" : "bytes", ascending: mode.ordered)
        memoryBytes = dt_groups_memory(result) + count * 2 * MemoryLayout<UInt32>.size
    }
    func usage(_ id: UInt32) -> KindUsage? {
        var info = DTGroupInfo(), length = 0
        guard let raw = dt_group_read(handle, id, &info, &length) else { return nil }
        let name = mode.label(tag: info.tag, text: String(decoding: UnsafeBufferPointer(start: raw, count: length), as: UTF8.self))
        let tones = mode.palette.tones
        let group = FileKind(id: id, identifier: name, title: name, glyph: mode.glyph,
            tone: tones[Int(info.color) % tones.count], vary: false)
        return KindUsage(kind: group, bytes: info.bytes, files: info.files)
    }
    func group(at key: DTKey) -> UInt32? {
        let group = dt_group_at(handle, key)
        return group == .max ? nil : group
    }
    func tone(for group: UInt32) -> KindTone? {
        var info = DTGroupInfo(), length = 0
        guard dt_group_read(handle, group, &info, &length) != nil else { return nil }
        let tones = mode.palette.tones
        return tones[Int(info.color) % tones.count]
    }
    func group(forDirectory id: UInt32) -> UInt32? {
        let group = dt_group_directory(handle, id)
        return group == .max ? nil : group
    }
    func palette(dark: Bool) -> [DTGlassTint] { dark ? mode.palette.dark : mode.palette.light }
    private struct Release: @unchecked Sendable {
        let pointer: OpaquePointer
        func run() { dt_groups_free(pointer) }
    }
    deinit {
        let release = Release(pointer: handle)
        DispatchQueue.global(qos: .utility).async { release.run() }
    }
}
