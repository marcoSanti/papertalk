// Linux stand-ins for the AppKit pieces the shared code uses: images, opening and revealing
// files, and desktop notifications.

#if os(Linux)
import Foundation

// The few AppKit pieces the shared code uses, with the same names and
// signatures, so AppStore compiles unchanged on Linux (AGENTS.md, "Linux port").

/// A cover image, kept as PNG bytes (rendered by python/papertalk_platform/pdf.py).
/// Stands in for NSImage in AppStore's thumbnail cache; the GTK UI decodes it.
final class NSImage {
    /// The image as PNG bytes.
    let png: Data
    init(png: Data) { self.png = png }
}

/// Opening links and revealing files, through the desktop's own handlers.
final class NSWorkspace {
    /// Like AppKit's, the one workspace.
    static let shared = NSWorkspace()

    /// Open a link or file with the desktop's default handler.
    @discardableResult
    func open(_ url: URL) -> Bool {
        LinuxDesktop.launch("xdg-open", [url.isFileURL ? url.path : url.absoluteString])
    }

    /// Shows the files in the file manager (FileManager1 D-Bus interface, which
    /// Nautilus, Dolphin, Nemo and Thunar implement), else opens their folder.
    func activateFileViewerSelecting(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let items = urls.map { "'\($0.absoluteString)'" }.joined(separator: ",")
        let revealed = LinuxDesktop.launch("gdbus", [
            "call", "--session", "--dest", "org.freedesktop.FileManager1",
            "--object-path", "/org/freedesktop/FileManager1",
            "--method", "org.freedesktop.FileManager1.ShowItems", "[\(items)]", "",
        ], wait: true)
        if !revealed { open(urls[0].deletingLastPathComponent()) }
    }
}

extension URL {
    // macOS sandbox access for files picked in a panel; there's no sandbox here.
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}

/// Desktop notifications through `notify-send` (libnotify), for the same events
/// as the macOS Notifier. Posted only while the window isn't focused; the GTK UI
/// sets `isAppActive`.
@MainActor
final class Notifier {
    /// Opening a notification's paper (unused: notify-send has no click callback here).
    var onOpen: ((String) -> Void)?
    /// Whether the window has focus; until the GTK UI wires it, nothing is posted.
    var isAppActive: () -> Bool = { true }

    /// Nothing to ask for on Linux.
    func requestPermissionIfNeeded() {}

    /// What a notification says, as on macOS.
    enum Event {
        case ready, failed(String), needsInput(String)
    }

    /// Post through notify-send while the app is in the background.
    func post(_ event: Event, paperId: String, title: String) {
        guard !isAppActive() else { return }
        let (summary, body, urgency): (String, String, String) = {
            switch event {
            case .ready: return (L("Episode ready"), title, "normal")
            case .failed(let reason): return (L("Conversion failed"), "\(title): \(reason)", "normal")
            case .needsInput(let question): return (question, title, "critical")
            }
        }()
        LinuxDesktop.launch("notify-send", ["--app-name=Papertalk", "--urgency=\(urgency)", summary, body])
    }

    /// notify-send can't withdraw a notification.
    func clearInputRequest(paperId: String) {}
}

/// Running the desktop's command-line helpers.
enum LinuxDesktop {
    /// Runs a desktop helper found on PATH. Returns whether it started (or, with
    /// `wait`, exited successfully). Missing helpers are not an error.
    @discardableResult
    static func launch(_ tool: String, _ arguments: [String], wait: Bool = false) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        guard wait else { return true }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
#endif
