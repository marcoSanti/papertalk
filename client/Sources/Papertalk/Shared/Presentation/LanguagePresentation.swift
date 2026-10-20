import Foundation

/// The interface language picker, in Settings and in first-run setup.
enum LanguagePresentation {
    static var title: String { L("Language") }
    static var pickerLabel: String { L("Interface language") }
    static var intro: String {
        L("Menus, buttons and messages appear in this language. Episodes, transcripts and mind maps are written in English unless you ask for this language when you import a paper.")
    }

    /// Each language under its own name, so it can be found whatever is shown now.
    static var options: [(language: AppLanguage, title: String)] {
        AppLanguage.allCases.map { ($0, $0.nativeName) }
    }
}
