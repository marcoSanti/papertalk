// Drawing PDF pages into images on macOS: covers, slide images and the PDF viewer.

#if os(macOS)
import CoreGraphics

/// A bitmap to draw one page on.
enum PageRaster {
    /// A white `width` × `height` pixel canvas scaled so a page of `size` fills it.
    static func canvas(width w: CGFloat, height h: CGFloat, page size: CGSize) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: w / size.width, y: h / size.height)
        return ctx
    }
}
#endif
