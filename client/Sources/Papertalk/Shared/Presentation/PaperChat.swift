// Ask: chatting with the LLM about one paper. The chat's messages, the context sent with every
// question (the paper's stored details and its PDF text) and the Ask window's wording.

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

/// What the Ask window shows and what it sends.
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

    /// The conversation as sent to the LLM: failed answers left out.
    static func history(_ messages: [ChatMessage]) -> [ChatMessage] { messages.filter { !$0.isError } }

    /// The typed question, trimmed; nil when there's nothing to send.
    static func question(_ draft: String) -> String? {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    /// Send is enabled: there's a question and no answer is pending.
    static func canSend(_ draft: String, answering: Bool) -> Bool { !answering && question(draft) != nil }

    /// "Ask — Title", the window's title.
    static func windowTitle(_ p: Paper) -> String { L("Ask — {0}", p.displayTitle) }

    static var placeholder: String { L("Ask about this paper…") }
    static var emptyTitle: String { L("Ask about this paper") }
    static var emptyHint: String { L("Answers come from the paper's text and details. Try one of these, or type your own.") }
    static var sendHelp: String { L("Send (Return)") }
    static var clearTitle: String { L("New chat") }
    static var thinking: String { L("Reading the paper…") }

    /// Starter questions shown in an empty chat.
    static var suggestions: [String] {
        [L("Summarize this paper in three sentences."),
         L("What is the main contribution?"),
         L("How does the method work, step by step?"),
         L("What are the limitations?")]
    }

    #if os(macOS)
    /// An answer with its Markdown (bold, italics, code, links) rendered; plain text if it doesn't
    /// parse. macOS only: Foundation on Linux has no Markdown parser.
    static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
    #endif
}
