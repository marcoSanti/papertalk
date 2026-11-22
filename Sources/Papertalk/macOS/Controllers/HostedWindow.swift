// What every window the app opens by itself has in common.

#if os(macOS)
import AppKit

/// Windows owned by their controllers.
@MainActor
enum HostedWindow {
    /// A window its controller keeps (and hears closing, as its delegate).
    static func make(width: CGFloat, height: CGFloat, minSize: NSSize, delegate: NSWindowDelegate,
                     style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // the controller owns it
        window.minSize = minSize
        window.delegate = delegate
        return window
    }

    /// A window for one of the maps.
    static func makeMap(delegate: NSWindowDelegate, minimizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .resizable]
        if minimizable { style.insert(.miniaturizable) }
        return make(width: 1080, height: 720, minSize: NSSize(width: 760, height: 480), delegate: delegate, style: style)
    }
}

/// The open windows of a kind that has one per paper.
@MainActor
final class WindowRegistry<Controller: PerPaperWindow> {
    private var open: [String: Controller] = [:]

    subscript(_ paperId: String) -> Controller? {
        get { open[paperId] }
        set { open[paperId] = newValue }
    }

    /// Bring the paper's window forward, or make, fill and show a new one.
    func present(_ paperId: String, make: () -> Controller, content: () -> NSView) {
        if let existing = open[paperId] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = make()
        open[paperId] = controller
        controller.window.contentView = content()
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
    }
}

/// A controller with one window per paper.
@MainActor
protocol PerPaperWindow: AnyObject {
    var window: NSWindow! { get }
    static var open: WindowRegistry<Self> { get }
}

extension PerPaperWindow {
    /// Close the paper's window, if it's open.
    static func close(paperId: String) { open[paperId]?.window.close() }

    /// Set the window's title (it follows the paper's, which can be edited).
    static func setTitle(_ title: String, paperId: String) { open[paperId]?.window.title = title }
}
#endif
