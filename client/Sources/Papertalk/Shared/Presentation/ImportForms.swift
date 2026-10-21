// Form state for the sheets that create or edit a paper: the import sheet (`ImportForm`),
// reading the chosen PDF (`PDFFile`) and the Edit paper sheet (`MetadataForm`).

import Foundation

/// The import sheet's state and rules: the chosen PDF, the depth, its
/// custom description and the summary length. The sheet binds to this and lays it out.
struct ImportForm {
    private(set) var fileName: String?
    private(set) var fileData: Data?
    /// How the episode is written (see `Depth`).
    var depth: Depth = .inDepth
    /// Custom only: the instructions sent as the depth guide.
    var depthNote = ""
    /// The summary length slider's value (a Double, as sliders bind to one).
    var summaryMinutes = Double(SummaryLength.defaultMinutes)
    /// The interface language when the sheet opened: an episode can be written in it.
    var appLanguage = Localization.language
    /// Write the episode in `appLanguage` instead of English. Off unless chosen.
    var writeInAppLanguage = false

    /// Only a summary has a length to choose; the other depths run as long as the paper needs.
    var showsLengthSlider: Bool { depth == .summary }
    /// "Up to 35 minutes", beside the slider.
    var lengthLabel: String { SummaryLength.label(SummaryLength.clamped(summaryMinutes)) }
    /// The slider's bounds, as the Double a Slider binds to.
    static let lengthRange = Double(SummaryLength.range.lowerBound)...Double(SummaryLength.range.upperBound)
    /// The slider snaps to whole steps of this many minutes.
    static let lengthStep = Double(SummaryLength.step)
    /// Under the slider's left end.
    static var lengthMinLabel: String { L("{0} min", SummaryLength.range.lowerBound) }
    /// Under the slider's right end.
    static var lengthMaxLabel: String { L("{0} min", SummaryLength.range.upperBound) }
    /// The length slider's tooltip.
    static var lengthHelp: String { L("The episode is written to fit in this time at the default speaking pace.") }

    /// A PDF has been chosen or dropped.
    var hasFile: Bool { fileData != nil }

    /// Every depth but Direct read needs the LLM.
    var needsLLM: Bool { depth != .direct }

    private var hasDepthNote: Bool { !depthNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// English needs no choice, and Direct read writes nothing.
    var showsLanguageToggle: Bool { appLanguage != .english && needsLLM }
    /// The toggle's label; each language names itself ("Scrivi l'episodio in italiano").
    static var languageToggleTitle: String { L("Write the episode in this language") }
    /// Under the toggle: off is the default, and why it's experimental.
    static var languageToggleHelp: String {
        L("Experimental. Off, the script, transcript and mind map are written in English. The voices are English Kokoro voices, so they read other languages with an English accent.")
    }

    /// The language the LLM writes in: English unless the toggle asks for the app's.
    var scriptLanguage: AppLanguage { showsLanguageToggle && writeInAppLanguage ? appLanguage : .english }

    /// A file, and for Custom a description of what's wanted.
    var canStart: Bool { hasFile && (depth != .custom || hasDepthNote) }

    /// Why Start is disabled ("" when it isn't).
    var startHelp: String {
        if canStart { return "" }
        return hasFile ? L("Describe the depth you want first") : L("Choose a PDF first")
    }

    /// Only a non-empty custom description can be saved as a preset.
    var canSavePreset: Bool { hasDepthNote }

    /// Without an LLM the paper is read out as-is; say so before Start, unless that was the choice anyway.
    func showsNoLLMWarning(llmBaseURL: String) -> Bool {
        needsLLM && llmBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// "1.2 MB" under the file name.
    var fileSizeLabel: String? {
        fileData.map { ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file) }
    }

    /// Take the chosen PDF (already read by `PDFFile.read`).
    mutating func setFile(name: String, data: Data) {
        fileName = name
        fileData = data
    }

    /// What `AppStore.upload` needs, once the form is complete.
    var submission: (data: Data, filename: String, depth: Depth, depthNote: String, targetMinutes: Int?,
                     scriptLanguage: AppLanguage)? {
        guard canStart, let fileData, let fileName else { return nil }
        return (fileData, fileName, depth, depthNote, showsLengthSlider ? SummaryLength.clamped(summaryMinutes) : nil,
                scriptLanguage)
    }

    /// The file button and the label beside it.
    var chooseButtonTitle: String { hasFile ? L("Change…") : L("Choose PDF…") }
    /// The chosen file's name, or a placeholder.
    var fileLabel: String { fileName ?? L("No file chosen") }

    /// The sheet's title.
    static var heading: String { L("New episode") }
    /// Under the title.
    static var subheading: String { L("Turn a paper into a podcast, converted on {0}.", Device.this) }
    /// Shown when `showsNoLLMWarning` is true.
    static var noLLMWarning: String { L("No LLM is configured, so this paper will be read out as-is instead of as a discussion.") }

    /// SF Symbol beside each depth choice.
    static func icon(for depth: Depth) -> String {
        switch depth {
        case .inDepth: return "books.vertical"
        case .summary: return "text.append"
        case .custom: return "slider.horizontal.3"
        case .direct: return "text.quote"
        }
    }
}

/// Reading a PDF the user picked or dropped (sandbox-scoped URLs included).
enum PDFFile {
    /// Shown when the file can't be read, naming it.
    struct ReadError: LocalizedError {
        let name: String
        var errorDescription: String? { L("Could not read {0}", name) }
    }

    /// The file's bytes, entering its security scope first (a file picked in a sandboxed panel).
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { return try Data(contentsOf: url) } catch { throw ReadError(name: url.lastPathComponent) }
    }
}

/// The Edit metadata sheet: one text field per value, lists one per line.
struct MetadataForm: Equatable {
    /// The paper's title.
    var title: String
    /// The library list name.
    var filename: String
    /// Bare DOI, e.g. 10.1000/xyz.
    var doi: String
    /// One author per line.
    var authors: String
    /// One affiliation per line.
    var affiliations: String

    /// The form filled from `p`.
    init(_ p: Paper) {
        title = p.title ?? ""
        filename = p.filename ?? ""
        doi = p.doi
        authors = p.authors.joined(separator: "\n")
        affiliations = p.affiliations.joined(separator: "\n")
    }

    /// Non-empty, trimmed lines.
    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The authors to save.
    var authorList: [String] { Self.lines(authors) }
    /// The affiliations to save.
    var affiliationList: [String] { Self.lines(affiliations) }
}
