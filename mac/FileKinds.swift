import AppKit
import UniformTypeIdentifiers

struct KindTone: Equatable {
    let light: UInt32, dark: UInt32
    init(_ light: UInt32, _ dark: UInt32) { self.light = light; self.dark = dark }

    // sRGB equivalents of the 600 tones and the dark appearance's 300/400 OKLCH midpoint.
    static let blue = Self(0x2f5ff5, 0x83a9ff), violet = Self(0x7f22fe, 0xb59cff)
    static let green = Self(0x00a63e, 0x53e88e), cyan = Self(0x0092b8, 0x16dff7)
    static let amber = Self(0xe17100, 0xffc600), orange = Self(0xf54a00, 0xffa244)
    static let pink = Self(0xe60076, 0xfd86c7), rose = Self(0xec003f, 0xff8496)
    static let teal = Self(0x009689, 0x11e1c9), indigo = Self(0x4f39f6, 0x8e9dff)
    static let lime = Self(0x5ea500, 0xabed27), sky = Self(0x0084d1, 0x49c8ff)
    static let purple = Self(0x9810fa, 0xce97ff), red = Self(0xe7000b, 0xff8485)
    static let fuchsia = Self(0xc800de, 0xf18bff), yellow = Self(0xd08700, 0xffd400)
    static let emerald = Self(0x009966, 0x33dfa3), neutral = Self(0x45556c, 0xacbbce)
    private static let spectrum: [Self] = [.red, .orange, .amber, .yellow, .lime, .green, .emerald, .teal, .cyan,
        .sky, .blue, .indigo, .violet, .purple, .fuchsia, .pink, .rose]

    private static func mix(_ a: UInt32, _ b: UInt32, _ fraction: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 255)
            let y = Double((b >> shift) & 255)
            return UInt32((x + (y - x) * fraction).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
    func variation(for identifier: String, acrossSpectrum: Bool) -> Self {
        let hash = identifier.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        let tones = Self.spectrum
        let index = acrossSpectrum ? Int(hash) % tones.count : tones.firstIndex(of: self) ?? 0
        let direction = hash & 256 == 0 ? 1 : -1
        let a = tones[index], b = tones[(index + tones.count + direction) % tones.count]
        let fraction = Double((hash >> 16) & 255) / 255 * (acrossSpectrum ? 1 : 0.65)
        return Self(Self.mix(a.light, b.light, fraction), Self.mix(a.dark, b.dark, fraction))
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
    let tone: KindTone

    init(id: UInt32, identifier: String, title: String, glyph: String, tone: KindTone, vary: Bool) {
        self.id = id
        self.identifier = identifier
        self.title = title
        self.glyph = glyph
        self.tone = vary ? tone.variation(for: identifier, acrossSpectrum: glyph == "file") : tone
    }
    func fill(darkMode: Bool) -> UInt32 { darkMode ? tone.dark : tone.light }
}
struct KindUsage {
    let kind: FileKind, bytes: UInt64, files: UInt64
    let formattedSize: String, formattedFiles: String

    init(kind: FileKind, bytes: UInt64, files: UInt64) {
        self.kind = kind; self.bytes = bytes; self.files = files
        formattedSize = formatBytes(bytes)
        formattedFiles = formatCount(files)
    }
}

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
        if type.conforms(to: .applicationBundle) || id == "com.apple.application" { return Self("applications", .red) }
        if type.conforms(to: .applicationExtension) || id.contains("plug-in") || suffix == "plugin" {
            return Self("plug-2", .orange, vary: true)
        }
        if type.conforms(to: .framework) { return Self("cubes", .indigo) }
        if ["mlmodelc", "mlpackage", "safetensors", "gguf"].contains(suffix) || id.contains("coreml")
            || id.contains("core-ml")
        {
            return Self("brain-nodes", .teal)
        }
        if suffix == "xcarchive" || id.contains("xcode.archive") { return Self("code-editor", .blue) }
        if type.conforms(to: .diskImage) || ["dmg", "iso", "sparseimage", "sparsebundle"].contains(suffix) {
            return Self("hard-drive", .rose)
        }
        if ["pkg", "mpkg"].contains(suffix) || id.contains("installer-package") { return Self("box-archive-2", .orange, vary: true) }
        if type.conforms(to: .package) || type.conforms(to: .bundle) { return Self("box-archive-2", .violet, vary: true) }
        if type.conforms(to: .symbolicLink) || type.conforms(to: .aliasFile) { return Self("file-link", .emerald, vary: true) }
        if type.conforms(to: .pdf) { return Self("report-file", .sky) }
        if type.conforms(to: .json) || ["json", "jsonl", "ndjson", "geojson"].contains(suffix) {
            return Self("brackets-curly", .cyan, vary: type != .json)
        }
        if type.conforms(to: .rawImage) { return Self("camera", .pink, vary: true) }
        if type.conforms(to: .png) { return Self("file-image", .amber) }
        if type.conforms(to: .jpeg) { return Self("image", .green) }
        if suffix == "svg" || id.contains("vector") { return Self("color-palette", .pink) }
        if suffix == "gif" { return Self("file-gif", .fuchsia) }
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
        if suffix == "dylib" || id.contains("dynamic-library") { return Self("cubes", .sky, vary: true) }
        if suffix == "o" || id.contains("object-code") { return Self("cube", .purple) }
        if ["pyc", "wasm", "class", "bc", "air", "metallib", "a", "so"].contains(suffix) {
            return Self("microchip", .indigo, vary: true)
        }
        if type.conforms(to: .unixExecutable) || type.conforms(to: .executable) { return Self("terminal", .yellow) }
        if suffix == "md" || suffix == "markdown" || id.contains("markdown") { return Self("markdown", .indigo) }
        if type.conforms(to: .html) { return Self("window-code", .orange) }
        if suffix == "js" || suffix == "mjs" || suffix == "cjs" { return Self("square-code", .yellow, vary: true) }
        if suffix == "py" { return Self("terminal", .blue) }
        if suffix == "sql" { return Self("database", .cyan, vary: true) }
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
        if identifier == UTType.data.identifier { return Self("database", .lime) }
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
    private var lightPalette = [dt_glass_tint(folder.tone.light)], darkPalette = [dt_glass_tint(folder.tone.dark)]
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
            lightPalette.append(dt_glass_tint(kind.tone.light))
            darkPalette.append(dt_glass_tint(kind.tone.dark))
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
