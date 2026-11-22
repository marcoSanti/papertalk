// Finding the JSON object in an LLM's reply, for the models' parsers and the pipeline.

import Foundation

/// An LLM reply read as JSON.
enum LLMReply {
    /// The JSON object in a reply: from the first "{" to the last "}". This is why the LLM is
    /// always asked for an object, never a top-level array.
    static func json(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Take everything from the first "{" to the last "}", ignoring any
        // prose the model added before/after and code fences.
        guard s.contains("{"),
              let start = s.firstIndex(of: "{"),
              let end = s.lastIndex(of: "}") else { return nil }
        return String(s[start...end])
    }

    /// That object, parsed; nil when there's none.
    static func object(_ raw: String) -> [String: Any]? {
        guard let json = json(raw) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
}
