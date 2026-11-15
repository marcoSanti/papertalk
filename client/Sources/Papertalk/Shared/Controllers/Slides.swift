// Slide decks: each slide's text and, for slides that are mostly pictures, a description the
// LLM writes from the slide's image, so every later step (metadata, script, mind map, Ask)
// reads the deck as text like a paper.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AppKit)
import AppKit
#endif

extension LocalPipeline {
    /// A slide with less text than this (characters) is described from its image as well.
    static let slideTextMinimum = 300
    /// Width of the slide image sent to the LLM, in pixels: enough to read charts and labels.
    static let slideImageWidth = 1024

    /// Whether a slide's own text is too short to carry it.
    static func needsDescription(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count < slideTextMinimum
    }

    /// One slide as the later steps read it: its number, its text, then what its pictures show.
    static func slidePage(_ number: Int, text: String, description: String?) -> String {
        var out = "Slide \(number)\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            out += "\n[What the slide shows: \(d)]"
        }
        return out
    }

    /// The whole deck as the source text, after the editable note (`PromptSettings.slidesSource`)
    /// that makes the prompts written for papers read it as slides.
    static func slidesText(_ pages: [String], note: String) -> String {
        guard !pages.isEmpty else { return "" }
        return note.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + pages.joined(separator: "\n\n")
    }

    /// Each slide's text, with descriptions of the slides that are mostly pictures. When the
    /// first description fails (most often a model that can't read images), the rest of the
    /// deck keeps its text only rather than failing slide after slide.
    func slidePages(_ pdf: Data) async -> [String] {
        let texts = Self.extractPages(pdf)
        var describe = true
        var out: [String] = []
        for (i, text) in texts.enumerated() {
            if Task.isCancelled { break }
            var description: String?
            if describe, Self.needsDescription(text), let png = Self.slidePNG(pdf, index: i) {
                onProgress(Double(i) / Double(texts.count), L("Describing slide {0} of {1}…", i + 1, texts.count))
                do {
                    description = try await describeSlide(png: png, text: text)
                } catch {
                    log("WARN: could not describe slide \(i + 1) (\(error.localizedDescription)); "
                        + "the model may not read images, so the rest of the deck uses its text only")
                    describe = false
                }
            }
            out.append(Self.slidePage(i + 1, text: text, description: description))
        }
        return out
    }

    /// What one slide shows, from its image (PNG) and its extracted text.
    func describeSlide(png: Data, text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let user: [[String: Any]] = [
            ["type": "text", "text": trimmed.isEmpty ? "The slide has no extractable text." : "Extracted text:\n" + trimmed],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]],
        ]
        return try await chat(messages: [["role": "system", "content": prompts.slideDescription],
                                         ["role": "user", "content": user]], maxTokens: 400)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Slide `index` of `pdf` as a PNG, `width` pixels wide; nil when it can't be drawn.
    static func slidePNG(_ pdf: Data, index: Int, width: Int = slideImageWidth) -> Data? {
        #if os(Linux)
        // shortcut: slide decks are macOS-only for now, so Linux sends no images (text only).
        return nil
        #else
        guard let page = PDFDocument(data: pdf)?.page(at: index), let image = renderPage(page, pixelWidth: width) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #endif
    }

    #if !os(Linux)
    /// A PDF page drawn on white, `pixelWidth` pixels wide (covers and slide images).
    static func renderPage(_ page: PDFPage, pixelWidth: Int) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, pixelWidth > 0 else { return nil }
        let w = pixelWidth, h = Int(CGFloat(pixelWidth) * bounds.height / bounds.width)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / bounds.width, y: CGFloat(h) / bounds.height)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
    #endif
}
