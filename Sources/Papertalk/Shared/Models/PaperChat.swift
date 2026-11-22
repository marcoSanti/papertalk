// Ask: chatting with the LLM about one paper. The chat's messages and what is sent with every
// question: the paper's stored details, its PDF text and how to cite it.

import Foundation

/// One message in a paper's Ask chat.
struct ChatMessage: Identifiable, Equatable {
    /// Who wrote it; the raw value is the chat API's role.
    enum Role: String { case user, assistant }

    let id = UUID()
    var role: Role
    var text: String
    /// An answer that failed: shown in the chat with why, never sent back to the LLM.
    var isError = false

    /// A failed answer saying why.
    static func failure(_ message: String) -> ChatMessage { ChatMessage(role: .assistant, text: message, isError: true) }
}

/// What Ask sends.
enum PaperChat {
    /// The most PDF text sent with a question: about 30k tokens, so it fits most models' context.
    static let maxTextCharacters = 120_000

    /// The paper's details, then its text (cut at `maxTextCharacters`), for the system prompt.
    static func context(for p: Paper, text: String) -> String {
        let details: [(String, String)] = [
            ("Title", p.displayTitle),
            ("Authors", p.authors.joined(separator: ", ")),
            ("Affiliations", p.affiliations.joined(separator: "; ")),
            ("Published", p.publishedIso ?? ""),
            ("DOI", p.doi),
            ("Topics", p.tags.joined(separator: ", ")),
        ]
        let lines = details.filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = body.count > maxTextCharacters ? "\n[The text is cut here.]" : ""
        return "PAPER DETAILS\n" + lines.joined(separator: "\n")
            + "\n\nPAPER TEXT\n" + String(body.prefix(maxTextCharacters)) + cut
    }

    /// Each page's text after a "[Page N]" line, so answers can cite where a fact is stated.
    static func pagedText(_ pages: [String]) -> String {
        pages.enumerated().map { "[Page \($0.offset + 1)]\n\($0.element)" }.joined(separator: "\n")
    }

    /// How answers cite the paper, added after the (editable) Ask prompt so links keep working
    /// whatever the prompt says.
    static let citationRule = """
        CITATIONS
        After each statement that comes from the paper, cite where the paper says it, in exactly this form: [[p. 3: "a short quote"]]. The number is the page from the [Page N] lines of the text; the quote is 4 to 12 words copied exactly from that page, without changes. Cite only what is in the text.
        """

    /// A place in the paper an answer cites: a page (from 1) and words copied from it.
    struct Citation: Hashable, Identifiable {
        var page: Int
        var quote: String
        var id: Self { self }
    }

    /// The conversation as sent to the LLM: failed answers left out.
    static func history(_ messages: [ChatMessage]) -> [ChatMessage] { messages.filter { !$0.isError } }

    /// The typed question, trimmed; nil when there's nothing to send.
    static func question(_ draft: String) -> String? {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }
}
