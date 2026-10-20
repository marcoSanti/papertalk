#if os(macOS)
import SwiftUI

/// Contact-book style browsing of the library by author: an A–Z index keyed
/// on surname, one card per author with their paper covers. Tapping a card
/// opens that author's papers in the library.
struct AuthorsView: View {
    @EnvironmentObject private var store: AppStore

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 16, alignment: .top)]

    var body: some View {
        let sections = AuthorsPresentation.sections(store.papersByAuthor, search: store.search)
        Group {
            if store.authorCounts.isEmpty {
                ContentUnavailableView {
                    Label(L("No authors yet"), systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text(L("Authors appear once a paper's metadata has been extracted."))
                }
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: store.search)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections, id: \.letter) { section in
                                Section {
                                    ForEach(section.entries) { AuthorCard(name: $0.name, papers: $0.papers) }
                                } header: {
                                    sectionHeader(section.letter)
                                }
                                .id(section.letter)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                    .overlay(alignment: .trailing) {
                        if AuthorsPresentation.showsLetterIndex(sectionCount: sections.count) {
                            letterIndex(sections.map(\.letter), proxy: proxy)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground())
        .navigationTitle(L("Authors"))
        .navigationSubtitle(LibraryPresentation.authorsSubtitle(store.authorCounts.count))
    }

    // MARK: pieces

    private func sectionHeader(_ letter: String) -> some View {
        HStack {
            Text(letter)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 30, height: 30)
                .glassEffect(.regular, in: Circle())
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private func letterIndex(_ letters: [String], proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { l in
                Button {
                    withAnimation(.snappy) { proxy.scrollTo(l, anchor: .top) }
                } label: {
                    Text(l)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 18, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Jump to {0}", l))
            }
        }
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .padding(.trailing, 6)
    }
}

// MARK: - Author card

private struct AuthorCard: View {
    @EnvironmentObject private var store: AppStore
    let name: String
    let papers: [Paper]
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        Button {
            store.showAuthor(name)
        } label: {
            VStack(spacing: 10) {
                AuthorAvatar(name: name, size: 52)
                VStack(spacing: 2) {
                    Text(name)
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(LibraryPresentation.paperCount(papers.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                coverStack
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16).padding(.horizontal, 12)
            .background(shape.fill(Color.stable(for: name).opacity(hovering ? 0.14 : 0.07)))
            .overlay(shape.strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.07), lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.snappy(duration: 0.2)) { hovering = h } }
        .help(L("Show {0}’s papers", name))
    }

    /// Up to three of the author's newest paper covers, fanned out.
    private var coverStack: some View {
        let (shown, more) = AuthorsPresentation.coverStack(papers)
        return HStack(spacing: -12) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                PaperArtwork(paper: p)
                    .frame(width: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .rotationEffect(.degrees(shown.count == 1 ? 0 : Double(i - 1) * 6))
                    .zIndex(Double(shown.count - i))
            }
            if more > 0 {
                Text("+\(more)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
        .frame(height: 42)
    }
}

// MARK: - Single-author header (shown above the library when drilled in)

struct AuthorHeader: View {
    @EnvironmentObject private var store: AppStore
    let name: String

    var body: some View {
        let papers = store.papersByAuthor[name] ?? []
        let coauthors = AuthorsPresentation.coauthors(of: name, in: papers)
        HStack(alignment: .top, spacing: 14) {
            AuthorAvatar(name: name, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.title2.weight(.semibold))
                Text(AuthorsPresentation.summary(papers: papers.count, coauthors: coauthors.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !coauthors.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(coauthors.prefix(10), id: \.name) { co, shared in
                            Button {
                                store.showAuthor(co)
                            } label: {
                                HStack(spacing: 5) {
                                    AuthorAvatar(name: co, size: 16)
                                    Text(co).font(.caption.weight(.medium)).lineLimit(1)
                                    if shared > 1 {
                                        Text("\(shared)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                                .glassEffect(.regular.interactive(), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(L("Show {0}’s papers", co))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

}

// MARK: - Avatar + name helpers

/// Round initials avatar (first + last name) in a colour stable per person.
struct AuthorAvatar: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        Text(AuthorName.initials(name))
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.stable(for: name).gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

#endif
