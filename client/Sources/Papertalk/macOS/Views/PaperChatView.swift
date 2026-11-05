// The Ask window's content: a chat with the LLM about one paper, styled like a messaging app.

#if os(macOS)
import SwiftUI

/// The paper's header, the conversation (or starter questions when it's empty) and the composer.
struct PaperChatView: View {
    @EnvironmentObject private var store: AppStore
    let paperId: String
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var messages: [ChatMessage] { store.chats[paperId] ?? [] }
    private var isAnswering: Bool { store.answering.contains(paperId) }

    var body: some View {
        Group {
            if let paper = store.papers[paperId] {
                VStack(spacing: 0) {
                    header(paper)
                    Divider()
                    if messages.isEmpty { emptyState } else { conversation }
                    composer
                }
                .onAppear {
                    PaperChatWindow.setTitle(PaperChat.windowTitle(paper), paperId: paperId)
                    composerFocused = true
                }
                .onChange(of: paper.displayTitle) { _, _ in
                    PaperChatWindow.setTitle(PaperChat.windowTitle(paper), paperId: paperId)
                }
            }
        }
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(.background)
        .tint(Color.appAccent)
        .onChange(of: store.papers[paperId] == nil) { _, gone in
            if gone { PaperChatWindow.close(paperId: paperId) }
        }
    }

    // MARK: - Header

    /// The cover, title and authors, with New chat.
    private func header(_ paper: Paper) -> some View {
        HStack(spacing: 12) {
            PaperArtwork(paper: paper)
                .frame(width: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(paper.displayTitle).font(.headline).lineLimit(1)
                Text(PaperPresentation.authorLine(paper.authors))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { store.clearChat(paperId) } label: {
                Label(PaperChat.clearTitle, systemImage: "square.and.pencil")
            }
            .buttonStyle(.glass)
            .disabled(messages.isEmpty || isAnswering)
            .help(PaperChat.clearTitle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Messages

    /// The messages, newest at the bottom, scrolled down as answers arrive.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(messages) { MessageRow(message: $0).id($0.id) }
                    if isAnswering { TypingBubble().id("typing") }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in scrollDown(proxy) }
            .onChange(of: isAnswering) { _, _ in scrollDown(proxy) }
        }
    }

    /// Scroll to the typing bubble or the last message.
    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy) {
            if isAnswering { proxy.scrollTo("typing", anchor: .bottom) }
            else if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    /// An empty chat: what Ask does, and starter questions that send at a click.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.aiGradient)
                .symbolEffect(.breathe, options: .repeating)
                .background {
                    Circle().fill(Theme.aiGradient).frame(width: 90, height: 90).blur(radius: 30).opacity(0.35)
                }
                .padding(.bottom, 4)
            Text(PaperChat.emptyTitle).font(.title2.weight(.semibold)).foregroundStyle(Theme.aiGradient)
            Text(PaperChat.emptyHint)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            VStack(spacing: 8) {
                ForEach(PaperChat.suggestions, id: \.self) { suggestion in
                    SuggestionChip(text: suggestion) { send(suggestion) }
                }
            }
            .frame(maxWidth: 380)
            .padding(.top, 6)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    /// The question field and Send. Return sends; Option-Return starts a new line.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(PaperChat.placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit { send(draft) }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(Glass.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.aiGradient, lineWidth: 1)
                        .opacity(composerFocused ? 0.8 : 0.25)
                        .animation(.snappy, value: composerFocused)
                }
            let enabled = PaperChat.canSend(draft, answering: isAnswering)
            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Theme.aiGradient, in: Circle())
                    .glassEffect(Glass.clear.interactive(), in: Circle())
                    .shadow(color: Theme.aiGlow.opacity(enabled ? 0.45 : 0), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(PaperChat.sendHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Send `text` (the draft or a starter question) and clear the field.
    private func send(_ text: String) {
        guard PaperChat.canSend(text, answering: isAnswering) else { return }
        draft = ""
        Task { await store.ask(paperId, text) }
    }
}

/// One message: the reader's on the right in an accent bubble, the LLM's on the left beside its
/// avatar, a failed answer tinted red with why.
private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    // A faint wash and edge, not a solid fill: the text stays the normal colour and readable.
                    .background(Theme.aiGradient.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.aiGradient, lineWidth: 1).opacity(0.45)
                    }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Avatar(error: message.isError)
                Group {
                    if message.isError {
                        Label(message.text, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Text(PaperChat.formatted(message.text))
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(message.isError ? AnyShapeStyle(Color.red.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 60)
            }
        }
    }
}

/// A starter question: a sparkle, the question and an arrow, on a faint AI-gradient wash with a
/// gradient edge that brightens on hover.
private struct SuggestionChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.aiGradient)
                Text(text).font(.callout).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.aiGradient.opacity(hovering ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.aiGradient, lineWidth: 1)
                    .opacity(hovering ? 0.9 : 0.4)
            }
            .shadow(color: Theme.aiGlow.opacity(hovering ? 0.25 : 0), radius: 10, y: 3)
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
    }
}

/// The LLM's round avatar beside its messages.
private struct Avatar: View {
    var error = false

    var body: some View {
        Image(systemName: error ? "exclamationmark" : "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(error ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.aiGradient), in: Circle())
            .shadow(color: (error ? Color.red : Theme.aiGlow).opacity(0.35), radius: 6, y: 2)
    }
}

/// Three pulsing dots in an LLM bubble while the answer is written.
private struct TypingBubble: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar()
            HStack(spacing: 8) {
                PhaseAnimator([0, 1, 2]) { phase in
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().fill(Theme.aiGradient).frame(width: 7, height: 7).opacity(i == phase ? 1 : 0.3)
                        }
                    }
                } animation: { _ in .easeInOut(duration: 0.35) }
                Text(PaperChat.thinking).font(.callout)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 60)
        }
    }
}

#endif
