// The Suggested section of the main window: a tab per source with Check Now, the paper being
// fetched, one row per suggested paper, and the details panel that shows the picked one's abstract.

#if os(macOS)
import SwiftUI

/// The main pane while Suggested is picked in the sidebar. Wording and decisions come from
/// `SuggestionsPresentation`; actions go to the store.
struct SuggestionsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab: Suggestion.Source = .semanticScholar

    var body: some View {
        let shown = SuggestionsPresentation.pending(store.suggestionLog.pending, in: tab)
        Group {
            if !shown.isEmpty {
                List(shown, selection: $store.selectedSuggestionId) { s in
                    SuggestionRow(suggestion: s)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else if SuggestionsPresentation.showsAlertSetup(tab: tab, ready: store.alertsReady) {
                alertSetup
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 10) {
                header
                if let fetch = store.paperFetch { FetchCard(fetch: fetch) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(AmbientBackground())
        .navigationTitle(SuggestionsPresentation.windowTitle)
        .navigationSubtitle(SuggestionsPresentation.lastChecked(store.suggestionLog.lastCheckIso))
        .onChange(of: tab) { store.selectedSuggestionId = nil }
    }

    /// The source tabs, the last check's result, and Check Now, on one glass bar. The daily
    /// switch and the import depth live in Settings → Suggested Papers.
    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(SuggestionsPresentation.tabs, id: \.self) { t in
                    Text(SuggestionsPresentation.tabLabel(t, count: SuggestionsPresentation.pending(store.suggestionLog.pending, in: t).count))
                        .tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let status = store.suggestionsStatus {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                Task { await store.checkSuggestions() }
            } label: {
                Label(SuggestionsPresentation.checkButton(checking: store.isCheckingSuggestions),
                      systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .disabled(!SuggestionsPresentation.canCheck(checking: store.isCheckingSuggestions))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }

    /// The Google Scholar tab before alerts are read: what they add, and the way to Settings.
    private var alertSetup: some View {
        ContentUnavailableView {
            Label(SuggestionsPresentation.alertsNotSetUpTitle, systemImage: "envelope")
        } description: {
            Text(SuggestionsPresentation.alertsNotSetUpMessage)
        } actions: {
            Button(SuggestionsPresentation.setUpAlertsButton) { store.openSettings(.suggestions) }
                .buttonStyle(.glassProminent)
                .help(SuggestionsPresentation.setUpAlertsHelp)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(SuggestionsPresentation.emptyTitle, systemImage: "sparkles")
        } description: {
            VStack(spacing: 8) {
                Text(SuggestionsPresentation.emptyMessage(enabled: store.suggestionsEnabled))
                Text(SuggestionsPresentation.enableHelp).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One suggested paper (its tab names the source): title, byline, the LLM's reason, how the PDF arrives, and its actions.
private struct SuggestionRow: View {
    @EnvironmentObject private var store: AppStore
    let suggestion: Suggestion

    var body: some View {
        let state = SuggestionsPresentation.rowState(suggestion.id, fetch: store.paperFetch)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(Color.appAccent)
                .frame(width: 34, height: 44)
                .background(Color.appAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(SuggestionsPresentation.details(suggestion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let why = suggestion.reason {
                    Label(why, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            AvailabilityBadge(suggestion: suggestion)
            if let status = SuggestionsPresentation.rowStatus(state) {
                Text(status).font(.caption).foregroundStyle(.secondary)
            } else {
                SuggestionImportButton(id: suggestion.id) { Text(SuggestionsPresentation.importButton) }
                    .buttonStyle(.glassProminent)
                    .help(SuggestionsPresentation.importHelp)
                Button(SuggestionsPresentation.dismissButton) { store.dismissSuggestions([suggestion.id]) }
                    .buttonStyle(.glass)
                    .help(SuggestionsPresentation.dismissHelp)
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            SuggestionImportButton(id: suggestion.id) { Text(SuggestionsPresentation.importButton) }
                .disabled(!SuggestionsPresentation.canAct(state))
            Button(SuggestionsPresentation.openPageButton) { store.openPage(of: suggestion) }
                .disabled(!SuggestionsPresentation.canOpenPage(suggestion))
            Divider()
            Button(SuggestionsPresentation.dismissButton) { store.dismissSuggestions([suggestion.id]) }
                .disabled(!SuggestionsPresentation.canAct(state))
        }
    }
}

/// Import for one suggestion: a plain button, or with libraries a menu asking which one it goes in.
private struct SuggestionImportButton<Content: View>: View {
    @EnvironmentObject private var store: AppStore
    let id: String
    @ViewBuilder let label: () -> Content

    var body: some View {
        if SuggestionsPresentation.asksLibrary(store.libraries) {
            Menu {
                Section(SuggestionsPresentation.libraryMenuTitle) {
                    Button(SuggestionsPresentation.noLibrary) { store.importSuggestions([id]) }
                    ForEach(store.libraries) { lib in
                        Button(lib.name) { store.importSuggestions([id], library: lib.id) }
                    }
                }
            } label: {
                label()
            }
            .menuStyle(.button)
        } else {
            Button { store.importSuggestions([id]) } label: { label() }
        }
    }
}

/// Where a suggestion came from (Semantic Scholar or a Google Scholar alert), as a small capsule.
private struct SourceBadge: View {
    let source: Suggestion.Source

    var body: some View {
        Label(SuggestionsPresentation.source(source), systemImage: SuggestionsPresentation.sourceIcon(source))
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(Color.appAccent)
            .background(Color.appAccent.opacity(0.12), in: Capsule())
            .help(SuggestionsPresentation.sourceHelp(source))
    }
}

/// "Free PDF" or "Download in browser", as a small capsule.
private struct AvailabilityBadge: View {
    let suggestion: Suggestion

    var body: some View {
        Label(SuggestionsPresentation.availability(suggestion),
              systemImage: SuggestionsPresentation.availabilityIcon(suggestion))
            .font(.caption)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(SuggestionsPresentation.isFree(suggestion) ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            .background(.quaternary.opacity(0.6), in: Capsule())
            .help(SuggestionsPresentation.availabilityHelp(suggestion))
    }
}

/// The paper being fetched: which one, its status, and while waiting the steps and the browser button.
private struct FetchCard: View {
    @EnvironmentObject private var store: AppStore
    let fetch: PaperFetch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(SuggestionsPresentation.heading(fetch)).font(.headline).lineLimit(1)
                Spacer()
                Text(SuggestionsPresentation.position(fetch)).font(.caption).foregroundStyle(.secondary)
            }
            if SuggestionsPresentation.showsBrowserSteps(fetch) {
                ForEach(Array(SuggestionsPresentation.browserSteps.enumerated()), id: \.offset) { i, step in
                    Label(step, systemImage: "\(i + 1).circle.fill")
                        .font(.callout)
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(SuggestionsPresentation.status(fetch)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(SuggestionsPresentation.stopButton) { store.stopFetch() }
                    .buttonStyle(.glass)
                Button(SuggestionsPresentation.skipButton) { store.skipFetch() }
                    .buttonStyle(.glass)
                    .help(SuggestionsPresentation.skipHelp)
                if SuggestionsPresentation.showsBrowserSteps(fetch) {
                    Button(SuggestionsPresentation.openPageButton) { store.openPage(of: fetch.current) }
                        .buttonStyle(.glassProminent)
                        .disabled(!SuggestionsPresentation.canOpenPage(fetch.current))
                }
            }
        }
        .glassCard(tint: Color.appAccent.opacity(0.12))
    }
}

/// The details panel for the picked suggestion: title, authors, why it fits, the abstract, and
/// Import, Open in Browser and Dismiss.
struct SuggestionDetail: View {
    @EnvironmentObject private var store: AppStore
    let suggestion: Suggestion

    var body: some View {
        let state = SuggestionsPresentation.rowState(suggestion.id, fetch: store.paperFetch)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(suggestion.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text(SuggestionsPresentation.authors(suggestion))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        SourceBadge(source: suggestion.source)
                        AvailabilityBadge(suggestion: suggestion)
                        Text(SuggestionsPresentation.details(suggestion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 16)

                // Stacked at full width: side by side, the narrow panel squeezed their labels.
                VStack(spacing: 8) {
                    if let status = SuggestionsPresentation.rowStatus(state) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                    } else {
                        SuggestionImportButton(id: suggestion.id) {
                            Label(SuggestionsPresentation.importButton, systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .help(SuggestionsPresentation.importHelp)
                    }
                    HStack(spacing: 8) {
                        Button {
                            store.openPage(of: suggestion)
                        } label: {
                            Label(SuggestionsPresentation.openPageButton, systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!SuggestionsPresentation.canOpenPage(suggestion))
                        Button {
                            store.dismissSuggestions([suggestion.id])
                        } label: {
                            Label(SuggestionsPresentation.dismissButton, systemImage: "eye.slash")
                                .frame(maxWidth: .infinity)
                        }
                        .help(SuggestionsPresentation.dismissHelp)
                        .disabled(!SuggestionsPresentation.canAct(state))
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
                .lineLimit(1)

                if let why = suggestion.reason {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(title: SuggestionsPresentation.whyTitle, systemImage: "sparkles")
                        Text(why).font(.callout)
                    }
                    .glassCard(tint: Color.appAccent.opacity(0.10))
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: SuggestionsPresentation.abstractTitle, systemImage: "text.alignleft")
                    Text(SuggestionsPresentation.abstract(suggestion))
                        .font(.callout)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                    if let doi = SuggestionsPresentation.doiLine(suggestion) {
                        Text(doi).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .glassCard()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }
}

/// The details panel while Suggested is on screen and nothing is picked.
struct NoSuggestionPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label(SuggestionsPresentation.noSelectionTitle, systemImage: "text.book.closed")
        } description: {
            Text(SuggestionsPresentation.noSelectionMessage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
