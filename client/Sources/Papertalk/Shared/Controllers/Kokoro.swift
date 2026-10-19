import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

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

    /// Same-gender voices, best-sounding first (per Kokoro's own voice grades),
    /// so two speakers of the same gender still get distinct, good voices.
    static let femalePool = [femaleVoice, "af_bella", "af_nicole", "bf_emma", "af_aoede", "af_kore", "af_sarah"]
    static let malePool = [maleVoice, "am_fenrir", "am_puck", "bm_george", "bm_fable", "bm_lewis"]

    /// A guest's voice: one of the best few voices of their gender that nobody
    /// in `used` has, chosen by a stable hash of their name, so different
    /// guests sound different and the same author always sounds the same.
    static func guestVoice(forGender gender: String?, name: String, avoiding used: Set<String>) -> String {
        let pool = (gender == "male" ? malePool : femalePool).filter { !used.contains($0) }.prefix(4)
        guard !pool.isEmpty else { return defaultVoice(forGender: gender, avoiding: used) }
        // djb2: Swift's hashValue is randomized per launch, this is not.
        let h = name.lowercased().unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return pool[pool.startIndex + Int(h % UInt64(pool.count))]
    }

    /// First voice for `gender` that no one in `used` already has.
    static func defaultVoice(forGender gender: String?, avoiding used: Set<String>) -> String {
        let pool = gender == "male" ? malePool : femalePool
        return pool.first { !used.contains($0) } ?? pool[0]
    }

    /// Last-resort gender guess from a first name, used only when the LLM didn't
    /// say. The cast sheet shows the result and lets the user flip it.
    static func guessGender(fromName name: String) -> String? {
        let first = name.split(whereSeparator: { !$0.isLetter }).first?.lowercased() ?? ""
        let males: Set<String> = ["alex", "sam", "marco", "luca", "matteo", "alessandro", "giuseppe", "antonio",
            "giovanni", "francesco", "carlo", "paolo", "davide", "giacomo", "riccardo", "edoardo", "tommaso",
            "gabriele", "massimo", "fabio", "salvatore", "michael", "john", "james", "robert", "william", "bill",
            "richard", "joseph", "charles", "david", "daniel", "mark", "paul", "peter", "george", "leo", "mario",
            "luigi", "nicola", "andrea", "vincenzo", "samuel", "thomas", "chris", "christopher", "kyle", "ryan",
            "eric", "nathan", "andrew", "joshua", "alan", "adam", "oscar", "matthew", "steven", "brian", "kevin",
            "jason", "jeff", "jeffrey", "scott", "frank", "henry", "jack", "harry", "wei", "jun", "hiroshi", "takeshi"]
        let females: Set<String> = ["maria", "giulia", "sofia", "elena", "anna", "lucia", "chiara", "sara",
            "francesca", "valentina", "ilaria", "silvia", "alessia", "martina", "giorgia", "marta", "beatrice",
            "emma", "olivia", "isabella", "mia", "charlotte", "amelia", "hannah", "zoe", "lina", "maya", "sandra",
            "melissa", "jennifer", "jessica", "rebecca", "laura", "fatima", "susan", "karen", "mary", "patricia",
            "linda", "elizabeth", "barbara", "sarah", "nancy", "lisa", "emily", "ashley", "michelle", "amy",
            "tongshuang", "tasnuva", "yuki", "mei", "priya", "ananya"]
        if males.contains(first) { return "male" }
        if females.contains(first) { return "female" }
        return nil
    }

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

    /// 24 kHz mono 16-bit PCM WAV duration in seconds.
    static func wavDuration(_ data: Data) -> Double {
        let bytes = data.count
        guard bytes > 44 else { return 0 }
        return Double(bytes - 44) / Double(24000 * 2)
    }

    /// Longest piece of text sent to Kokoro in one call.
    /// Measured on a 150-turn bake: peak memory ~1.2 GB unsplit, ~0.9 GB at
    /// 400 characters, ~0.45 GB at 200, at the same speed.
    static let maxPieceLength = 200

    /// Split a turn into pieces of at most `max` characters: between sentences,
    /// else after a comma, semicolon or colon, else between words. Kokoro holds
    /// every sample and Core ML buffer of a call until it returns, so a long
    /// monologue pushed memory past 1 GB and got the app killed on 8 GB Macs;
    /// short calls keep the peak flat whatever the turn's length.
    static func pieces(of text: String, max: Int = maxPieceLength) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > max else { return clean.isEmpty ? [] : [clean] }
        var sentences: [String] = []
        clean.enumerateSubstrings(in: clean.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sentences.append(s) }
        }
        let units = sentences.flatMap { sentence -> [String] in
            guard sentence.count > max else { return [sentence] }
            let clauses = pack(words(sentence, splitAfter: [",", ";", ":"]), max: max)
            return clauses.flatMap { $0.count > max ? pack(words($0, splitAfter: nil), max: max) : [$0] }
        }
        return pack(units, max: max)
    }

    /// Words of `s`, or with `splitAfter`, runs of words ending at one of those marks.
    private static func words(_ s: String, splitAfter marks: Set<Character>?) -> [String] {
        let all = s.split(separator: " ").map(String.init)
        guard let marks else { return all }
        var out: [String] = [], run = ""
        for w in all {
            run = run.isEmpty ? w : run + " " + w
            if let last = w.last, marks.contains(last) { out.append(run); run = "" }
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    /// Join consecutive units with spaces into pieces of at most `max` characters
    /// (a unit longer than `max` stays whole).
    private static func pack(_ units: [String], max: Int) -> [String] {
        var out: [String] = [], buf = ""
        for u in units {
            if !buf.isEmpty, buf.count + 1 + u.count > max { out.append(buf); buf = u } else { buf = buf.isEmpty ? u : buf + " " + u }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    /// One WAV from consecutive 24 kHz mono 16-bit pieces (their PCM joined).
    static func joinWAVs(_ parts: [Data]) -> Data {
        if parts.count == 1 { return parts[0] }
        var pcm = Data()
        for part in parts where part.count > 44 { pcm.append(part.subdata(in: part.startIndex + 44..<part.endIndex)) }
        return SpeechAudio.wavFile(pcm16: pcm)
    }
}