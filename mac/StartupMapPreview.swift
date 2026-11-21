import AppKit
import ImageIO
import UniformTypeIdentifiers

final class StartupMapPreview: NSImageView {
    struct Style: Equatable {
        let radial: Bool
        let color: MapColorMode
        let dark: Bool
        let shine: Bool

        func file(in snapshot: StartupSnapshot) -> URL {
            let chart = radial ? "sunburst" : "treemap"
            let appearance = dark ? "dark" : "light"
            let finish = shine ? "glass" : "flat"
            return snapshot.file.deletingLastPathComponent().appendingPathComponent(
                "map-v1-\(snapshot.journal.uuidString)-\(snapshot.identity.inode)-\(chart)-\(color.rawValue)-\(appearance)-\(finish).png")
        }
    }

    private static let maximumDimension = 720
    private static let writeQueue = DispatchQueue(label: "local.diskslop.map-preview", qos: .utility)

    func present(_ image: CGImage?, style: Style? = nil) {
        if let image {
            imageScaling = style?.radial == true ? .scaleProportionallyUpOrDown : .scaleAxesIndependently
            self.image = NSImage(cgImage: image, size: .zero)
        } else {
            self.image = nil
        }
        isHidden = image == nil
    }

    static func read(_ snapshot: StartupSnapshot, style: Style) -> CGImage? {
        guard snapshot.fileInode != 0,
              let source = CGImageSourceCreateWithURL(style.file(in: snapshot) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumDimension).contains(width), (1...maximumDimension).contains(height)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func save(_ image: CGImage, to snapshot: StartupSnapshot, style: Style) {
        writeQueue.async {
            do {
                try FileManager.default.createDirectory(at: snapshot.file.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch { return }
            let ratio = min(1, CGFloat(maximumDimension) / CGFloat(max(image.width, image.height)))
            let width = max(1, Int(CGFloat(image.width) * ratio))
            let height = max(1, Int(CGFloat(image.height) * ratio))
            guard let context = ChartRenderer.bitmap(width: width, height: height) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let thumbnail = context.makeImage() else { return }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            if CGImageDestinationFinalize(destination) { try? data.write(to: style.file(in: snapshot), options: .atomic) }
        }
    }
}
