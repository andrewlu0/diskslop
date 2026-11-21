import AppKit
import CoreText
import Metal

// A frame's native glyphs are shaped once, alongside its raster. The display thread only places quads.
final class MapGestureLabels {
    struct Quad {
        let rect: SIMD4<Float>, uv: SIMD4<Float>, ink: SIMD4<Float>
    }
    struct Highlight: Equatable {
        let rect: CGRect, dim: Bool, dark: Bool
        func place(in viewport: CGRect, size: CGSize, scale: CGFloat, quads: inout [Quad]) {
            let canvas = CGRect(origin: .zero, size: size), pixel = 1 / scale
            let sx = size.width / viewport.width, sy = size.height / viewport.height
            let x = ((rect.minX - viewport.minX) * sx * scale).rounded() / scale
            let y = ((rect.minY - viewport.minY) * sy * scale).rounded() / scale
            let right = max(x + pixel, ((rect.maxX - viewport.minX) * sx * scale).rounded() / scale)
            let bottom = max(y + pixel, ((rect.maxY - viewport.minY) * sy * scale).rounded() / scale)
            func band(_ l: CGFloat, _ t: CGFloat, _ r: CGFloat, _ b: CGFloat, _ color: Float, _ alpha: Float) {
                guard l < r, t < b else { return }
                let clipped = canvas.intersection(CGRect(x: l, y: t, width: r-l, height: b-t))
                guard !clipped.isNull, !clipped.isEmpty else { return }
                quads.append(Quad(rect: SIMD4(Float(clipped.minX/size.width), Float(clipped.minY/size.height),
                    Float(clipped.width/size.width), Float(clipped.height/size.height)), uv: .zero, ink: SIMD4(0, 0, color, alpha)))
            }
            if dim {
                let a = Float(selectionDimOpacity)
                band(0, 0, size.width, y, 0, a); band(0, bottom, size.width, size.height, 0, a)
                band(0, y, x, bottom, 0, a); band(right, y, size.width, bottom, 0, a)
            }
            let c: Float = dark ? 0 : 1
            band(x, y, right, y + pixel, c, 0.95); band(x, max(y+pixel,bottom-pixel), right, bottom, c, 0.95)
            band(x, y+pixel, x+pixel, bottom-pixel, c, 0.95); band(max(x+pixel,right-pixel), y+pixel, right, bottom-pixel, c, 0.95)
        }
    }
    private struct Line {
        let row: Int, width: CGFloat
    }
    private struct Entry {
        let rect: CGRect, light: Bool, title: Line, size: Line
    }
    let texture: MTLTexture
    private let entries: [Entry], ellipsis: [Line]
    private let rowHeight: CGFloat = 21, scale: CGFloat = 2

    init?(labels: [FileLabel], device: MTLDevice) {
        guard !labels.isEmpty else { return nil }
        let fonts = [NSFont.systemFont(ofSize: 16, weight: .semibold), NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
        var lines = [(CTLine, CGFloat)](), maxWidth: CGFloat = 1
        func shape(_ text: String, font: NSFont) -> Line {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor.white]
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            if CTLineGetTypographicBounds(line, nil, nil, nil) > 768,
               let shortened = CTLineCreateTruncatedLine(line, 768, .middle, lines.first?.0) { line = shortened }
            let width = ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 1
            let result = Line(row: lines.count, width: width)
            lines.append((line, font.ascender)); maxWidth = max(maxWidth, width)
            return result
        }
        ellipsis = fonts.map { shape("…", font: $0) }
        entries = labels.map { Entry(rect: $0.rect, light: $0.lightInk, title: shape($0.title, font: fonts[0]), size: shape($0.size, font: fonts[1])) }
        let width = Int(ceil(maxWidth * scale)), height = Int(rowHeight * scale) * lines.count
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue), let pixels = context.data else { return nil }
        context.scaleBy(x: scale, y: scale)
        for (i, value) in lines.enumerated() {
            context.textPosition = CGPoint(x: 0, y: CGFloat(height) / scale - CGFloat(i) * rowHeight - value.1)
            CTLineDraw(value.0, context)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let atlas = device.makeTexture(descriptor: descriptor) else { return nil }
        atlas.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: context.bytesPerRow)
        texture = atlas
    }

    func place(in viewport: CGRect, size: CGSize, quads: inout [Quad]) {
        let canvas = CGRect(origin: .zero, size: size)
        let sx = size.width / viewport.width, sy = size.height / viewport.height
        let u = scale / CGFloat(texture.width), v = rowHeight * scale / CGFloat(texture.height)
        for entry in entries {
            let tile = CGRect(x: (entry.rect.minX - viewport.minX) * sx, y: (entry.rect.minY - viewport.minY) * sy,
                width: entry.rect.width * sx, height: entry.rect.height * sy).intersection(canvas)
            guard tile.width >= 44, tile.height >= 21, !tile.isNull else { continue }
            let large = tile.width >= 150 && tile.height >= 74, inset: CGFloat = large ? 9 : 4
            func append(_ line: Line, _ kind: Int, _ top: CGFloat, _ ratio: CGFloat) {
                let width = min(line.width * ratio, tile.width - inset * 2)
                let box = SIMD4<Float>(Float((tile.minX + inset) / size.width), Float(top / size.height),
                    Float(width / size.width), Float(rowHeight * ratio / size.height))
                let uv = SIMD4<Float>(Float(width / ratio * u), Float(CGFloat(line.row) * v), Float(line.width * u), Float(v))
                let ink = SIMD4<Float>(Float(ellipsis[kind].width * u), Float(CGFloat(ellipsis[kind].row) * v), entry.light ? 1 : 0, 0)
                quads.append(Quad(rect: box, uv: uv, ink: ink))
            }
            append(entry.title, 0, tile.minY + inset, large ? 1 : 11/16)
            if tile.height > 39 { append(entry.size, 1, tile.minY + inset + (large ? 22 : 15), large ? 1 : 10/12) }
        }
    }
}
