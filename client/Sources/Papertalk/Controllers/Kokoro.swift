import Foundation
import FluidAudio

/// Shared Kokoro voice selection + WAV helpers used by both live synthesis
/// (PlayerController) and import-time baking (AppStore), so baked audio and
/// on-demand fallback sound identical.
enum KokoroSpeech {
    static let maleVoice = "am_michael"
    static let femaleVoice = "af_heart"
    static let defaultVoice = "af_heart"

    /// Default voice id for a proposed speaker's gender (female unless male).
    static func defaultVoice(forGender gender: String?) -> String {
        gender == "male" ? maleVoice : femaleVoice
    }

    /// Same-gender voices in order of preference, so two speakers of the same
    /// gender still get distinct voices.
    static let femalePool = [femaleVoice, "af_bella", "af_nicole", "bf_emma", "af_sarah", "bf_isabella"]
    static let malePool = [maleVoice, "am_adam", "bm_george", "am_eric", "bm_lewis", "am_liam"]

    /// First voice for `gender` that no one in `used` already has.
    static func defaultVoice(forGender gender: String?, avoiding used: Set<String>) -> String {
        let pool = gender == "male" ? malePool : femalePool
        return pool.first { !used.contains($0) } ?? pool[0]
    }

    /// Best-effort gender guess for a name ("male"/"female"/nil).
    static func gender(for name: String) -> String? { guessGender(name) }

    /// Short spoken sample demonstrating a voice, e.g. for a preview: the label
    /// (minus its gender suffix) is inserted as the voice's name.
    static func samplePrompt(for voice: String) -> String {
        let short = label(voice).split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? voice
        return "Hello, my name is \(short), and I am an AI generated voice."
    }

    /// Every voice the English Kokoro bundle can load, for user-pickable menus.
    static let allVoices: [String] = KokoroAneConstants.englishVoices

    /// Display name without gender, e.g. "am_michael" -> "Michael".
    static func displayName(_ voice: String) -> String {
        guard let name = voice.split(separator: "_").last else { return voice }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// "female" / "male" / nil from the voice id's second letter.
    static func voiceGender(_ voice: String) -> String? {
        let p = Array(voice.prefix(2))
        guard p.count == 2 else { return nil }
        return p[1] == "f" ? "female" : p[1] == "m" ? "male" : nil
    }

    /// Accent family from the voice id's first letter. Every pack speaks
    /// English here; non-English packs just lend their timbre.
    static func accent(_ voice: String) -> String {
        switch voice.first {
        case "a": return "American"
        case "b": return "British"
        case "e": return "Spanish"
        case "f": return "French"
        case "h": return "Hindi"
        case "i": return "Italian"
        case "j": return "Japanese"
        case "p": return "Portuguese"
        case "z": return "Mandarin"
        default: return "Other"
        }
    }

    /// Voices grouped for menus: accent × gender, American and British first.
    static let voiceGroups: [(title: String, voices: [String])] = {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for v in allVoices {
            let g = voiceGender(v).map { " · \($0)" } ?? ""
            let key = accent(v) + g
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(v)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }()

    /// Human label for a voice id, e.g. "am_michael" -> "Michael · male".
    static func label(_ voice: String) -> String {
        let parts = voice.split(separator: "_")
        guard let name = parts.last else { return voice }
        let gender = voice.hasPrefix("af") || voice.hasPrefix("bf") || voice.hasPrefix("ef")
            || voice.hasPrefix("ff") || voice.hasPrefix("hf") || voice.hasPrefix("if")
            || voice.hasPrefix("jf") || voice.hasPrefix("pf") || voice.hasPrefix("zf")
            ? "female"
            : voice.hasPrefix("am") || voice.hasPrefix("bm") || voice.hasPrefix("em")
                || voice.hasPrefix("hm") || voice.hasPrefix("im") || voice.hasPrefix("jm")
                || voice.hasPrefix("pm") || voice.hasPrefix("zm")
                ? "male" : ""
        let pretty = name.prefix(1).uppercased() + name.dropFirst()
        return gender.isEmpty ? pretty : "\(pretty) · \(gender)"
    }

    static func voice(for speaker: String) -> String {
        guessGender(speaker) == "male" ? maleVoice : defaultVoice
    }

    /// Assign a voice to every distinct speaker in a transcript, guaranteeing
    /// two different speakers always get two different voices (so the back-and-
    /// forth is audible even when gender guessing is ambiguous or misses).
    static func voices(for speakers: [String]) -> [String: String] {
        let distinct = speakers.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var map: [String: String] = [:]
        var used = Set<String>()
        for s in distinct {
            // Keep each speaker's gender; a clash moves to another voice of the same gender.
            let chosen = defaultVoice(forGender: guessGender(s), avoiding: used)
            map[s] = chosen
            used.insert(chosen)
        }
        return map
    }

    /// 24 kHz mono 16-bit PCM WAV duration in seconds.
    static func wavDuration(_ data: Data) -> Double {
        let bytes = data.count
        guard bytes > 44 else { return 0 }
        return Double(bytes - 44) / Double(24000 * 2)
    }

    private static func guessGender(_ name: String) -> String? {
        let males: Set<String> = ["alex","sam","marco","luca","matteo","alessandro","giuseppe","antonio","giovanni",
            "francesco","carlo","paolo","davide","giacomo","riccardo","edoardo","tommaso","michael","john","james",
            "robert","william","david","daniel","mark","paul","peter","george","leo","mario","luigi","nicola",
            "vincenzo","samuel","thomas","chris","kyle","ryan","eric","nathan","andrew","joshua","alan","adam","oscar"]
        let females: Set<String> = ["maria","giulia","sofia","elena","anna","lucia","chiara","sara","francesca",
            "valentina","ilaria","silvia","alessia","martina","giorgia","marta","beatrice","emma","olivia","isabella",
            "mia","charlotte","amelia","hannah","zoe","lina","maya","sandra","melissa","jennifer","jessica","rebecca",
            "laura","fatima","susan","karen"]
        let first = name.split(whereSeparator: { !$0.isLetter }).first?.lowercased() ?? ""
        if males.contains(first) { return "male" }
        if females.contains(first) { return "female" }
        if first.hasSuffix("a") { return "female" }
        if first.hasSuffix("o") || first.hasSuffix("io") { return "male" }
        return nil
    }
}