import Foundation

/// One editable prompt on the Query Prompts settings page.
struct PromptEntry: Identifiable {
    let id: String
    let group: String
    let title: String
    let usedWhen: String
    /// The {tokens} this prompt is filled with.
    let tokens: [String]
    let keyPath: WritableKeyPath<PromptSettings, String>

    var tokensLabel: String {
        tokens.isEmpty ? "No tokens." : "Tokens: " + tokens.map { "{\($0)}" }.joined(separator: ", ")
    }

    func isDefault(_ prompts: PromptSettings) -> Bool {
        prompts[keyPath: keyPath] == PromptSettings.defaults[keyPath: keyPath]
    }

    func reset(_ prompts: inout PromptSettings) {
        prompts[keyPath: keyPath] = PromptSettings.defaults[keyPath: keyPath]
    }
}

/// Every prompt the pipeline sends, in the order an import uses them.
enum PromptCatalog {
    static let intro = "Everything the LLM is asked during an import. The reply formats (JSON schemas and the "
        + "“Name: line” dialogue layout) are added automatically, so replies stay readable whatever you write here."
    static let resetTitle = "Reset to default"

    private static let segmentTokens = ["segmentNumber", "segmentCount", "segmentTitle", "goal", "keyPoints",
                                        "targetWords", "otherSegments", "covered", "recentTurns", "position",
                                        "host", "expert"]

    static let entries: [PromptEntry] = [
        PromptEntry(id: "metadata", group: "Paper details", title: "Metadata",
                    usedWhen: "First, to read the title, authors, affiliations, DOI and tags from the paper's text.",
                    tokens: [], keyPath: \.metadata),
        PromptEntry(id: "cast", group: "Paper details", title: "Cast",
                    usedWhen: "To propose the interviewer and the interviewed author, with their genders, before you choose the voices.",
                    tokens: [], keyPath: \.cast),
        PromptEntry(id: "outlineSystem", group: "Planning", title: "Editor role",
                    usedWhen: "The system prompt of the planning call, which outlines the episode.",
                    tokens: [], keyPath: \.outlineSystem),
        PromptEntry(id: "outlineRules", group: "Planning", title: "Outline rules",
                    usedWhen: "When the LLM plans the episode: it breaks the paper into a section index and designs the listening segments before any dialogue is written.",
                    tokens: ["minutes", "minSeg", "maxSeg", "plannedWords", "depthGuide", "host", "expert"],
                    keyPath: \.outlineRules),
        PromptEntry(id: "outlineRepair", group: "Planning", title: "Outline repair",
                    usedWhen: "Only when the outline reply couldn't be read, to ask for it again.",
                    tokens: [], keyPath: \.outlineRepair),
        PromptEntry(id: "depthSummary", group: "Depth", title: "Summary",
                    usedWhen: "The {depthGuide} of a Summary episode.", tokens: [], keyPath: \.depthSummary),
        PromptEntry(id: "depthInDepth", group: "Depth", title: "In-depth",
                    usedWhen: "The {depthGuide} of an In-depth episode (and of Custom with no description).",
                    tokens: [], keyPath: \.depthInDepth),
        PromptEntry(id: "depthCustom", group: "Depth", title: "Custom",
                    usedWhen: "The {depthGuide} of a Custom episode, around the description you typed.",
                    tokens: ["note"], keyPath: \.depthCustom),
        PromptEntry(id: "dialoguePersona", group: "Dialogue", title: "Personas",
                    usedWhen: "When the LLM writes the two-speaker dialogue segments: {host} asks the questions, {expert} (the author) carries the technical content.",
                    tokens: ["host", "expert"], keyPath: \.dialoguePersona),
        PromptEntry(id: "writeForEar", group: "Dialogue", title: "Ear style",
                    usedWhen: "Added to the personas, so the dialogue reads naturally when spoken by the voices.",
                    tokens: ["host", "expert"], keyPath: \.writeForEar),
        PromptEntry(id: "segmentRequest", group: "Dialogue", title: "Segment request",
                    usedWhen: "The request for each dialogue segment. The reply format and the paper's text are added after it.",
                    tokens: segmentTokens, keyPath: \.segmentRequest),
        PromptEntry(id: "positionOnly", group: "Dialogue", title: "Position: only segment",
                    usedWhen: "The {position} of a segment when the episode has just one.",
                    tokens: ["host", "expert"], keyPath: \.positionOnly),
        PromptEntry(id: "positionFirst", group: "Dialogue", title: "Position: first",
                    usedWhen: "The {position} of the episode's first segment.",
                    tokens: ["host", "expert"], keyPath: \.positionFirst),
        PromptEntry(id: "positionMiddle", group: "Dialogue", title: "Position: middle",
                    usedWhen: "The {position} of every segment between the first and the last.",
                    tokens: ["host", "expert"], keyPath: \.positionMiddle),
        PromptEntry(id: "positionLast", group: "Dialogue", title: "Position: last",
                    usedWhen: "The {position} of the episode's last segment.",
                    tokens: ["host", "expert"], keyPath: \.positionLast),
        PromptEntry(id: "monologuePersona", group: "Monologue", title: "Persona",
                    usedWhen: "In-depth only: when the LLM writes a method section as one long spoken monologue by the first author, {expert}.",
                    tokens: ["expert", "host", "position"], keyPath: \.monologuePersona),
        PromptEntry(id: "monologueRules", group: "Monologue", title: "Rules",
                    usedWhen: "Added to the monologue persona for each block of the method text.",
                    tokens: ["expert", "host", "position"], keyPath: \.monologueRules),
        PromptEntry(id: "blockOnly", group: "Monologue", title: "Position: only block",
                    usedWhen: "The {position} when the method fits in one block.", tokens: [], keyPath: \.blockOnly),
        PromptEntry(id: "blockFirst", group: "Monologue", title: "Position: first block",
                    usedWhen: "The {position} of the method's first block.", tokens: [], keyPath: \.blockFirst),
        PromptEntry(id: "blockMiddle", group: "Monologue", title: "Position: middle block",
                    usedWhen: "The {position} of every block between the first and the last.", tokens: [], keyPath: \.blockMiddle),
        PromptEntry(id: "blockLast", group: "Monologue", title: "Position: last block",
                    usedWhen: "The {position} of the method's last block.", tokens: [], keyPath: \.blockLast),
    ]

    /// The entries by group, in order, for the page's list.
    static var groups: [(name: String, entries: [PromptEntry])] {
        var out: [(name: String, entries: [PromptEntry])] = []
        for e in entries {
            if let i = out.firstIndex(where: { $0.name == e.group }) { out[i].entries.append(e) }
            else { out.append((e.group, [e])) }
        }
        return out
    }

    static func entry(_ id: String) -> PromptEntry { entries.first { $0.id == id } ?? entries[0] }
}
