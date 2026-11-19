import AppKit
import UniformTypeIdentifiers

struct KindTone {
    let ink: UInt32, nightInk: UInt32, lightTile: UInt32, darkTile: UInt32
    init(_ ink: UInt32, _ night: UInt32) {
        self.ink = ink
        nightInk = night
        lightTile = Self.mix(ink, 0xffffff, 0.53)
        darkTile = Self.mix(Self.mix(ink, night, 0.23), 0x15171d, 0.28)
    }
    static func mix(_ a: UInt32, _ b: UInt32, _ fraction: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 255)
            let y = Double((b >> shift) & 255)
            return UInt32((x + (y - x) * fraction).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
    static let blue = Self(0x3455df, 0x96adff), violet = Self(0x7c3aed, 0xc4b5fd)
    static let green = Self(0x168044, 0x86efac), cyan = Self(0x087e96, 0x67e8f9)
    static let amber = Self(0xb46909, 0xfcd34d), orange = Self(0xc45013, 0xfdba74)
    static let pink = Self(0xb42b83, 0xf9a8d4), rose = Self(0xc43752, 0xfda4af)
    static let teal = Self(0x0c8377, 0x74e1cf), indigo = Self(0x5046c7, 0xa5b4fc)
    static let lime = Self(0x648815, 0xc4e777), sky = Self(0x217ab4, 0x90d8ff)
    static let purple = Self(0x893ac9, 0xd8b4fe), red = Self(0xc24138, 0xf6aaa4)
    static let neutral = Self(0x666b7d, 0xc0c3d0)
    static let coral = Self(0xd74744, 0xffa9a4), gold = Self(0xb88d08, 0xf3db7e)
    static let glacier = Self(0x3283a8, 0x9cdeed)

    static func variation(_ hash: UInt32, near ink: UInt32?) -> Self {
        var hue = Double(hash % 65521) / 65521
        if let ink {
            let anchor = Double(NSColor(rgb: ink).hueComponent)
            hue = (anchor + (hue - 0.5) * 0.38 + 1).truncatingRemainder(dividingBy: 1)
        }
        hue *= 6
        let sector = Int(hue)
        let x = hue - Double(sector)
        let channels = [(1.0, x, 0.0), (1 - x, 1, 0), (0, 1, x), (0, 1 - x, 1), (x, 0, 1), (1, 0, 1 - x)][sector]
        func color(low: Double, high: Double) -> UInt32 {
            func channel(_ value: Double) -> UInt32 { UInt32((low + (high - low) * value).rounded()) }
            return channel(channels.0) << 16 | channel(channels.1) << 8 | channel(channels.2)
        }
        return Self(color(low: 38, high: 178), color(low: 125, high: 240))
    }
}
extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}
extension NSAppearance {
    var usesDarkColors: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

struct FileKind {
    let id: UInt32, identifier: String, title: String, glyph: String
    let tone: KindTone, light: UInt32, dark: UInt32

    init(id: UInt32, identifier: String, title: String, glyph: String, tone: KindTone, vary: Bool) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.glyph = glyph
        self.tone = tone
        let hash = title.lowercased().utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        let accent = KindTone.variation(hash, near: glyph == "file" ? nil : tone.ink)
        let amount = glyph == "file" ? 0.82 : vary ? 0.35 + Double((hash >> 8) % 30) / 100 : 0.08
        light = KindTone.mix(tone.lightTile, accent.lightTile, amount)
        dark = KindTone.mix(tone.darkTile, accent.darkTile, amount)
    }
    func fill(darkMode: Bool) -> UInt32 { darkMode ? dark : light }
    func tint(darkMode: Bool) -> NSColor { NSColor(rgb: darkMode ? tone.nightInk : tone.ink) }
}
struct KindUsage { let kind: FileKind, bytes: UInt64, files: UInt64 }

private struct KindStyle {
    let glyph: String, tone: KindTone
    let vary: Bool
    init(_ glyph: String, _ tone: KindTone, vary: Bool = false) {
        self.glyph = glyph
        self.tone = tone
        self.vary = vary
    }

    static func resolve(_ type: UTType, suffix: String, identifier: String) -> Self {
        let id = type.identifier.lowercased()
        if type.conforms(to: .applicationBundle) || id == "com.apple.application" { return Self("applications", .coral) }
        if type.conforms(to: .applicationExtension) || id.contains("plug-in") || suffix == "plugin" {
            return Self("plug-2", .orange)
        }
        if type.conforms(to: .framework) { return Self("cubes", .indigo) }
        if ["mlmodelc", "mlpackage", "safetensors", "gguf"].contains(suffix) || id.contains("coreml")
            || id.contains("core-ml")
        {
            return Self("brain-nodes", .teal)
        }
        if suffix == "xcarchive" || id.contains("xcode.archive") { return Self("code-editor", .blue) }
        if type.conforms(to: .diskImage) || ["dmg", "iso", "sparseimage", "sparsebundle"].contains(suffix) {
            return Self("hard-drive", .red)
        }
        if ["pkg", "mpkg"].contains(suffix) || id.contains("installer-package") { return Self("box-archive-2", .orange) }
        if type.conforms(to: .package) || type.conforms(to: .bundle) { return Self("box-archive-2", .violet, vary: true) }
        if type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) { return Self("file-link", .sky) }
        if type.conforms(to: .pdf) { return Self("report-file", .glacier) }
        if type.conforms(to: .json) || ["json", "jsonl", "ndjson", "geojson"].contains(suffix) {
            return Self("brackets-curly", .cyan, vary: type != .json)
        }
        if type.conforms(to: .rawImage) { return Self("camera", .pink, vary: true) }
        if type.conforms(to: .png) { return Self("file-image", .amber) }
        if type.conforms(to: .jpeg) { return Self("image", .green) }
        if suffix == "svg" || id.contains("vector") { return Self("color-palette", .pink) }
        if suffix == "gif" { return Self("file-gif", .orange) }
        if type.conforms(to: .image) { return Self("file-image", .teal, vary: true) }
        if type.conforms(to: .audio) { return Self("file-music", .violet, vary: true) }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            return Self("clapperboard-play", .pink, vary: true)
        }
        if type.conforms(to: .font) { return Self("text-size", .purple, vary: true) }
        if type.conforms(to: .database) || ["sqlite", "sqlite3", "db-wal", "parquet", "arrow"].contains(suffix) {
            return Self("database", .teal, vary: true)
        }
        if type.conforms(to: .spreadsheet) || ["xlsx", "xls", "csv", "tsv"].contains(suffix) {
            return Self("table", .green, vary: true)
        }
        if type.conforms(to: .presentation) || ["ppt", "pptx", "key"].contains(suffix) {
            return Self("presentation-screen", .orange, vary: true)
        }
        if type.conforms(to: .archive) || ["zip", "gz", "bz2", "xz", "zst", "rar", "7z", "tar", "xip"].contains(suffix) {
            return Self("file-zip", .amber, vary: true)
        }
        if suffix == "dylib" || id.contains("dynamic-library") { return Self("cubes", .sky) }
        if suffix == "o" || id.contains("object-code") { return Self("cube", .purple) }
        if ["pyc", "wasm", "class", "bc", "air", "metallib", "a", "so"].contains(suffix) {
            return Self("microchip", .indigo, vary: true)
        }
        if type.conforms(to: .unixExecutable) || type.conforms(to: .executable) { return Self("terminal", .gold) }
        if suffix == "md" || suffix == "markdown" || id.contains("markdown") { return Self("markdown", .indigo) }
        if type.conforms(to: .html) { return Self("window-code", .orange) }
        if suffix == "js" || suffix == "mjs" || suffix == "cjs" { return Self("square-code", .amber) }
        if suffix == "py" { return Self("terminal", .blue) }
        if suffix == "sql" { return Self("database", .cyan) }
        if type.conforms(to: .propertyList) || ["yml", "yaml", "toml", "ini"].contains(suffix) {
            return Self("file-settings", .orange, vary: true)
        }
        if type.conforms(to: .script) { return Self("terminal", .teal, vary: true) }
        if type.conforms(to: .sourceCode) || ["rs", "tsx", "jsx", "go", "zig", "kt", "kts"].contains(suffix) {
            return Self("code", .indigo, vary: true)
        }
        if type.conforms(to: .threeDContent) { return Self("cube-transparent", .purple, vary: true) }
        if ["epub", "mobi"].contains(suffix) { return Self("book-open-2", .orange) }
        if ["cer", "p12", "pem", "keychain", "pfx"].contains(suffix) { return Self("file-key", .amber, vary: true) }
        if type.conforms(to: .text) { return Self("file-content", .blue, vary: true) }
        if identifier == UTType.data.identifier { return Self("database", .green) }
        return Self("file", .violet, vary: true)
    }
}

final class FileKindCatalog: @unchecked Sendable {
    static let shared = FileKindCatalog()
    private struct Signature: Hashable { let ext: String, finder: UInt32, flags: UInt8 }
    private let lock = NSLock()
    private var byTag: [Signature: UInt32] = [:], byName: [String: UInt32] = [:]
    private static let folder = FileKind(
        id: 0, identifier: "public.folder", title: "Folder", glyph: "folder", tone: .neutral, vary: false)
    private var kinds = [folder]
    private var lightPalette = [dt_glass_tint(folder.light)], darkPalette = [dt_glass_tint(folder.dark)]
    private static let fallbackNames = [
        "parquet": "Apache Parquet", "arrow": "Apache Arrow", "wasm": "WebAssembly module",
        "ndjson": "Newline-delimited JSON", "jsonl": "Newline-delimited JSON", "geojson": "GeoJSON", "avif": "AVIF image",
        "webp": "WebP image", "heic": "HEIF image", "heif": "HEIF image", "db-wal": "SQLite write-ahead log",
        "sqlite": "SQLite database", "sqlite3": "SQLite database", "mlmodelc": "Compiled Core ML model",
        "mlpackage": "Core ML model package",
        "toml": "TOML configuration", "yaml": "YAML", "yml": "YAML", "ts": "TypeScript", "tsx": "TypeScript JSX",
        "rs": "Rust source",
        "pyc": "Python bytecode", "zst": "Zstandard archive", "safetensors": "SafeTensors model", "gguf": "GGUF model",
    ]
    func kind(_ id: UInt32) -> FileKind { lock.withLock { kinds[Int(id)] } }
    func palette(dark: Bool) -> [DTGlassTint] { lock.withLock { dark ? darkPalette : lightPalette } }

    func resolve(path: UnsafePointer<CChar>, ext: String, finder: UInt32, flags: UInt8) -> UInt32 {
        let directory = flags & 1 != 0
        let url = URL(fileURLWithFileSystemRepresentation: path, isDirectory: directory, relativeTo: nil)
        let suffix = ext.lowercased()
        let key = Signature(ext: flags & 32 == 0 ? suffix : url.lastPathComponent, finder: finder, flags: flags)
        if let id = lock.withLock({ byTag[key] }) { return id }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .localizedTypeDescriptionKey, .isPackageKey])
        let declared = suffix.isEmpty ? nil : UTType(filenameExtension: suffix, conformingTo: directory ? .directory : .data)
        var type = values?.contentType ?? declared ?? (directory ? .folder : .data)
        if flags & 2 != 0 {
            type = .symbolicLink
        } else if type.isDynamic || type == .data || type == .directory || type == .folder {
            if let declared, declared.isDeclared { type = declared }
            if !directory && flags & 4 != 0 && (type == .data || type.isDynamic) { type = .unixExecutable }
        }
        if directory
            && !(values?.isPackage == true || flags & 8 != 0 || type.conforms(to: .package) || type.conforms(to: .bundle))
        {
            lock.withLock { byTag[key] = 0 }
            return 0
        }
        if type.conforms(to: .applicationBundle) { type = .applicationBundle }
        let generic = type.isDynamic || type == .data || type == .folder || type == .directory
        let id: String
        let name: String
        if type == .applicationBundle {
            id = type.identifier
            name = type.localizedDescription?.localizedCapitalized ?? "Application"
        } else if generic && !suffix.isEmpty {
            id = (directory ? "package:" : "extension:") + suffix
            let finderName = values?.localizedTypeDescription
            name =
                Self.fallbackNames[suffix] ?? finderName.flatMap {
                    $0.isEmpty || ["document", "data", "folder", "item"].contains($0.lowercased()) ? nil : $0
                }
                ?? (suffix.uppercased() + (directory ? " package" : " document"))
        } else {
            id = type.identifier
            name = type.localizedDescription ?? values?.localizedTypeDescription ?? (directory ? "Package" : "Document")
        }
        let group = name.folding(options: [.caseInsensitive], locale: .current)
        let style = KindStyle.resolve(type, suffix: suffix, identifier: id)
        return lock.withLock {
            if let known = byName[group] {
                byTag[key] = known
                return known
            }
            let value = UInt32(kinds.count)
            let kind = FileKind(
                id: value, identifier: id, title: name, glyph: style.glyph, tone: style.tone, vary: style.vary)
            kinds.append(kind)
            lightPalette.append(dt_glass_tint(kind.light))
            darkPalette.append(dt_glass_tint(kind.dark))
            byName[group] = value
            byTag[key] = value
            return value
        }
    }
}
func resolveFileKind(
    _ path: UnsafePointer<CChar>?, _ suffix: UnsafePointer<UInt8>?, _ length: Int, _ finder: UInt32, _ flags: UInt8
) -> UInt32 {
    guard let path else { return 0 }
    let ext = String(decoding: UnsafeBufferPointer(start: suffix, count: length), as: UTF8.self)
    return FileKindCatalog.shared.resolve(path: path, ext: ext, finder: finder, flags: flags)
}
