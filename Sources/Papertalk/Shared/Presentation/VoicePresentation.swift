// How voices are named in menus and tooltips, in the interface language.

import Foundation

extension KokoroSpeech {
    /// Accent family from the voice id's first letter, in the interface language. Every pack
    /// speaks English here; non-English packs just lend their timbre.
    static func accentLabel(_ voice: String) -> String {
        switch voice.first {
        case "a": return L("American")
        case "b": return L("British")
        case "e": return L("Spanish")
        case "f": return L("French")
        case "h": return L("Hindi")
        case "i": return L("Italian")
        case "j": return L("Japanese")
        case "p": return L("Portuguese")
        case "z": return L("Mandarin")
        default: return L("Other")
        }
    }

    /// "female" / "male" in the interface language.
    static func genderLabel(_ gender: String?) -> String? {
        switch gender {
        case "female": return L("female")
        case "male": return L("male")
        default: return nil
        }
    }

    /// Voices grouped for menus: accent × gender, American and British first.
    static var voiceGroups: [(title: String, voices: [String])] {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for v in allVoices {
            let g = genderLabel(voiceGender(v)).map { " · \($0)" } ?? ""
            let key = accentLabel(v) + g
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(v)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// Human label for a voice id, e.g. "am_michael" -> "Michael · male".
    static func label(_ voice: String) -> String {
        let name = displayName(voice)
        return genderLabel(voiceGender(voice)).map { "\(name) · \($0)" } ?? name
    }
}
