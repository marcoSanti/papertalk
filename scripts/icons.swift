// Makes every macOS icon of the app.
//
//   swift scripts/icons.swift app shared/icon.icns
//   swift scripts/icons.swift dev <official.icns> <dev.icns>
//   swift scripts/icons.swift document <official.icns> <document.icns>
//
// app: the official icon (a speaker at a lectern, with sound waves, on the app's orange). Its
// output is committed as shared/icon.icns, which every other icon is generated from.
// dev: the official icon with a "DEV" stripe, so dev and debug builds are easy to tell apart.
// document: the Finder icon of `.papertalk` files, always made from the official icon: a file's
// icon shouldn't change between dev and stable builds. app.sh runs dev and document at build time.
import AppKit

/// An sRGB colour from 0–255 components.
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

/// An empty `px` × `px` bitmap.
func canvas(_ px: Int) -> CGContext {
    CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// The official icon. Drawn as vectors at each size (not downscaled), on the macOS grid: an 824 pt
/// rounded square centred on a 1024 pt canvas. Shapes are filled and thick so it reads at 16 px.
enum AppIcon {
    static let white = rgb(255, 255, 255), cream = rgb(0xFD, 0xEF, 0xE6)
    /// The app's accent (`Color.appAccent`), and the lighter and deeper ends of the tile's gradient.
    static let orange = rgb(0xD0, 0x70, 0x40), light = rgb(0xE8, 0x8A, 0x55), deep = rgb(0xA8, 0x50, 0x28)
    static let shade = rgb(80, 30, 10, 0.35)


    /// The icon at `px` × `px` pixels.
    static func render(_ px: Int) -> CGImage {
        let ctx = canvas(px)
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
}

/// The official icon with a stripe across its lower-right corner, clipped to the icon's own
/// shape (its alpha), so it never spills into the transparent margin.
enum DevIcon {
    static func render(_ px: Int, over source: NSImage) -> CGImage {
        let side = CGFloat(px)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        var proposed = rect
        let icon = source.cgImage(forProposedRect: &proposed, context: nil,
                                  hints: [.ctm: AffineTransform(scale: 1)])!

        // The stripe on its own layer, then masked by the icon's alpha.
        let stripe = canvas(px)
        stripe.translateBy(x: side * 0.70, y: side * 0.30)
        stripe.rotate(by: .pi / 4)
        let band = side * 0.16
        stripe.setFillColor(CGColor(srgbRed: 1.0, green: 0.78, blue: 0.16, alpha: 1))
        stripe.fill(CGRect(x: -side, y: -band / 2, width: side * 2, height: band))
        // Thin dark edges keep the band readable on light and dark parts of the icon.
        stripe.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        let edge = max(1, side * 0.008)
        stripe.fill(CGRect(x: -side, y: band / 2 - edge, width: side * 2, height: edge))
        stripe.fill(CGRect(x: -side, y: -band / 2, width: side * 2, height: edge))
        // The label is unreadable at tiny sizes; there the colour alone says "dev".
        if px >= 64 {
            let font = NSFont.systemFont(ofSize: band * 0.62, weight: .black)
            let text = NSAttributedString(string: "DEV", attributes: [
                .font: font,
                .foregroundColor: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1),
                .kern: band * 0.08,
            ])
            let size = text.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: stripe, flipped: false)
            text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2 + font.descender * 0.25))
            NSGraphicsContext.restoreGraphicsState()
        }
        // Keep the stripe only where the icon itself is opaque.
        let clipped = canvas(px)
        clipped.draw(stripe.makeImage()!, in: rect)
        clipped.setBlendMode(.destinationIn)
        clipped.draw(icon, in: rect)

        let out = canvas(px)
        out.draw(icon, in: rect)
        out.draw(clipped.makeImage()!, in: rect)
        return out.makeImage()!
    }
}

/// A white page with a folded corner, the app icon in its middle and "PAPERTALK" along the bottom.
enum DocumentIcon {
    /// The app's accent orange (`Color.appAccent`).
    static let accent = CGColor(srgbRed: 0xD0 / 255, green: 0x70 / 255, blue: 0x40 / 255, alpha: 1)

    static func render(_ px: Int, around source: NSImage) -> CGImage {
        let side = CGFloat(px)
        let ctx = canvas(px)
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
}

/// Write every size `render` draws into the .icns at `output`; iconutil's exit status.
func writeIcns(to output: URL, render: (Int) -> CGImage) throws -> Int32 {
    let iconset = FileManager.default.temporaryDirectory
        .appendingPathComponent("papertalk-icon-\(ProcessInfo.processInfo.processIdentifier).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }
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
    return iconutil.terminationStatus
}

let args = CommandLine.arguments
let render: (Int) -> CGImage
switch (args.dropFirst().first, args.count) {
case ("app", 3):
    render = AppIcon.render
case ("dev", 4) where NSImage(contentsOfFile: args[2]) != nil:
    let source = NSImage(contentsOfFile: args[2])!
    render = { DevIcon.render($0, over: source) }
case ("document", 4) where NSImage(contentsOfFile: args[2]) != nil:
    let source = NSImage(contentsOfFile: args[2])!
    render = { DocumentIcon.render($0, around: source) }
default:
    FileHandle.standardError.write("usage: icons.swift app <out.icns> | dev|document <official.icns> <out.icns>\n".data(using: .utf8)!)
    exit(2)
}
exit(try writeIcns(to: URL(fileURLWithPath: args[args.count - 1]), render: render))
