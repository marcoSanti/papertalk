// The MVC rules a compiler can't check, read off the sources: views only lay out and forward,
// wording stays out of the Model, and only controllers do I/O. scripts/check_layers.sh proves the
// other half, that the Model and Presentation don't depend on the layers above them.

import Foundation
import XCTest

final class ArchitectureTests: PapertalkTestCase {
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Papertalk")

    private static let views = ["macOS/Views", "macOS/Components", "Linux/UI"]
    private static let controllers = ["Shared/Controllers", "macOS/Controllers"]
    /// The controllers a view may talk to: the store, the player and what opens windows or panels.
    private static let viewFacing: Set<String> = ["AppStore", "PlayerController", "PaperPanels", "NowPlaying",
        "PaperWindow", "PaperChatWindow", "MindMapWindow", "LibraryMapWindow"]
    /// Store and player state a control edits in place (a field, a picker, a sheet's presence).
    private static let bindable: Set<String> = ["search", "sort", "libraryLayout", "selectedId", "selectedSuggestionId",
        "showUpload", "showSettings", "showOnboarding", "editingPaper", "editingLibrary", "transcriptSheet", "whatsNew",
        "askAboutUpdateChecks", "askToDeleteListenedAudio", "checkUpdatesToggle", "suggestionsEnabled", "suggestionDepth",
        "voiceSpeed"]

    /// Each Swift file of `folders` with its code, comments left out.
    private func sources(_ folders: [String]) throws -> [(file: String, code: String)] {
        var out: [(file: String, code: String)] = []
        for folder in folders {
            let root = Self.app.appendingPathComponent(folder)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            XCTAssertFalse(files.isEmpty, "no sources in \(folder); did they move?")
            for url in files {
                let code = try String(contentsOf: url, encoding: .utf8)
                    .replacingOccurrences(of: #"(?m)(^|\s)//.*$"#, with: "", options: .regularExpression)
                out.append(("\(folder)/\(url.lastPathComponent)", code))
            }
        }
        return out
    }

    private func matches(_ pattern: String, in code: String, group: Int = 0) throws -> [String] {
        let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let ns = code as NSString
        return re.matches(in: code, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: group)) }
    }

    /// Fail on every match of `pattern` in `folders`.
    private func forbid(_ pattern: String, in folders: [String], _ why: String) throws {
        for (file, code) in try sources(folders) {
            for hit in try matches(pattern, in: code) { XCTFail("\(file): `\(hit)`. \(why)") }
        }
    }

    func testViewsNeverWriteState() throws {
        try forbid(#"\b(store|player)(\??\.\w+)+(\[[^\]\n]*\])?\s*(=(?!=)|\+=|-=)|\b(store|player)(\??\.\w+)+\.toggle\(\)"#,
                   in: Self.views, "A view asks: call a method on the store or player.")
    }

    func testViewsBindOnlyToControlState() throws {
        for (file, code) in try sources(Self.views) {
            let bound = try matches(#"\$(?:store|player)\.(\w+)"#, in: code, group: 1)
                + matches(#"binding\(\\\.(\w+)"#, in: code, group: 1)
            for name in bound where !Self.bindable.contains(name) {
                XCTFail("\(file) binds to `\(name)`. Change it through a method, or add it to `bindable` if it's control state.")
            }
        }
    }

    func testViewsDoNoIO() throws {
        try forbid(#"\b(URLSession|UserDefaults|FileManager|KeychainStore|JSONDecoder|JSONEncoder|JSONSerialization|NSPasteboard|NSOpenPanel|NSSavePanel|PDFDocument|PDFSource)\b|Data\(contentsOf|NSWorkspace\.shared\.(open|activateFileViewerSelecting)|\bK\.\w+\(|\.save\(\)"#,
                   in: Self.views, "I/O belongs to a controller.")
    }

    func testViewsHoldNoLogic() throws {
        try forbid(#"trimmingCharacters|\.filter\s*[({]|\.sorted\s*[({]|replacingOccurrences|disabled\(!?paper\.|enabled: !?paper\."#,
                   in: Self.views, "Parsing, filtering, sorting and enablement belong in Presentation.")
    }

    func testViewsReachOnlyTheStoreThePlayerAndWindows() throws {
        var types = Set<String>()
        for (_, code) in try sources(Self.controllers) {
            types.formUnion(try matches(#"^(?:@\w+ )*(?:final )?(?:class|struct|enum|actor|protocol) (\w+)"#, in: code, group: 1))
        }
        XCTAssertTrue(types.isSuperset(of: Self.viewFacing), "a controller in `viewFacing` is gone")
        let hidden = types.subtracting(Self.viewFacing).sorted().joined(separator: "|")
        try forbid(#"\b(?:\#(hidden))\b"#, in: Self.views, "Views don't reach services: go through the store.")
    }

    func testControllersDeclareNoViews() throws {
        try forbid(#"^(?:\w+ )*(?:struct|class) \w+[^\n]*:\s*(?:View|NSView)\b"#, in: Self.controllers, "Views go in Views/ or Components/.")
    }

    func testSharedControllersKnowNoUIToolkit() throws {
        try forbid(#"^import (SwiftUI|SwiftCrossUI|GtkBackend)"#, in: ["Shared/Controllers"], "Controllers don't lay out.")
    }

    func testModelHasNoWordingAndNoUI() throws {
        try forbid(#"(?<![\w.])L\(|^import (SwiftUI|AppKit|SwiftCrossUI)|\bURLSession\.shared"#,
                   in: ["Shared/Models", "Shared/Support"], "Wording goes in Presentation, network in Controllers.")
    }

    func testPresentationIsPure() throws {
        try forbid(#"^import (SwiftUI|AppKit|SwiftCrossUI|PDFKit)|\b(URLSession|UserDefaults|FileManager|KeychainStore)\b|Data\(contentsOf"#,
                   in: ["Shared/Presentation"], "Presentation only computes; I/O belongs to a controller.")
    }
}
