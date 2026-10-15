#if os(Linux)
import Foundation
import SwiftCrossUI

/// Library sections and tags, like the macOS sidebar.
///
/// Layout note for every split-view pane: don't put modifiers (padding, frame)
/// on the pane's root view. With a List inside, SwiftCrossUI 0.9 then lays the
/// pane out at its minimum size, centred and clipped. Pad the rows instead, and
/// set the column's width with a `PaneWidth` strut inside the pane.
struct SidebarPane: View {
    @State var bridge: StoreBridge

    var body: some View {
        let store = bridge.store
        let selection = Binding<SidebarItem?>(get: { store.sidebarSelection },
                                              set: { if let item = $0 { store.selectSidebar(item) } })
        return VStack(alignment: .leading, spacing: 6) {
            Text("Library").font(.caption).foregroundColor(.gray).padding(.horizontal, 12).padding(.top, 12)
            List(store.sidebarItems, id: \.self, selection: selection) { item in
                HStack {
                    Text(LibraryPresentation.sidebarTitle(item))
                    Spacer()
                    Text(LibraryPresentation.badge(store.sidebarCount(item)) ?? "").foregroundColor(.gray)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            Spacer()
            HStack {
                Text(LibraryPresentation.storageLocation(isStandalone: store.isStandalone).title).font(.caption)
                Spacer()
                Button("Settings") { store.settingsPage = .llm; store.showSettings = true }
            }
            .padding(12)
            PaneWidth(230)
        }
    }
}

/// An invisible strut that gives a split-view pane its minimum width (the
/// column starts at 200 points and can't be widened from outside the pane).
struct PaneWidth: View {
    let width: Double
    init(_ width: Double) { self.width = width }

    var body: some View {
        Color.adaptive(light: .clear, dark: .clear).frame(width: width, height: 1)
    }
}
#endif
