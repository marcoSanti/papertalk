// The New Library / Edit Library sheet's state and wording: name, icon and whether its mind
// maps connect to other libraries.

import Foundation

/// The library sheet's form. `id` is the library's (a fresh one for a new library).
struct LibraryForm: Identifiable, Equatable {
    let id: String
    /// Editing an existing library rather than creating one.
    let isNew: Bool
    var name: String
    var icon: String
    var connectsAcross: Bool

    /// The icons the sheet offers (SF Symbols).
    static let icons = [
        "folder", "books.vertical", "book.closed", "graduationcap", "brain", "atom", "flask",
        "leaf", "globe", "cpu", "function", "chart.bar", "heart", "star", "bolt", "lightbulb",
    ]

    /// A blank form for a new library.
    init() {
        id = UUID().uuidString; isNew = true
        name = ""; icon = Self.icons[0]; connectsAcross = false
    }

    /// A form holding `library`'s current values.
    init(_ library: Library) {
        id = library.id; isNew = false
        name = library.name; icon = library.icon; connectsAcross = library.connectsAcross
    }

    private var cleanName: String {
        name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// A name is needed.
    var canSave: Bool { !cleanName.isEmpty }

    /// The library to save.
    var library: Library { Library(id: id, name: cleanName, icon: icon, connectsAcross: connectsAcross) }

    /// The sheet's heading.
    var title: String { isNew ? L("New Library") : L("Edit Library") }
    /// The save button.
    var saveLabel: String { isNew ? L("Create Library") : L("Save") }
    /// The cross-library toggle and its explanation.
    static var connectsAcrossTitle: String { L("Connect mind maps to other libraries") }
    static var connectsAcrossHelp: String {
        L("Off, a paper's mind map is only connected to the other papers in this library. The change applies to mind maps drawn from now on.")
    }
}
