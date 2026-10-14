import Foundation
import FluidAudio

/// Shared Kokoro voice selection + WAV helpers used by both live synthesis
/// (PlayerController) and import-time baking (AppStore), so baked audio and
/// on-demand fallback sound identical.
enum KokoroSpeech {
    static let maleVoice = "am_michael"
    static let femaleVoice = "af_heart"
    static let defaultVoice = "af_heart"

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
            let preferred = guessGender(s) == "male" ? maleVoice : femaleVoice
            var chosen = preferred
            if used.contains(chosen) { chosen = chosen == maleVoice ? femaleVoice : maleVoice }
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