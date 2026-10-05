import AppKit

// Matches the colors and four-square geometry of HomeGrid web's icon.svg.
// The transparent inset gives the artwork room alongside other macOS app icons.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Scripts/GenerateAppIcon.swift <output.iconset>")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let background = CGColor(colorSpace: colorSpace, components: [CGFloat(23) / 255, CGFloat(34) / 255, CGFloat(42) / 255, 1])!
let foreground = CGColor(colorSpace: colorSpace, components: [CGFloat(168) / 255, CGFloat(211) / 255, CGFloat(215) / 255, 1])!

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let drawing = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: pixels * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not render app icon at \(pixels) pixels")
        }
        drawing.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        drawing.translateBy(x: CGFloat(pixels) * 6 / 64, y: CGFloat(pixels) * 6 / 64)
        drawing.scaleBy(x: CGFloat(pixels) * 52 / (64 * 64), y: CGFloat(pixels) * 52 / (64 * 64))
        drawing.setFillColor(background)
        drawing.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 64, height: 64),
                               cornerWidth: 16, cornerHeight: 16, transform: nil))
        drawing.fillPath()
        drawing.setFillColor(foreground)
        for x in [14, 35] {
            for y in [14, 35] {
                drawing.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 15, height: 15),
                                       cornerWidth: 3, cornerHeight: 3, transform: nil))
                drawing.fillPath()
            }
        }
        guard let image = drawing.makeImage() else {
            fatalError("Could not create app icon at \(pixels) pixels")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode app icon at \(pixels) pixels")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"), options: .atomic)
    }
}
