// An Ask answer's text (macOS): Markdown rendered in an AppKit text view, citations as icon links.

#if os(macOS)
import AppKit
import SwiftUI

/// An answer's Markdown, selectable, sized to its text. AppKit rather than SwiftUI `Text`: a
/// citation shows as a page icon and its page, and links get the pointing-hand cursor, neither
/// of which `Text` can do. Clicked links go to the environment's `openURL`, like `Text`'s.
struct AnswerText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextView {
        let v = NSTextView(usingTextLayoutManager: false)
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = true
        // SwiftUI sets the frame from `sizeThatFits`; a text view resizing itself fights it.
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.linkTextAttributes = [.foregroundColor: NSColor(Color.appAccent), .cursor: NSCursor.pointingHand]
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        // Only on a new text: resetting it on every update would drop the reader's selection.
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        v.textStorage?.setAttributedString(context.coordinator.attributed(text))
    }

    /// As wide as the longest line (at most the offered width) and as tall as the wrapped text.
    /// Measured on a layout of its own: the view's container still has its old width here (it
    /// tracks the frame), which gave heights for the wrong width and cut answers off.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 10_000
        return context.coordinator.size(of: text, width: width)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Sends clicked links on, and remembers the text shown.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?
        var shown: String?
        private var built: (text: String, string: NSAttributedString)?
        private var measured: (text: String, width: CGFloat, size: CGSize)?

        /// `AnswerText.attributed(text)`, built once per text.
        func attributed(_ text: String) -> NSAttributedString {
            if let built, built.text == text { return built.string }
            let s = AnswerText.attributed(text)
            built = (text, s)
            return s
        }

        /// The text's size wrapped at `width`, laid out as the text view lays it out (TextKit 1,
        /// no padding); remembered for the last text and width.
        func size(of text: String, width: CGFloat) -> CGSize {
            if let measured, measured.text == text, measured.width == width { return measured.size }
            let size = AnswerText.measure(attributed(text), width: width)
            measured = (text, width, size)
            return size
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), let openURL else { return false }
            openURL(url)
            return true
        }
    }

    /// `s` wrapped at `width`: as wide as its longest line and as tall as all its lines.
    static func measure(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        let storage = NSTextStorage(attributedString: s)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }

    /// `text` as the text view shows it: `PaperChat.formatted`'s bold, italics, code and links in
    /// the body font, each citation's page label led by a page icon, both one link.
    static func attributed(_ text: String) -> NSAttributedString {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let md = PaperChat.formatted(text)
        let out = NSMutableAttributedString()
        for run in md.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .font: font(body, intent)]
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link {
                attrs[.link] = url
                if PaperChat.citation(from: url) != nil { out.append(icon(body, link: url)) }
            }
            out.append(NSAttributedString(string: String(md[run.range].characters), attributes: attrs))
        }
        return out
    }

    /// The body font with a run's bold, italics or code.
    private static func font(_ body: NSFont, _ intent: InlinePresentationIntent) -> NSFont {
        let bold = intent.contains(.stronglyEmphasized)
        if intent.contains(.code) { return .monospacedSystemFont(ofSize: body.pointSize * 0.95, weight: bold ? .semibold : .regular) }
        var traits = body.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if intent.contains(.emphasized) { traits.insert(.italic) }
        return NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(traits), size: body.pointSize) ?? body
    }

    /// A page icon in the accent colour, linked to `url`, then a no-break space before the label.
    private static func icon(_ body: NSFont, link url: URL) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: body.pointSize, weight: .medium)
            .applying(.init(paletteColors: [NSColor(Color.appAccent)]))
        guard let image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: (body.capHeight - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height)
        let s = NSMutableAttributedString(attachment: attachment)
        s.append(NSAttributedString(string: "\u{00A0}"))
        s.addAttributes([.link: url, .font: body], range: NSRange(location: 0, length: s.length))
        return s
    }
}
#endif
