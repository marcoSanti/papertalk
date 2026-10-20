import Foundation

/// A language the interface can be shown in. Only the interface: episodes,
/// transcripts and everything else the LLM writes stay in English unless an
/// import asks for the app's language (`ImportForm.writeInAppLanguage`).
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en", italian = "it", spanish = "es", german = "de", french = "fr"
    var id: String { rawValue }

    /// The language's own name, as the language picker lists it.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .french: return "Français"
        }
    }

    /// The name the LLM is told to write in.
    var englishName: String {
        switch self {
        case .english: return "English"
        case .italian: return "Italian"
        case .spanish: return "Spanish"
        case .german: return "German"
        case .french: return "French"
        }
    }

    /// Dates are formatted for the interface language.
    var locale: Locale { Locale(identifier: rawValue) }

    /// English → this language. English itself has no pack: its keys are the text.
    var pack: [String: String] {
        switch self {
        case .english: return [:]
        case .italian: return LanguagePacks.italian
        case .spanish: return LanguagePacks.spanish
        case .german: return LanguagePacks.german
        case .french: return LanguagePacks.french
        }
    }

    /// The first of the system's preferred languages the app has, else English.
    static func preferred(_ identifiers: [String]) -> AppLanguage {
        for id in identifiers {
            let code = String(id.prefix { $0 != "-" && $0 != "_" }).lowercased()
            if let match = AppLanguage(rawValue: code) { return match }
        }
        return .english
    }
}

/// Namespace for the per-language tables (`Packs/`).
enum LanguagePacks {}

/// The interface language in use and the lookup behind `L(_:_:)`.
enum Localization {
    /// Set once at launch (`load()`) and by `AppStore.setLanguage`. Tests run in English.
    nonisolated(unsafe) static var language: AppLanguage = .english

    static let defaultsKey = "papertalk.language"

    /// The saved choice, else the system's language when the app has it.
    static func load(defaults: UserDefaults = .standard, preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        defaults.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? AppLanguage.preferred(preferred)
    }

    /// `key` in `language`, with `{0}`, `{1}`… replaced by `args`. A key a pack
    /// lacks falls back to English (the suite checks every pack is complete).
    static func text(_ key: String, _ args: [Any], in language: AppLanguage) -> String {
        var out = language.pack[key] ?? key
        for (i, arg) in args.enumerated() {
            out = out.replacingOccurrences(of: "{\(i)}", with: "\(arg)")
        }
        return out
    }
}

/// Interface text: `key` is the English wording, translated into the current
/// language. Keys must be string literals, here or in `Localization.text` (the
/// suite collects them from the sources to check every pack); values go in
/// through `{0}`, `{1}`… placeholders.
func L(_ key: String, _ args: Any...) -> String {
    Localization.text(key, args, in: Localization.language)
}
