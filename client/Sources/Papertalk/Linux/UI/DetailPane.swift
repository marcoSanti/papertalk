#if os(Linux)
import Foundation
import SwiftCrossUI

/// The selected paper (filled in by the next step).
struct DetailPane: View {
    @State var bridge: StoreBridge

    var body: some View {
        if let paper = bridge.store.selectedPaper() {
            Text(paper.displayTitle).font(.title2).padding(16)
        } else {
            VStack(spacing: 6) {
                Text(LibraryPresentation.noSelection.title).font(.headline)
                Text(LibraryPresentation.noSelection.message).foregroundColor(.gray)
            }
            .padding(16)
        }
    }
}
#endif
