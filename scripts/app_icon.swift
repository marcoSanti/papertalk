// Draws the official app icon (a speaker at a lectern, with sound waves, on the app's orange)
// and writes every size into an .icns. Its output is committed as shared/icon.icns, which
// the dev, document, Help Book and Linux icons are all generated from.
//
//   swift scripts/app_icon.swift shared/icon.icns
//
// Drawn as vectors at each size (not downscaled), on the macOS grid: an 824 pt rounded
// square centred on a 1024 pt canvas. Shapes are filled and thick so it reads at 16 px.
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: app_icon.swift <out.icns>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: args[1])

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("papertalk-icon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

/// An sRGB colour from 0–255 components.
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let white = rgb(255, 255, 255), cream = rgb(0xFD, 0xEF, 0xE6)
/// The app's accent (`Color.appAccent`), and the lighter and deeper ends of the tile's gradient.
let orange = rgb(0xD0, 0x70, 0x40), light = rgb(0xE8, 0x8A, 0x55), deep = rgb(0xA8, 0x50, 0x28)
let shade = rgb(80, 30, 10, 0.35)

/// The icon at `px` × `px` pixels.
func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Lay out in 1024 pt, top-down. Shadows don't follow the transform, so they scale by hand.
    let k = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: k, y: -k)
    func shadow(y: CGFloat, blur: CGFloat, _ color: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -y * k), blur: blur * k, color: color)
    }

    // The tile: a soft drop shadow, then the orange gradient, light at the top.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    shadow(y: 12, blur: 28, rgb(0, 0, 0, 0.3))
    ctx.addPath(tile); ctx.setFillColor(orange); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [light, deep] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    ctx.translateBy(x: 45, y: 0)   // the speaker and waves, centred as a group

    // Shoulders: a dome, cut flat where the lectern covers it.
    let bust = CGMutablePath()
    bust.move(to: CGPoint(x: 255, y: 640))
    bust.addLine(to: CGPoint(x: 255, y: 560))
    bust.addCurve(to: CGPoint(x: 400, y: 448), control1: CGPoint(x: 255, y: 490), control2: CGPoint(x: 320, y: 448))
    bust.addCurve(to: CGPoint(x: 545, y: 560), control1: CGPoint(x: 480, y: 448), control2: CGPoint(x: 545, y: 490))
    bust.addLine(to: CGPoint(x: 545, y: 640))
    bust.closeSubpath()
    ctx.addPath(bust); ctx.setFillColor(white); ctx.fillPath()
    // The head, with a clear gap above the shoulders so the two stay apart when small.
    ctx.fillEllipse(in: CGRect(x: 312, y: 240, width: 176, height: 176))

    // The lectern: a tapered stand under a rounded ledge, with a panel line.
    let stand = CGMutablePath()
    stand.move(to: CGPoint(x: 250, y: 630))
    stand.addLine(to: CGPoint(x: 550, y: 630))
    stand.addLine(to: CGPoint(x: 522, y: 790))
    stand.addArc(tangent1End: CGPoint(x: 518, y: 812), tangent2End: CGPoint(x: 490, y: 812), radius: 24)
    stand.addLine(to: CGPoint(x: 310, y: 812))
    stand.addArc(tangent1End: CGPoint(x: 282, y: 812), tangent2End: CGPoint(x: 278, y: 790), radius: 24)
    stand.closeSubpath()
    ctx.saveGState()
    shadow(y: 10, blur: 22, shade)
    ctx.addPath(stand); ctx.setFillColor(cream); ctx.fillPath()
    let ledge = CGPath(roundedRect: CGRect(x: 212, y: 588, width: 376, height: 56),
                       cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.addPath(ledge); ctx.setFillColor(white); ctx.fillPath()
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0xD0, 0x70, 0x40, 0.5)); ctx.setLineWidth(22); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 335, y: 712)); ctx.addLine(to: CGPoint(x: 465, y: 712))
    ctx.strokePath()

    // Three waves from the mouth, evenly spaced, fading outwards.
    ctx.setLineWidth(40)
    for (i, r) in [150.0, 222.0, 294.0].enumerated() {
        ctx.setStrokeColor(rgb(255, 255, 255, 1 - CGFloat(i) * 0.22))
        ctx.addArc(center: CGPoint(x: 400, y: 328), radius: r, startAngle: -.pi * 0.2, endAngle: .pi * 0.2, clockwise: false)
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(points * scale))
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
