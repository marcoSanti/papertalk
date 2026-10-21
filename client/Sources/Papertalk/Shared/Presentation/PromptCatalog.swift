// The Query Prompts settings page's catalog: every editable prompt the pipeline sends, with
// when it is used and which {tokens} it is filled with.

import Foundation

/// One editable prompt on the Query Prompts settings page.
struct PromptEntry: Identifiable {
    /// Stable id, used as the page's picker tag.
    let id: String
    /// The picker section it's listed under.
    let group: String
    /// Its name in the picker.
    let title: String
    /// When the pipeline sends it, shown above the editor.
    let usedWhen: String
    /// The {tokens} this prompt is filled with.
    let tokens: [String]
    /// Where its text lives in `PromptSettings`.
    let keyPath: WritableKeyPath<PromptSettings, String>

    /// "Tokens: {host}, {expert}" under the description.
    var tokensLabel: String {
        tokens.isEmpty ? L("No tokens.") : L("Tokens:") + " " + tokens.map { "{\($0)}" }.joined(separator: ", ")
    }

    /// Unchanged from the shipped text (disables Reset).
    func isDefault(_ prompts: PromptSettings) -> Bool {
        prompts[keyPath: keyPath] == PromptSettings.defaults[keyPath: keyPath]
    }

    /// Put the shipped text back.
    func reset(_ prompts: inout PromptSettings) {
        prompts[keyPath: keyPath] = PromptSettings.defaults[keyPath: keyPath]
    }
}

/// Every prompt the pipeline sends, in the order an import uses them.
enum PromptCatalog {
    /// The page's explanation, under its title.
    static var intro: String {
        L("Everything the LLM is asked during an import. The reply formats (JSON schemas and the “Name: line” dialogue layout) are added automatically, so replies stay readable whatever you write here.")
    }
    /// The reset button.
    static var resetTitle: String { L("Reset to default") }

    private static let segmentTokens = ["segmentNumber", "segmentCount", "segmentTitle", "goal", "keyPoints",
                                        "targetWords", "otherSegments", "covered", "recentTurns", "position",
                                        "host", "expert"]

    /// One entry per `PromptSettings` field (a test checks none is missing).
    static var entries: [PromptEntry] { [
        PromptEntry(id: "metadata", group: L("Paper details"), title: L("Metadata"),
                    usedWhen: L("First, to read the title, authors, affiliations, DOI and tags from the paper's text."),
                    tokens: [], keyPath: \.metadata),
        PromptEntry(id: "cast", group: L("Paper details"), title: L("Cast"),
                    usedWhen: L("To propose the interviewer and the interviewed author, with their genders, before you choose the voices."),
                    tokens: [], keyPath: \.cast),
        PromptEntry(id: "outlineSystem", group: L("Planning"), title: L("Editor role"),
                    usedWhen: L("The system prompt of the planning call, which outlines the episode."),
                    tokens: [], keyPath: \.outlineSystem),
        PromptEntry(id: "outlineRules", group: L("Planning"), title: L("Outline rules"),
                    usedWhen: L("When the LLM plans the episode: it breaks the paper into a section index and designs the listening segments before any dialogue is written."),
                    tokens: ["minutes", "minSeg", "maxSeg", "plannedWords", "depthGuide", "host", "expert"],
                    keyPath: \.outlineRules),
        PromptEntry(id: "outlineRepair", group: L("Planning"), title: L("Outline repair"),
                    usedWhen: L("Only when the outline reply couldn't be read, to ask for it again."),
                    tokens: [], keyPath: \.outlineRepair),
        PromptEntry(id: "depthSummary", group: L("Depth"), title: L("Summary"),
                    usedWhen: L("The {depthGuide} of a Summary episode."), tokens: [], keyPath: \.depthSummary),
        PromptEntry(id: "depthInDepth", group: L("Depth"), title: L("In-depth"),
                    usedWhen: L("The {depthGuide} of an In-depth episode (and of Custom with no description)."),
                    tokens: [], keyPath: \.depthInDepth),
        PromptEntry(id: "depthCustom", group: L("Depth"), title: L("Custom"),
                    usedWhen: L("The {depthGuide} of a Custom episode, around the description you typed."),
                    tokens: ["note"], keyPath: \.depthCustom),
        PromptEntry(id: "dialoguePersona", group: L("Dialogue"), title: L("Personas"),
                    usedWhen: L("When the LLM writes the two-speaker dialogue segments: {host} asks the questions, {expert} (the author) carries the technical content."),
                    tokens: ["host", "expert"], keyPath: \.dialoguePersona),
        PromptEntry(id: "writeForEar", group: L("Dialogue"), title: L("Ear style"),
                    usedWhen: L("Added to the personas, so the dialogue reads naturally when spoken by the voices."),
                    tokens: ["host", "expert"], keyPath: \.writeForEar),
        PromptEntry(id: "segmentRequest", group: L("Dialogue"), title: L("Segment request"),
                    usedWhen: L("The request for each dialogue segment. The reply format and the paper's text are added after it."),
                    tokens: segmentTokens, keyPath: \.segmentRequest),
        PromptEntry(id: "lengthLimit", group: L("Dialogue"), title: L("Length limit"),
                    usedWhen: L("Summaries only: added to each segment request, so the episode keeps to the length you chose."),
                    tokens: ["maxWords"], keyPath: \.lengthLimit),
        PromptEntry(id: "condense", group: L("Dialogue"), title: L("Condense"),
                    usedWhen: L("Summaries only: when a segment still comes out too long, to ask for a shorter version. The reply format and the segment are added after it."),
                    tokens: ["targetWords", "host", "expert"], keyPath: \.condense),
        PromptEntry(id: "positionOnly", group: L("Dialogue"), title: L("Position: only segment"),
                    usedWhen: L("The {position} of a segment when the episode has just one."),
                    tokens: ["host", "expert"], keyPath: \.positionOnly),
        PromptEntry(id: "positionFirst", group: L("Dialogue"), title: L("Position: first"),
                    usedWhen: L("The {position} of the episode's first segment."),
                    tokens: ["host", "expert"], keyPath: \.positionFirst),
        PromptEntry(id: "positionMiddle", group: L("Dialogue"), title: L("Position: middle"),
                    usedWhen: L("The {position} of every segment between the first and the last."),
                    tokens: ["host", "expert"], keyPath: \.positionMiddle),
        PromptEntry(id: "positionLast", group: L("Dialogue"), title: L("Position: last"),
                    usedWhen: L("The {position} of the episode's last segment."),
                    tokens: ["host", "expert"], keyPath: \.positionLast),
        PromptEntry(id: "monologuePersona", group: L("Monologue"), title: L("Persona"),
                    usedWhen: L("In-depth only: when the LLM writes a method section as one long spoken monologue by the first author, {expert}."),
                    tokens: ["expert", "host", "position"], keyPath: \.monologuePersona),
        PromptEntry(id: "monologueRules", group: L("Monologue"), title: L("Rules"),
                    usedWhen: L("Added to the monologue persona for each block of the method text."),
                    tokens: ["expert", "host", "position"], keyPath: \.monologueRules),
        PromptEntry(id: "blockOnly", group: L("Monologue"), title: L("Position: only block"),
                    usedWhen: L("The {position} when the method fits in one block."), tokens: [], keyPath: \.blockOnly),
        PromptEntry(id: "blockFirst", group: L("Monologue"), title: L("Position: first block"),
                    usedWhen: L("The {position} of the method's first block."), tokens: [], keyPath: \.blockFirst),
        PromptEntry(id: "blockMiddle", group: L("Monologue"), title: L("Position: middle block"),
                    usedWhen: L("The {position} of every block between the first and the last."), tokens: [], keyPath: \.blockMiddle),
        PromptEntry(id: "blockLast", group: L("Monologue"), title: L("Position: last block"),
                    usedWhen: L("The {position} of the method's last block."), tokens: [], keyPath: \.blockLast),
        PromptEntry(id: "mindMap", group: L("Mind map"), title: L("Mind map"),
                    usedWhen: L("After the script, to map the paper's key concepts under three branches: the problem, the method and the demonstration."),
                    tokens: [], keyPath: \.mindMap),
        PromptEntry(id: "mindMapRetry", group: L("Mind map"), title: L("Mind map retry"),
                    usedWhen: L("Only when a main concept of the mind map came back without at least two parts, to ask again."),
                    tokens: [], keyPath: \.mindMapRetry),
        PromptEntry(id: "outputLanguage", group: L("Language"), title: L("Episode language"),
                    usedWhen: L("Only when an import asks for the episode in the app's language: added to the planning, dialogue, monologue and mind map prompts."),
                    tokens: ["language"], keyPath: \.outputLanguage),
    ] }

    /// The entries by group, in order, for the page's list.
    static var groups: [(name: String, entries: [PromptEntry])] {
        var out: [(name: String, entries: [PromptEntry])] = []
        for e in entries {
            if let i = out.firstIndex(where: { $0.name == e.group }) { out[i].entries.append(e) }
            else { out.append((e.group, [e])) }
        }
        return out
    }

    /// The entry with this id, else the first.
    static func entry(_ id: String) -> PromptEntry { entries.first { $0.id == id } ?? entries[0] }
}
