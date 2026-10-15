// Makes the development app icon: the official icon with a "DEV" stripe across
// its lower-right corner, so dev and debug builds are easy to tell apart from
// official releases in the Dock and in Finder.
//
//   swift scripts/dev_icon.swift <official.icns> <dev.icns>
//
// The stripe is clipped to the icon's own shape (its alpha), so it never spills
// into the transparent margin around the rounded square.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: dev_icon.swift <official.icns> <dev.icns>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: args[2])

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("papertalk-dev-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func context(_ px: Int) -> CGContext {
    CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func render(_ px: Int) -> CGImage {
    let side = CGFloat(px)
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    var proposed = rect
    let icon = source.cgImage(forProposedRect: &proposed, context: nil,
                              hints: [.ctm: AffineTransform(scale: 1)])!

    // The stripe on its own layer, then masked by the icon's alpha.
    let stripe = context(px)
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
    let clipped = context(px)
    clipped.draw(stripe.makeImage()!, in: rect)
    clipped.setBlendMode(.destinationIn)
    clipped.draw(icon, in: rect)

    let out = context(px)
    out.draw(icon, in: rect)
    out.draw(clipped.makeImage()!, in: rect)
    return out.makeImage()!
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
