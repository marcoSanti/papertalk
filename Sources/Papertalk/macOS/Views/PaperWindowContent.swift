// What a paper's own window shows.

#if os(macOS)
import SwiftUI

/// The window's content: the live paper from the store, with every card.
struct PaperWindowContent: View {
    @EnvironmentObject private var store: AppStore
    let paperId: String

    var body: some View {
        Group {
            if let paper = store.papers[paperId] {
                DetailView(paper: paper, onEdit: { store.beginEditing(paper) }, inWindow: true)
                    .onAppear { PaperWindow.setTitle(paper.displayTitle, paperId: paperId) }
                    .onChange(of: paper.displayTitle) { _, title in PaperWindow.setTitle(title, paperId: paperId) }
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .tint(Color.appAccent)
        .onChange(of: store.papers[paperId] == nil) { _, gone in
            if gone { PaperWindow.close(paperId: paperId) }
        }
        // Confirmations and the Edit sheet are presented by the library window.
        .onChange(of: store.pendingConfirmation != nil || store.editingPaper != nil) { _, shown in
            if shown { PaperWindow.raiseMainWindow(paperId: paperId) }
        }
    }
}
#endif
