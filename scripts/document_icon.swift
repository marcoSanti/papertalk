// Makes the Finder icon of `.papertalk` paper files: a white page with a folded corner, the app
// icon in its middle and "PAPERTALK" in the app's orange along the bottom.
//
//   swift scripts/document_icon.swift <app.icns> <document.icns>
//
// app.sh runs it at build time (into client/.build/icons/), always from the official icon: a
// file's icon shouldn't change between dev and stable builds.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: document_icon.swift <app.icns> <document.icns>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: args[2])

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("papertalk-doc-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

/// The app's accent orange (`Color.appAccent`).
let accent = CGColor(srgbRed: 0xD0 / 255, green: 0x70 / 255, blue: 0x40 / 255, alpha: 1)

func render(_ px: Int) -> CGImage {
    let side = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // The page: the proportions of the system's document icons, origin bottom-left.
    let w = side * 0.70, h = side * 0.88
    let x = (side - w) / 2, y = (side - h) / 2
    let fold = w * 0.26, r = side * 0.03
    let page = CGMutablePath()
    page.move(to: CGPoint(x: x + r, y: y))
    page.addLine(to: CGPoint(x: x + w - r, y: y))
    page.addQuadCurve(to: CGPoint(x: x + w, y: y + r), control: CGPoint(x: x + w, y: y))
    page.addLine(to: CGPoint(x: x + w, y: y + h - fold))
    page.addLine(to: CGPoint(x: x + w - fold, y: y + h))
    page.addLine(to: CGPoint(x: x + r, y: y + h))
    page.addQuadCurve(to: CGPoint(x: x, y: y + h - r), control: CGPoint(x: x, y: y + h))
    page.addLine(to: CGPoint(x: x, y: y + r))
    page.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
    page.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03,
                  color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(page)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(page)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
    ctx.setLineWidth(max(1, side * 0.004))
    ctx.strokePath()

    // The folded corner, shaded so it reads as the back of the page.
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: x + w - fold, y: y + h))
    corner.addLine(to: CGPoint(x: x + w - fold, y: y + h - fold + r))
    corner.addQuadCurve(to: CGPoint(x: x + w - fold + r, y: y + h - fold), control: CGPoint(x: x + w - fold, y: y + h - fold))
    corner.addLine(to: CGPoint(x: x + w, y: y + h - fold))
    corner.closeSubpath()
    ctx.saveGState()
    ctx.addPath(corner)
    ctx.clip()
    let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(gray: 0.97, alpha: 1), CGColor(gray: 0.82, alpha: 1)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: x + w - fold, y: y + h), end: CGPoint(x: x + w - fold / 2, y: y + h - fold / 2), options: [])
    ctx.restoreGState()

    // The app icon, a little above the middle to leave room for the label.
    let iconSide = w * 0.62
    let iconRect = CGRect(x: (side - iconSide) / 2, y: y + h * 0.31, width: iconSide, height: iconSide)
    var proposed = CGRect(origin: .zero, size: iconRect.size)
    if let icon = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
        ctx.draw(icon, in: iconRect)
    }

    // The label is unreadable at tiny sizes; there the page and icon say enough.
    if px >= 64 {
        let font = NSFont.systemFont(ofSize: w * 0.105, weight: .heavy)
        let text = NSAttributedString(string: "PAPERTALK", attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: accent)!, .kern: w * 0.012,
        ])
        let size = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: NSPoint(x: (side - size.width) / 2, y: y + h * 0.12))
        NSGraphicsContext.restoreGraphicsState()
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
