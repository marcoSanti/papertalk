import Foundation

/// The voice selection sheet's state and rules: who speaks, their gender and
/// voice, and whether the cast can be confirmed. The sheet lays it out.
struct CastForm: Equatable {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var role: String
        var name: String
        var voice: String
        /// "male" / "female", or nil when neither the LLM nor the name tells.
        var gender: String?
    }

    private(set) var rows: [Row]
    /// The paper's authors: the guest is picked from these.
    let authors: [String]
    /// Author full name -> gender, from the LLM.
    let authorGenders: [String: String]

    init(proposals: [ProposedSpeaker], authors: [String], authorGenders: [String: String]) {
        rows = Self.initialRows(proposals)
        self.authors = authors
        self.authorGenders = authorGenders
    }

    /// Default voices: the interviewer keeps the show's signature voice
    /// (Heart / Michael), each guest gets a different voice of their own
    /// gender, varied per author.
    static func initialRows(_ proposals: [ProposedSpeaker]) -> [Row] {
        var rows = proposals.map { Row(role: $0.role, name: $0.name, voice: $0.voice, gender: $0.gender) }
        var used = Set<String>()
        for i in rows.indices where isHost(rows[i].role) {
            rows[i].voice = KokoroSpeech.defaultVoice(forGender: proposals[i].gender, avoiding: used)
            used.insert(rows[i].voice)
        }
        for i in rows.indices where !isHost(rows[i].role) {
            rows[i].voice = KokoroSpeech.guestVoice(forGender: proposals[i].gender, name: rows[i].name, avoiding: used)
            used.insert(rows[i].voice)
        }
        return rows
    }

    /// The host/anchor speaks for the show; everyone else is an interviewed author.
    static func isHost(_ role: String) -> Bool {
        let r = role.lowercased()
        return ["interviewer", "host", "anchor", "moderator", "presenter"].contains { r.contains($0) }
    }

    // MARK: per-row presentation

    /// Guests are chosen from the paper's authors (when it has any); the
    /// interviewer's name is typed.
    func picksFromAuthors(_ row: Row) -> Bool { !Self.isHost(row.role) && !authors.isEmpty }

    /// Extra entry in the author menu for a name that isn't one of the authors
    /// (the LLM's suggestion, or nothing yet).
    func authorPlaceholder(_ row: Row) -> String? {
        guard !authors.contains(row.name) else { return nil }
        return row.name.isEmpty ? L("Choose an author…") : row.name
    }

    static func avatarName(_ row: Row) -> String { row.name.isEmpty ? row.role : row.name }

    static func genderHelp(_ row: Row) -> String {
        row.gender == nil ? L("Gender unknown — pick one so the voice fits") : L("Switching gender picks a matching voice")
    }

    static func voiceHelp(_ voice: String) -> String {
        "\(KokoroSpeech.accentLabel(voice)) · \(KokoroSpeech.genderLabel(KokoroSpeech.voiceGender(voice)) ?? L("voice"))"
    }

    // MARK: edits

    /// Rename a speaker. Picking a different author also takes that author's
    /// gender (from the LLM, else their first name), which re-voices them.
    mutating func rename(_ id: Row.ID, to name: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].name = name
        guard !Self.isHost(rows[i].role), authors.contains(name),
              let g = authorGenders[name] ?? KokoroSpeech.guessGender(fromName: name) else { return }
        setGender(id, g)
    }

    /// Change a speaker's gender; if their voice no longer matches, give them
    /// the default for it (host: signature voice; guest: per-author), avoiding
    /// everyone else's voice.
    mutating func setGender(_ id: Row.ID, _ gender: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].gender = gender
        guard KokoroSpeech.voiceGender(rows[i].voice) != gender else { return }
        let others = Set(rows.filter { $0.id != id }.map(\.voice))
        rows[i].voice = Self.isHost(rows[i].role)
            ? KokoroSpeech.defaultVoice(forGender: gender, avoiding: others)
            : KokoroSpeech.guestVoice(forGender: gender, name: rows[i].name, avoiding: others)
    }

    mutating func setVoice(_ id: Row.ID, _ voice: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].voice = voice
    }

    // MARK: validation and result

    private var trimmedNames: [String] { rows.map { $0.name.trimmingCharacters(in: .whitespaces) } }

    enum Issue: Equatable {
        case emptyName, duplicateName, unknownGender(String), sharedVoice
    }

    /// The most important problem with the cast, if any. Names block
    /// confirming; gender and shared voices are only warnings.
    var issue: Issue? {
        let names = trimmedNames
        if names.contains(where: \.isEmpty) { return .emptyName }
        if Set(names.map { $0.lowercased() }).count < names.count { return .duplicateName }
        if let unknown = rows.first(where: { $0.gender == nil }) { return .unknownGender(Self.avatarName(unknown)) }
        if Set(rows.map(\.voice)).count < rows.count { return .sharedVoice }
        return nil
    }

    enum Severity { case error, warning, info }

    /// The line under the speaker cards.
    var note: (text: String, severity: Severity) {
        switch issue {
        case .emptyName: return (L("Every speaker needs a name."), .error)
        case .duplicateName: return (L("Each speaker needs a different name."), .error)
        case .unknownGender(let who):
            return (L("Couldn't tell {0}'s gender — choose Female or Male so the voice fits.", who), .warning)
        case .sharedVoice: return (L("Speakers share a voice, so they'll be hard to tell apart."), .warning)
        case nil: return (L("Each person's voice is used whenever they speak. Choosing a voice plays a short sample."), .info)
        }
    }

    var canConfirm: Bool {
        guard !rows.isEmpty else { return false }
        return issue != .emptyName && issue != .duplicateName
    }

    /// The second confirm button: write the script with these names, but no audio yet.
    static var scriptOnlyTitle: String { L("Skip audio") }
    static var scriptOnlyHelp: String { L("Write the script without voicing it. You can voice it later with Regenerate audio.") }

    /// The confirmed cast: trimmed names with their voices.
    var cast: [SpeakerConfig] {
        zip(rows, trimmedNames).map { SpeakerConfig(name: $1, voice: $0.voice) }
    }
}

/// The speaking-pace control under the speaker cards.
enum SpeakingPacePresentation {
    static func label(_ speed: Double) -> String { String(format: "%.2f×", speed) }

    static func isDefault(_ speed: Double) -> Bool { abs(speed - PlayerController.defaultSpeed) < 0.001 }

    /// Above this, Kokoro (trained on natural-pace speech) may slur words.
    static let slurThreshold = 1.5

    /// The warning shown above `slurThreshold`, with how long a 30-minute
    /// summary (planned at the default pace) plays at `speed`.
    static func warning(_ speed: Double) -> String? {
        guard speed > slurThreshold else { return nil }
        let minutes = Int((30 * PlayerController.defaultSpeed / speed).rounded())
        return L("Kokoro is trained on natural-pace speech, so words may slur above 1.5× — listen to a sample first. Episodes also get shorter: a 30-minute summary plays in about {0} minutes at this pace.", minutes)
    }
}

/// The voice-sample button's wording for each preview phase.
enum VoiceSamplePresentation {
    /// The preview phase that concerns this button's voice (nil if another voice is previewing).
    static func phase(_ preview: PlayerController.PreviewPhase?, for voice: String) -> PlayerController.PreviewPhase? {
        preview?.voice == voice ? preview : nil
    }

    static func label(_ phase: PlayerController.PreviewPhase?, loadingModel: Bool) -> String {
        switch phase {
        case .generating: return loadingModel ? L("Loading voices…") : L("Generating…")
        case .playing: return L("Playing")
        case .failed: return L("Retry")
        case nil: return L("Sample")
        }
    }

    static func help(_ phase: PlayerController.PreviewPhase?, voice: String) -> String {
        switch phase {
        case .generating: return L("Synthesizing a sample of {0} — click to cancel", KokoroSpeech.displayName(voice))
        case .playing: return L("Stop the sample")
        case .failed(_, let msg): return L("Couldn't play the sample: {0}", msg)
        case nil: return L("Hear {0}", KokoroSpeech.displayName(voice))
        }
    }

    /// Clicking while generating or playing stops; otherwise it (re)plays.
    static func tapStops(_ phase: PlayerController.PreviewPhase?) -> Bool {
        switch phase {
        case .generating, .playing: return true
        default: return false
        }
    }
}
