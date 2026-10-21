// Wording and options for choosing the interface language.

import Foundation

/// The interface language picker, in Settings and in first-run setup.
enum LanguagePresentation {
    /// The Settings page that holds the picker, first in the sidebar.
    static var generalTitle: String { L("General") }
    /// The picker's label (also its tooltip in setup).
    static var pickerLabel: String { L("Interface language") }
    /// What the choice changes, under the heading.
    static var intro: String {
        L("Menus, buttons and messages appear in this language. Episodes, transcripts and mind maps are written in English unless you ask for this language when you import a paper.")
    }

    /// Each language under its own name, so it can be found whatever is shown now.
    static var options: [(language: AppLanguage, title: String)] {
        AppLanguage.allCases.map { ($0, $0.nativeName) }
    }
}
