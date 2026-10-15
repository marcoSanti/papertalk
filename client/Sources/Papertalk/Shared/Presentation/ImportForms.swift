import Foundation

/// The import sheet's state and rules: the chosen PDF, the depth and its
/// custom description. The sheet binds to this and lays it out.
struct ImportForm {
    private(set) var fileName: String?
    private(set) var fileData: Data?
    var depth: Depth = .inDepth
    var depthNote = ""

    var hasFile: Bool { fileData != nil }

    /// Every depth but Direct read needs the LLM.
    var needsLLM: Bool { depth != .direct }

    private var hasDepthNote: Bool { !depthNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A file, and for Custom a description of what's wanted.
    var canStart: Bool { hasFile && (depth != .custom || hasDepthNote) }

    /// Why Start is disabled ("" when it isn't).
    var startHelp: String {
        if canStart { return "" }
        return hasFile ? "Describe the depth you want first" : "Choose a PDF first"
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
    var submission: (data: Data, filename: String, depth: Depth, depthNote: String)? {
        guard canStart, let fileData, let fileName else { return nil }
        return (fileData, fileName, depth, depthNote)
    }

    /// The file button and the label beside it.
    var chooseButtonTitle: String { hasFile ? "Change…" : "Choose PDF…" }
    var fileLabel: String { fileName ?? "No file chosen" }

    static let heading = "New episode"
    static let subheading = "Turn a paper into a podcast, converted on \(Device.this)."
    static let noLLMWarning = "No LLM is configured, so this paper will be read out as-is instead of as a discussion."

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
        var errorDescription: String? { "Could not read \(name)" }
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
