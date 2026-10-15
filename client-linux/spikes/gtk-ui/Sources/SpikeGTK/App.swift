import GtkBackend
import Foundation
import SpikeCore
import SwiftCrossUI

@main
struct SpikeApp: App {
    typealias Backend = GtkBackend
    var backend: GtkBackend { GtkBackend(appIdentifier: "dev.papertalk.spike") }

    @State var bridge = StoreBridge(Store(papers: [
        Paper(id: "1", title: "Attention Is All You Need", cover: nil),
        Paper(id: "2", title: "Deep Residual Learning", cover: nil),
        Paper(id: "3", title: "Language Models are Few-Shot Learners", cover: nil),
    ]))

    var body: some Scene {
        WindowGroup("Papertalk (GTK spike)") {
            ContentView(bridge: bridge)
        }
        .defaultSize(width: 900, height: 560)
        .commands {
            CommandMenu("File") {
                Button("Import PDF…") { bridge.store.showImport = true }
                Button("Delete Paper…") { bridge.store.requestDelete() }
            }
        }
    }
}

struct ContentView: View {
    @State var bridge: StoreBridge
    @Environment(\.chooseFile) var chooseFile

    var body: some View {
        let store = bridge.store
        NavigationSplitView {
            VStack {
                TextField("Search titles", text: bridge.binding(\.search))
                List(store.filtered, selection: bridge.binding(\.selectedId)) { paper in
                    Text(paper.title)
                }
            }
            .padding()
        } detail: {
            VStack(alignment: .leading) {
                if let paper = store.papers.first(where: { $0.id == store.selectedId }) {
                    Text(paper.title).font(.system(size: 22))
                    if let png = paper.cover, let image = Covers.image(png) {
                        Image(image).frame(width: 140, height: 180)
                    }
                    HStack {
                        Button("Delete…") { store.requestDelete() }
                        Button("Import…") { store.showImport = true }
                    }
                } else {
                    Text("Select a paper").foregroundColor(.gray)
                }
                Text("Log: " + store.log.joined(separator: ", "))
                Text("revision \(bridge.revision)")
            }
            .padding()
        }
        .alert(store.pendingDelete.map { "Delete “\($0.title)”?" } ?? "",
               isPresented: Binding(get: { store.pendingDelete != nil },
                                    set: { if !$0 { store.pendingDelete = nil } })) {
            Button("Delete paper") { store.confirmDelete() }
            Button("Cancel") { store.pendingDelete = nil }
        }
        .sheet(isPresented: bridge.binding(\.showImport)) {
            VStack {
                Text("Import a PDF")
                Button("Choose file…") {
                    Task {
                        if let url = await chooseFile() { store.importFile(url) }
                    }
                }
                Button("Cancel") { store.showImport = false }
            }
            .padding()
        }
    }
}
