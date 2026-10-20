import Foundation

/// The import sheet's state and rules: the chosen PDF, the depth, its
/// custom description and the summary length. The sheet binds to this and lays it out.
struct ImportForm {
    private(set) var fileName: String?
    private(set) var fileData: Data?
    var depth: Depth = .inDepth
    var depthNote = ""
    /// The summary length slider's value (a Double, as sliders bind to one).
    var summaryMinutes = Double(SummaryLength.defaultMinutes)
    /// The interface language when the sheet opened: an episode can be written in it.
    var appLanguage = Localization.language
    /// Write the episode in `appLanguage` instead of English. Off unless chosen.
    var writeInAppLanguage = false

    /// Only a summary has a length to choose; the other depths run as long as the paper needs.
    var showsLengthSlider: Bool { depth == .summary }
    var lengthLabel: String { SummaryLength.label(SummaryLength.clamped(summaryMinutes)) }
    static let lengthRange = Double(SummaryLength.range.lowerBound)...Double(SummaryLength.range.upperBound)
    static let lengthStep = Double(SummaryLength.step)
    static var lengthMinLabel: String { L("{0} min", SummaryLength.range.lowerBound) }
    static var lengthMaxLabel: String { L("{0} min", SummaryLength.range.upperBound) }
    static var lengthHelp: String { L("The episode is written to fit in this time at the default speaking pace.") }

    var hasFile: Bool { fileData != nil }

    /// Every depth but Direct read needs the LLM.
    var needsLLM: Bool { depth != .direct }

    private var hasDepthNote: Bool { !depthNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// English needs no choice, and Direct read writes nothing.
    var showsLanguageToggle: Bool { appLanguage != .english && needsLLM }
    static var languageToggleTitle: String { L("Write the episode in this language") }
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

    func showsNoLLMWarning(llmBaseURL: String) -> Bool {
        needsLLM && llmBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var fileSizeLabel: String? {
        fileData.map { ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file) }
    }

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
    var fileLabel: String { fileName ?? L("No file chosen") }

    static var heading: String { L("New episode") }
    static var subheading: String { L("Turn a paper into a podcast, converted on {0}.", Device.this) }
    static var noLLMWarning: String { L("No LLM is configured, so this paper will be read out as-is instead of as a discussion.") }

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
    struct ReadError: LocalizedError {
        let name: String
        var errorDescription: String? { L("Could not read {0}", name) }
    }

    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { return try Data(contentsOf: url) } catch { throw ReadError(name: url.lastPathComponent) }
    }
}

/// The Edit metadata sheet: one text field per value, lists one per line.
struct MetadataForm: Equatable {
    var title: String
    var filename: String
    var doi: String
    var authors: String
    var affiliations: String

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

    var authorList: [String] { Self.lines(authors) }
    var affiliationList: [String] { Self.lines(affiliations) }
}
