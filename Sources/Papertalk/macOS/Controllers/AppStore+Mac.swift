// AppStore methods only the macOS interface needs.

#if os(macOS)
import AppKit
import Foundation

extension AppStore {
    /// Show the library's folder in Finder.
    func revealLibraryFolder() { NSWorkspace.shared.activateFileViewerSelecting([libraryFolder]) }

    /// Where a citation's quote is in the paper; its page without highlights when it isn't found.
    nonisolated static func locate(_ c: PaperChat.Citation, in pdf: Data) async -> (page: Int, rects: [CGRect]) {
        await Task.detached { PDFSource.find(c, in: pdf) }.value ?? (c.page, [])
    }
}
#endif
