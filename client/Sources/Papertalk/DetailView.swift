import SwiftUI
import AppKit

struct DetailView: View {
    @EnvironmentObject private var store: AppStore
    let paper: Paper
    var onEdit: () -> Void

    @State private var transcript: Transcript?
    @State private var showTranscript = false
    @State private var shownID: String?
    @State private var showLog = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !authors.isEmpty || paper.doi != nil { metaBlock }
                    tagsSection
                    Divider()
                    actions
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LogPane(lines: store.logLines, isOpen: $showLog)
        }
        .navigationTitle(paper.displayTitle)
        .sheet(isPresented: $showTranscript) {
            if let t = transcript {
                TranscriptView(transcript: t, title: paper.displayTitle)
            }
        }
        .onAppear { load(paper) }
        .onChange(of: paper.id) { _ in load(paper) }
    }

    private func load(_ p: Paper) {
        guard shownID != p.id else { return }
        shownID = p.id
        transcript = nil
        Task {
            transcript = await store.transcript(for: p.id)
            await store.prepareAudio(for: p.id)
        }
    }

    // MARK: sections
    private var authors: [String] { paper.authors }
    private var affils: [String] { paper.affiliations }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paper").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                TextField("Untitled", text: Binding(
                    get: { paper.displayTitle },
                    set: { store.saveTitle(paper.id, $0) }))
                    .textFieldStyle(.plain)
                    .font(.title2).fontWeight(.semibold)
                if let d = paper.depthTitle {
                    Text(d).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer()
                starButton
                editButton
            }
            HStack(spacing: 8) {
                Text(paper.filename ?? "—").font(.caption).foregroundStyle(.secondary)
                if let iso = paper.createdIso { Text("· " + formatDate(iso)).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var starButton: some View {
        Button {
            store.toggleFavorite(paper.id)
        } label: {
            Image(systemName: paper.favorite ? "star.fill" : "star")
                .foregroundStyle(paper.favorite ? .yellow : .secondary)
                .font(.title3)
        }
        .buttonStyle(.plain)
        .help(paper.favorite ? "Remove from favorites" : "Add to favorites")
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil").font(.title3).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Edit metadata")
    }

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !authors.isEmpty {
                Text(authors.joined(separator: " · ")).font(.callout)
            }
            if !affils.isEmpty {
                Text(affils.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            }
            if !paper.doi.isEmpty {
                Link("DOI: \(paper.doi)", destination: URL(string: "https://doi.org/\(paper.doi)")!)
                    .font(.callout)
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tags").font(.headline)
                Spacer()
            }
            if paper.tags.isEmpty {
                Text("No tags").font(.subheadline).foregroundStyle(.secondary)
            } else {
                FlowTags(tags: paper.tags) { tag in
                    store.removeTag(paper.id, tag)
                }
            }
            TagEntryField { store.addTag(paper.id, $0) }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    openPDF()
                } label: { Label("PDF", systemImage: "doc").frame(maxWidth: .infinity) }
                .disabled(!paper.hasPdf)
                Button {
                    if transcript == nil {
                        Task { transcript = await store.transcript(for: paper.id) }
                    }
                    showTranscript = true
                } label: { Label("Transcript", systemImage: "text.quote").frame(maxWidth: .infinity) }
                .disabled(!paper.hasScript)
            }
            HStack(spacing: 8) {
                Button {
                    store.regenerateAudio(paper.id)
                } label: { Label("Regenerate audio", systemImage: "waveform.badge.magnifyingglass").frame(maxWidth: .infinity) }
                .disabled(!paper.hasScript || store.activeRun != nil)
                Button {
                    store.rerun(paper.id)
                } label: { Label("Rerun", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity) }
            }
            HStack(spacing: 8) {
                Button {
                    store.refreshMeta(paper.id)
                } label: { Label("Metadata", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                Button(role: .destructive) {
                    store.delete(paper.id)
                } label: { Label("Delete", systemImage: "trash").frame(maxWidth: .infinity) }
            }
        }
        .buttonStyle(.bordered)
        .foregroundStyle(.primary)
    }

    private func openPDF() {
        Task {
            if let data = await store.pdfData(for: paper.id) {
                PDFViewerWindow.present(data: data, title: paper.displayTitle)
            }
        }
    }
}

// MARK: - helpers
func stageLabel(_ stage: String) -> String {
    switch stage {
    case "extract": return "Extracting text from PDF"
    case "notes": return "Summarizing paper"
    case "outline": return "Planning episode"
    case "segments": return "Writing dialogue"
    case "audio": return "Synthesizing audio"
    case "finalize": return "Finalizing"
    default: return stage.isEmpty ? "Processing…" : stage.capitalized + "…"
    }
}

private func formatDate(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: iso) {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        return df.string(from: d)
    }
    return ""
}

/// Minimal tag-entry field that submits on return.
private struct TagEntryField: View {
    var onAdd: (String) -> Void
    @State private var text = ""
    var body: some View {
        HStack {
            TextField("Add a tag…", text: $text)
                .textFieldStyle(.plain)
                .frame(maxWidth: 160)
            Button {
                submit()
            } label: { Text("Add") }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .onSubmit { submit() }
    }
    private func submit() {
        let t = text
        onAdd(t)
        text = ""
    }
}