// The open and save panels for `.papertalk` paper bundles and the library folder, and the hook
// that hands files opened from Finder to the store.

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// A `.papertalk` paper bundle (declared in Info.plist).
    static let papertalkPaper = UTType(exportedAs: PaperBundle.typeIdentifier, conformingTo: .package)
}

/// Panels that pick where papers and the library go.
@MainActor
enum PaperPanels {
    /// Pick `.papertalk` files and import them.
    static func importPapers(into store: AppStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.papertalkPaper]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        store.openFiles(panel.urls)
    }

    /// Ask whether `paper`'s PDF goes along (with the copyright warning; the default leaves it
    /// out), then where to save the bundle, and export it there.
    static func exportPaper(_ paper: Paper, from store: AppStore) {
        var include = false
        if paper.hasPdf {
            let question = PaperPresentation.exportPDFQuestion
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = question.title
            alert.informativeText = question.message
            alert.addButton(withTitle: question.withoutPDF)
            alert.addButton(withTitle: question.withPDF)
            alert.addButton(withTitle: question.cancel)
            switch alert.runModal() {
            case .alertFirstButtonReturn: include = false
            case .alertSecondButtonReturn: include = true
            default: return
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.papertalkPaper]
        panel.nameFieldStringValue = PaperPresentation.bundleFileName(paper)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.exportPaper(paper.id, to: url, includePDF: include) }
    }

    /// Ask where to save the episode, then export it there.
    static func exportAudio(_ paper: Paper, from store: AppStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = EpisodeExport.fileName(paper)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.exportAudio(paper.id, to: url) }
    }

    /// Open the stored PDF in its own window.
    static func openPDF(_ paper: Paper, from store: AppStore) {
        guard paper.hasPdf else { return }
        Task {
            if let data = await store.pdfData(for: paper.id) {
                PDFViewerWindow.present(data: data, title: paper.displayTitle)
            }
        }
    }

    /// Pick a folder for the library and move it there.
    static func chooseLibraryFolder(for store: AppStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Use This Folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setLibraryFolder(url)
    }
}

/// Receives files opened from Finder (a double-clicked `.papertalk`), holding them until the
/// window has set `onOpen`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the window once the store exists; pending files are delivered then.
    var onOpen: (([URL]) -> Void)? {
        didSet { if let onOpen, !pending.isEmpty { onOpen(pending); pending = [] } }
    }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpen { onOpen(urls) } else { pending += urls }
    }
}
#endif
