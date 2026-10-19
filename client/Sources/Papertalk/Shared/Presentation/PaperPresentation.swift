import Foundation

/// How a single paper is described across the library and the details panel.
enum PaperPresentation {
    /// "Ada Lovelace, Grace Hopper, Alan Turing et al." (first three names).
    static func authorLine(_ authors: [String]) -> String {
        authors.count > 3 ? authors.prefix(3).joined(separator: ", ") + " et al." : authors.joined(separator: ", ")
    }

    /// Grid card subtitle: the first author (+ "et al."), else depth or filename.
    static func cardSubtitle(_ p: Paper) -> String {
        if let first = p.authors.first {
            return p.authors.count > 1 ? "\(first) et al." : first
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
    static func coverHelp(_ p: Paper) -> String { p.hasPdf ? "Double-click to open the PDF" : "" }

    /// "3 papers" beside an author in the details panel, only when they have more than this one.
    static func otherPapersLabel(_ count: Int) -> String? { count > 1 ? LibraryPresentation.paperCount(count) : nil }

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
        present ? "\(label) available" : "No \(label.lowercased()) yet"
    }

    // MARK: authors and tags

    static let authorPreviewLimit = 5

    static func visibleAuthors(_ authors: [String], showAll: Bool) -> [String] {
        showAll ? authors : Array(authors.prefix(authorPreviewLimit))
    }

    static func authorsToggleTitle(count: Int, showingAll: Bool) -> String? {
        guard count > authorPreviewLimit else { return nil }
        return showingAll ? "Show fewer" : "Show all \(count) authors"
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

    static func showsConversionCard(_ p: Paper) -> Bool { p.isActive || p.isError }
    static func showsEpisodeCard(_ p: Paper) -> Bool { p.hasScript || p.hasAudio }
    static func isPlayable(_ p: Paper) -> Bool { p.hasScript || p.hasAudio }

    /// Regenerate needs a script, and waits while any conversion runs
    /// (voicing shares the one Kokoro model).
    static func canRegenerateAudio(_ p: Paper, anyConversionRunning: Bool) -> Bool {
        p.hasScript && !anyConversionRunning
    }

    static func canRerun(_ p: Paper) -> Bool { !p.isActive }

    /// A converting paper can be stopped (and deleted) while it runs.
    static func canStop(_ p: Paper) -> Bool { p.isActive }
    static let stopTitle = "Stop conversion"

    /// Rerunning a paper that has an episode replaces it, so it's confirmed first.
    static func rerunNeedsConfirmation(_ p: Paper) -> Bool { p.hasScript || p.hasAudio }

    static func listenedToggle(_ p: Paper) -> (title: String, icon: String) {
        p.read ? ("Mark as unlistened", "circle") : ("Mark as listened", "checkmark.circle")
    }

    static func favoriteToggle(_ p: Paper) -> (title: String, icon: String) {
        p.favorite ? ("Remove from favorites", "star.fill") : ("Add to favorites", "star")
    }

    /// The favourite button in the details panel's action bar.
    static func favoriteButton(_ p: Paper) -> (title: String, icon: String) {
        p.favorite ? ("Favorited", "star.fill") : ("Favorite", "star")
    }

    /// The play button in the details panel's action bar.
    static func playButton(_ p: Paper, isPlaying: Bool) -> (title: String, icon: String) {
        if isPlaying { return ("Pause", "pause.fill") }
        return (p.progress > 1 ? "Resume" : "Play", "play.fill")
    }

    // MARK: status

    static func statusText(_ p: Paper) -> String {
        switch p.statusKind {
        case .running: return p.state == "queued" ? "Queued" : "Converting"
        case .done: return p.read ? "Listened" : "Ready"
        case .error: return "Failed"
        case .unknown: return p.state.isEmpty || p.state == "draft" ? "Not converted" : p.state.capitalized
        }
    }

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
        p.statusError == ConversionPresentation.stoppedMessage ? "Conversion stopped" : "Conversion failed"
    }

    static func failureMessage(_ p: Paper) -> String {
        p.statusError ?? p.message ?? "Something went wrong while converting this paper."
    }
}

/// The conversion checklist shown while a paper converts.
enum ConversionPresentation {
    /// Left on a paper whose conversion was stopped.
    static let stoppedMessage = "Stopped. The script and any voiced sections are kept: Try again continues from there."

    static let stages: [(key: String, label: String)] = [
        ("extract", "Extract text"),
        ("notes", "Summarize"),
        ("outline", "Plan episode"),
        ("segments", "Write dialogue"),
        ("audio", "Synthesize voices"),
        ("finalize", "Finalize"),
    ]

    /// Index of the stage in progress (0 when unknown).
    static func currentStage(_ stage: String?) -> Int {
        stages.firstIndex { $0.key == (stage ?? "") } ?? 0
    }

    enum StageState { case done, current, pending }
    static func state(ofStage index: Int, current: Int) -> StageState {
        index < current ? .done : index == current ? .current : .pending
    }

    /// Progress bar value: never fully empty, so a just-started run shows movement.
    static func barValue(_ progress: Double) -> Double { min(1, max(0.02, progress)) }

    static func percentLabel(_ progress: Double) -> String {
        "\(Int((max(0.02, progress) * 100).rounded()))%"
    }
}

/// Listening progress for the details panel's episode card. Uses the live
/// player position when this paper is the one loaded, else the saved one.
struct EpisodeProgress: Equatable {
    let position: Double
    let length: Double
    let isRead: Bool
    let hasAudio: Bool

    init(paper: Paper, isLoaded: Bool, playerTime: Double, playerDuration: Double, playerIsPlaying: Bool) {
        position = isLoaded && (playerTime > 0 || playerIsPlaying) ? playerTime : paper.progress
        length = isLoaded && playerDuration > 0 ? playerDuration : paper.duration
        isRead = paper.read
        hasAudio = paper.hasAudio
    }

    var fraction: Double { length > 0 ? min(1, max(0, position / length)) : 0 }

    var percentLabel: String? { length > 0 ? "\(Int((fraction * 100).rounded()))%" : nil }

    var elapsedLabel: String { formatT(position) }
    var remainingLabel: String { length > 0 ? "−" + formatT(max(0, length - position)) : "–:––" }

    var headline: String {
        if length <= 0 { return hasAudio ? "Ready to play" : "Script ready" }
        if isRead && position <= 0.5 { return "Listened" }
        if position <= 0.5 { return "\(Int((length / 60).rounded())) min episode" }
        let left = max(0, length - position)
        return left < 60 ? "Almost done" : "\(Int((left / 60).rounded())) min left"
    }

    /// "Turn 3 of 40" while this paper is loaded and playing a turn.
    static func turnLabel(activeTurn: Int, turnCount: Int) -> String? {
        guard turnCount > 0, activeTurn >= 0 else { return nil }
        return "Turn \(activeTurn + 1) of \(turnCount)"
    }
}
