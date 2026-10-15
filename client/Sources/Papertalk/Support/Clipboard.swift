#if os(macOS)
import AppKit

/// Copying text to the system clipboard, in one place.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#endif
