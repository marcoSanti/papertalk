import SwiftUI

/// Contact-book style browsing of the library by author: an A–Z index keyed
/// on surname, one card per author with their paper covers. Tapping a card
/// opens that author's papers in the library.
struct AuthorsView: View {
    @EnvironmentObject private var store: AppStore

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 16, alignment: .top)]

    private struct Entry: Identifiable {
        let name: String
        let papers: [Paper]
        var id: String { name }
    }

    var body: some View {
        let sections = groupedEntries()
        Group {
            if store.authorCounts.isEmpty {
                ContentUnavailableView {
                    Label("No authors yet", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Authors appear once a paper's metadata has been extracted.")
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
                        if sections.count > 4 {
                            letterIndex(sections.map(\.letter), proxy: proxy)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackground())
        .navigationTitle("Authors")
        .navigationSubtitle(store.authorCounts.isEmpty ? "" : subtitle(store.authorCounts.count))
    }

    private func subtitle(_ n: Int) -> String { n == 1 ? "1 author" : "\(n) authors" }

    // MARK: grouping

    /// Authors matching the search, grouped A–Z by surname.
    private func groupedEntries() -> [(letter: String, entries: [Entry])] {
        let q = store.search.trimmingCharacters(in: .whitespaces).lowercased()
        let byAuthor = store.papersByAuthor
        let entries = byAuthor.keys
            .filter { q.isEmpty || q.hasPrefix("#") || $0.lowercased().contains(q) }
            .sorted { AuthorName.sortKey($0).localizedCompare(AuthorName.sortKey($1)) == .orderedAscending }
            .map { Entry(name: $0, papers: byAuthor[$0] ?? []) }
        var out: [(letter: String, entries: [Entry])] = []
        for e in entries {
            let letter = AuthorName.indexLetter(e.name)
            if out.last?.letter == letter { out[out.count - 1].entries.append(e) }
            else { out.append((letter, [e])) }
        }
        return out
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
                .help("Jump to \(l)")
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
                    Text(papers.count == 1 ? "1 paper" : "\(papers.count) papers")
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
        .help("Show \(name)’s papers")
    }

    /// Up to three of the author's newest paper covers, fanned out.
    private var coverStack: some View {
        let shown = papers.prefix(3)
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
            if papers.count > shown.count {
                Text("+\(papers.count - shown.count)")
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
        let coauthors = coauthorCounts(papers)
        HStack(alignment: .top, spacing: 14) {
            AuthorAvatar(name: name, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.title2.weight(.semibold))
                Text(summary(papers.count, coauthors.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !coauthors.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(coauthors.prefix(10), id: \.0) { co, shared in
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
                            .help("Show \(co)’s papers")
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

    private func summary(_ papers: Int, _ coauthors: Int) -> String {
        let p = papers == 1 ? "1 paper" : "\(papers) papers"
        guard coauthors > 0 else { return p }
        return p + " · " + (coauthors == 1 ? "1 co-author" : "\(coauthors) co-authors")
    }

    /// Co-authors ranked by how many papers they share with this author.
    private func coauthorCounts(_ papers: [Paper]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for p in papers {
            for a in Set(p.authors.map(AuthorName.clean)) where !a.isEmpty && a != name {
                counts[a, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    }
}

// MARK: - Avatar + name helpers

/// Round initials avatar (first + last name) in a colour stable per person.
struct AuthorAvatar: View {
    let name: String
    var size: CGFloat = 24

    private var initials: String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.count > 1 ? (parts.last?.first.map(String.init) ?? "") : ""
        return (first + last).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.stable(for: name).gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

enum AuthorName {
    static func clean(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "Ada Lovelace" sorts as "Lovelace Ada", like a contact book.
    static func sortKey(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let last = parts.last else { return name }
        return last + " " + parts.dropLast().joined(separator: " ")
    }

    static func indexLetter(_ name: String) -> String {
        let c = sortKey(name).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).first
        guard let c, c.isLetter else { return "#" }
        return String(c).uppercased()
    }
}
