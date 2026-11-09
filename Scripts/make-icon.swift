// Draws Driftcast's app icon and writes every size the asset catalog needs.
//   swift Scripts/make-icon.swift Driftcast/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func draw(_ px: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Design units: a 512-point canvas with the origin at the top left.
    let s = CGFloat(px) / 512
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)

    // Rounded tile with a pink gradient running from the top left to the bottom right.
    let tile = CGRect(x: 52, y: 52, width: 408, height: 408)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 92, cornerHeight: 92, transform: nil))
    ctx.clip()
    let colors = [CGColor(srgbRed: 1.00, green: 0.56, blue: 0.76, alpha: 1),
                  CGColor(srgbRed: 0.98, green: 0.33, blue: 0.62, alpha: 1),
                  CGColor(srgbRed: 0.90, green: 0.18, blue: 0.53, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    ctx.restoreGState()

    // Cast waves: three quarter circles around the dot, fading outwards.
    let center = CGPoint(x: 141, y: 371)
    ctx.setLineWidth(23)
    ctx.setLineCap(.round)
    for (radius, alpha) in [(92.0, 1.0), (158.0, 0.82), (223.0, 0.58)] {
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
        ctx.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - 25, y: center.y - 25, width: 50, height: 50))

    // Play triangle.
    ctx.move(to: CGPoint(x: 340, y: 100))
    ctx.addLine(to: CGPoint(x: 340, y: 190))
    ctx.addLine(to: CGPoint(x: 412, y: 145))
    ctx.closePath()
    ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! draw(px).write(to: outDir.appendingPathComponent(name + ".png"))
}
print("wrote icons to", outDir.path)
