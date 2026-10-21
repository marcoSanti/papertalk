// How one paper is described and what can be done with it: card and list subtitles, the details
// panel's labels and enabled actions, status wording, the conversion checklist
// (`ConversionPresentation`) and listening progress (`EpisodeProgress`).

import Foundation

/// How a single paper is described across the library and the details panel.
enum PaperPresentation {
    /// "Ada Lovelace, Grace Hopper, Alan Turing et al." (first three names).
    static func authorLine(_ authors: [String]) -> String {
        authors.count > 3 ? L("{0} et al.", authors.prefix(3).joined(separator: ", ")) : authors.joined(separator: ", ")
    }

    /// Grid card subtitle: the first author (+ "et al."), else depth or filename.
    static func cardSubtitle(_ p: Paper) -> String {
        if let first = p.authors.first {
            return p.authors.count > 1 ? L("{0} et al.", first) : first
        }
        return p.depthTitle ?? p.filename ?? ""
    }

    /// List row subtitle: every author, else the filename.
    static func listSubtitle(_ p: Paper) -> String {
        p.authors.isEmpty ? (p.filename ?? "—") : p.authors.joined(separator: ", ")
    }

    /// The status badge on a cover: only while converting or after a failure.
    static func showsStatusBadgeOnCover(_ p: Paper) -> Bool { p.isError || p.isActive }

    /// The "NEW" marker: finished but not listened to yet.
    static func isNew(_ p: Paper) -> Bool { !p.read && p.isDone }

    /// The thin bar along a cover's bottom edge: conversion progress while
    /// converting, otherwise how much has been listened to (0 hides it).
    static func progressStrip(_ p: Paper) -> Double {
        if p.isActive { return min(1, max(0.02, p.progress)) }
        guard p.duration > 0, p.progress > 0 else { return 0 }
        return min(1, p.progress / p.duration)
    }

    /// A rename typed into the title field, tidied; nil if it's empty (the
    /// field then reverts) or unchanged.
    static func titleEdit(_ draft: String, current: String) -> (clean: String, changed: Bool)? {
        let clean = draft.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        return (clean, clean != current)
    }

    /// Tooltip on the big cover in the details panel.
    static func coverHelp(_ p: Paper) -> String { p.hasPdf ? L("Double-click to open the PDF") : "" }

    /// "3 papers" beside an author in the details panel, only when they have more than this one.
    static func otherPapersLabel(_ count: Int) -> String? { count > 1 ? LibraryPresentation.paperCount(count) : nil }

    /// The doi.org link for a DOI, nil when there's none.
    static func doiURL(_ doi: String) -> URL? {
        doi.isEmpty ? nil : URL(string: "https://doi.org/\(doi)")
    }

    /// Published date for the details panel, nil when unknown or unparseable.
    static func publishedDate(_ p: Paper) -> String? {
        guard let iso = p.publishedIso else { return nil }
        let s = formatDate(iso)
        return s.isEmpty ? nil : s
    }

    /// Tooltip for an asset (PDF / Transcript / Audio) in the details panel.
    static func assetHelp(_ label: String, present: Bool) -> String {
        present ? L("{0} available", label) : L("{0} not available yet", label)
    }

    // MARK: authors and tags

    /// Authors listed before "Show all".
    static let authorPreviewLimit = 5

    /// The authors to list: all, or the first `authorPreviewLimit`.
    static func visibleAuthors(_ authors: [String], showAll: Bool) -> [String] {
        showAll ? authors : Array(authors.prefix(authorPreviewLimit))
    }

    /// The show-all / show-fewer button, nil when every author already fits.
    static func authorsToggleTitle(count: Int, showingAll: Bool) -> String? {
        guard count > authorPreviewLimit else { return nil }
        return showingAll ? L("Show fewer") : L("Show all {0} authors", count)
    }

    /// The library's most-used tags this paper doesn't have yet.
    static func suggestedTags(for p: Paper, tagCounts: [(String, Int)], limit: Int = 5) -> [String] {
        tagCounts
            .filter { !p.tags.contains($0.0) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: sections and actions

    /// The conversion card shows while converting and after a failure.
    static func showsConversionCard(_ p: Paper) -> Bool { p.isActive || p.isError }
    /// The episode card shows once there's a script or audio.
    static func showsEpisodeCard(_ p: Paper) -> Bool { p.hasScript || p.hasAudio }
    /// A script can be played (live) even without saved audio.
    static func isPlayable(_ p: Paper) -> Bool { p.hasScript || p.hasAudio }

    /// Regenerate needs a script, and waits while any conversion runs
    /// (voicing shares the one Kokoro model).
    static func canRegenerateAudio(_ p: Paper, anyConversionRunning: Bool) -> Bool {
        p.hasScript && !anyConversionRunning
    }

    /// A paper being converted can't be rerun until it stops.
    static func canRerun(_ p: Paper) -> Bool { !p.isActive }

    /// A script without saved audio plays with voices made live (`PlayerController.prepare(transcript:)`):
    /// nothing is stored, so every listen synthesizes it again. Nil when there's audio, or no episode yet.
    static func liveAudioWarning(_ p: Paper) -> String? {
        guard p.hasScript, !p.hasAudio, !p.isActive else { return nil }
        return L("No saved audio: the voices are made live as you listen and aren't kept. Regenerate audio voices it once and saves it.")
    }

    /// Shown when live playback starts, wherever Play was pressed.
    static var liveAudioToast: String { L("Playing with live voices. This audio isn't saved; Regenerate audio saves it.") }

    /// Older records have no flag: no mind map.
    static func hasMindMap(_ p: Paper) -> Bool { p.hasMindMap == true }

    /// A mind map needs the PDF and the LLM, and waits for the paper's import
    /// (which draws one itself) and for a drawing already under way.
    static func canCreateMindMap(_ p: Paper, llmConfigured: Bool, drawing: Bool) -> Bool {
        p.hasPdf && llmConfigured && !p.isActive && !drawing
    }

    /// The Manage row that creates or redraws the mind map.
    static func mindMapRow(_ p: Paper, drawing: Bool) -> (title: String, subtitle: String) {
        if drawing { return (L("Drawing mind map…"), L("Asking the LLM for the paper's key concepts")) }
        return hasMindMap(p) ? (L("Redraw mind map"), L("Map the paper's key concepts again"))
            : (L("Create mind map"), L("Map the paper's key concepts and how they connect"))
    }

    /// The paper's title as a file name: path separators replaced, kept to a sane length.
    static func fileName(_ p: Paper, extension ext: String) -> String {
        let safe = p.displayTitle.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: "-")
        return String(safe.trimmingCharacters(in: .whitespaces).prefix(200)) + "." + ext
    }

    /// The suggested name of an exported `.papertalk` bundle.
    static func bundleFileName(_ p: Paper) -> String { fileName(p, extension: PaperBundle.pathExtension) }

    /// The question asked before exporting a paper that has a PDF. Leaving the PDF out is
    /// the default button: most papers' PDFs are under copyright.
    static var exportPDFQuestion: (title: String, message: String, withoutPDF: String, withPDF: String, cancel: String) {
        (L("Include the paper's PDF?"),
         L("Most papers' PDFs are under copyright, so you may not be allowed to share them. Include it only if you have the right to; without it, the episode, script and mind map still come along."),
         L("Export Without PDF"), L("Include the PDF"), L("Cancel"))
    }

    /// A paper can be exported once it isn't being converted.
    static func canExportPaper(_ p: Paper) -> Bool { !p.isActive }

    /// Baked audio can go once the paper isn't being converted; the script stays.
    static func canDeleteAudio(_ p: Paper) -> Bool { p.hasAudio && !p.isActive }

    /// A converting paper can be stopped (and deleted) while it runs.
    static func canStop(_ p: Paper) -> Bool { p.isActive }
    /// The stop button and menu item.
    static var stopTitle: String { L("Stop conversion") }

    /// Rerunning a paper that has an episode replaces it, so it's confirmed first.
    static func rerunNeedsConfirmation(_ p: Paper) -> Bool { p.hasScript || p.hasAudio }

    /// The context menu's listened toggle: title and SF Symbol.
    static func listenedToggle(_ p: Paper) -> (title: String, icon: String) {
        p.read ? (L("Mark as unlistened"), "circle") : (L("Mark as listened"), "checkmark.circle")
    }

    /// The context menu's favourite toggle: title and SF Symbol.
    static func favoriteToggle(_ p: Paper) -> (title: String, icon: String) {
        p.favorite ? (L("Remove from favorites"), "star.fill") : (L("Add to favorites"), "star")
    }

    /// The favourite button in the details panel's action bar.
    static func favoriteButton(_ p: Paper) -> (title: String, icon: String) {
        p.favorite ? (L("Favorited"), "star.fill") : (L("Favorite"), "star")
    }

    /// The play button in the details panel's action bar.
    static func playButton(_ p: Paper, isPlaying: Bool) -> (title: String, icon: String) {
        if isPlaying { return (L("Pause"), "pause.fill") }
        return (p.progress > 1 ? L("Resume") : L("Play"), "play.fill")
    }

    // MARK: status

    /// The status badge's word.
    static func statusText(_ p: Paper) -> String {
        switch p.statusKind {
        case .running: return p.state == "queued" ? L("Queued") : L("Converting")
        case .done: return p.read ? L("Listened") : L("Ready")
        case .error: return L("Failed")
        case .unknown: return p.state.isEmpty || p.state == "draft" ? L("Not converted") : p.state.capitalized
        }
    }

    /// The status badge's SF Symbol.
    static func statusIcon(_ p: Paper) -> String {
        switch p.statusKind {
        case .running: return "hourglass"
        case .done: return p.read ? "checkmark.circle.fill" : "waveform"
        case .error: return "exclamationmark.triangle.fill"
        case .unknown: return "doc"
        }
    }

    /// The error card's heading: a stop the user asked for isn't a failure.
    static func failureTitle(_ p: Paper) -> String {
        ConversionPresentation.isStopped(p) ? L("Conversion stopped") : L("Conversion failed")
    }

    /// The error card's explanation.
    static func failureMessage(_ p: Paper) -> String {
        p.statusError ?? p.message ?? L("Something went wrong while converting this paper.")
    }
}

/// The conversion checklist shown while a paper converts.
enum ConversionPresentation {
    /// Left on a paper whose conversion was stopped.
    static var stoppedMessage: String { stopped(in: Localization.language) }

    private static func stopped(in language: AppLanguage) -> String {
        Localization.text("Stopped. The script and any voiced sections are kept: Try again continues from there.", [], in: language)
    }

    /// The paper was stopped, whatever language the interface had then (the message is saved with the paper).
    static func isStopped(_ p: Paper) -> Bool { AppLanguage.allCases.contains { stopped(in: $0) == p.statusError } }

    /// The checklist rows: each `Paper.stage` key with its label, in pipeline order.
    static var stages: [(key: String, label: String)] { [
        ("extract", L("Extract text")),
        ("notes", L("Summarize")),
        ("outline", L("Plan episode")),
        ("segments", L("Write dialogue")),
        ("audio", L("Synthesize voices")),
        ("finalize", L("Finalize")),
    ] }

    /// Index of the stage in progress (0 when unknown).
    static func currentStage(_ stage: String?) -> Int {
        stages.firstIndex { $0.key == (stage ?? "") } ?? 0
    }

    /// How a checklist row is drawn.
    enum StageState { case done, current, pending }
    /// A row before the current one is done, after it pending.
    static func state(ofStage index: Int, current: Int) -> StageState {
        index < current ? .done : index == current ? .current : .pending
    }

    /// Progress bar value: never fully empty, so a just-started run shows movement.
    static func barValue(_ progress: Double) -> Double { min(1, max(0.02, progress)) }

    /// "42%" beside the bar.
    static func percentLabel(_ progress: Double) -> String {
        "\(Int((max(0.02, progress) * 100).rounded()))%"
    }
}

/// Listening progress for the details panel's episode card. Uses the live
/// player position when this paper is the one loaded, else the saved one.
struct EpisodeProgress: Equatable {
    /// Seconds listened.
    let position: Double
    /// The episode's length in seconds (0 until known).
    let length: Double
    /// Listened to the end (or marked so).
    let isRead: Bool
    /// Saved audio exists (else it plays live).
    let hasAudio: Bool

    /// `isLoaded`: this paper is in the player, so its live position wins.
    init(paper: Paper, isLoaded: Bool, playerTime: Double, playerDuration: Double, playerIsPlaying: Bool) {
        position = isLoaded && (playerTime > 0 || playerIsPlaying) ? playerTime : paper.progress
        length = isLoaded && playerDuration > 0 ? playerDuration : paper.duration
        isRead = paper.read
        hasAudio = paper.hasAudio
    }

    /// Listened share of the episode, 0…1.
    var fraction: Double { length > 0 ? min(1, max(0, position / length)) : 0 }

    /// "42%", nil until the length is known.
    var percentLabel: String? { length > 0 ? "\(Int((fraction * 100).rounded()))%" : nil }

    /// Under the bar's left end.
    var elapsedLabel: String { formatT(position) }
    /// Under the bar's right end, as time left.
    var remainingLabel: String { length > 0 ? "−" + formatT(max(0, length - position)) : "–:––" }

    /// The card's big line: what's ready, how long, or how much is left.
    var headline: String {
        if length <= 0 { return hasAudio ? L("Ready to play") : L("Script ready") }
        if isRead && position <= 0.5 { return L("Listened") }
        if position <= 0.5 { return L("{0} min episode", Int((length / 60).rounded())) }
        let left = max(0, length - position)
        return left < 60 ? L("Almost done") : L("{0} min left", Int((left / 60).rounded()))
    }

    /// "Turn 3 of 40" while this paper is loaded and playing a turn.
    static func turnLabel(activeTurn: Int, turnCount: Int) -> String? {
        guard turnCount > 0, activeTurn >= 0 else { return nil }
        return L("Turn {0} of {1}", activeTurn + 1, turnCount)
    }
}
