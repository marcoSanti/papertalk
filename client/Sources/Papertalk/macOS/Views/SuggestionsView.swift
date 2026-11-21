// The Suggested section of the main window: the daily check's header, the paper being fetched,
// one row per suggested paper, and the details panel that shows the picked one's abstract.

#if os(macOS)
import SwiftUI

/// The main pane while Suggested is picked in the sidebar. Wording and decisions come from
/// `SuggestionsPresentation`; actions go to the store.
struct SuggestionsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.suggestionLog.pending.isEmpty {
                emptyState
            } else {
                List(store.suggestionLog.pending, selection: $store.selectedSuggestionId) { s in
                    SuggestionRow(suggestion: s)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
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
    }

    /// The daily check's switch, the last check's result, and Check Now, on one glass bar.
    private var header: some View {
        HStack(spacing: 12) {
            Toggle(SuggestionsPresentation.enableToggle, isOn: $store.suggestionsEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(SuggestionsPresentation.enableHelp)
            if let status = store.suggestionsStatus {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Picker(SuggestionsPresentation.importDepthLabel, selection: $store.suggestionDepth) {
                ForEach(SuggestionsPresentation.importDepths(current: store.suggestionDepth)) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .help(SuggestionsPresentation.importDepthHelp)
            Button {
                store.openSettings(.suggestions)
            } label: {
                Label(SuggestionsPresentation.alertsButton(ready: store.alertsReady), systemImage: "gearshape")
            }
            .buttonStyle(.glass)
            .help(SuggestionsPresentation.alertsHelp(ready: store.alertsReady))
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

/// One suggested paper: title, byline, the LLM's reason, how the PDF arrives, and its actions.
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
                HStack(spacing: 6) {
                    SourceBadge(source: suggestion.source)
                    Text(SuggestionsPresentation.details(suggestion))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
                Button(SuggestionsPresentation.importButton) { store.importSuggestions([suggestion.id]) }
                    .buttonStyle(.glassProminent)
                    .help(SuggestionsPresentation.importHelp)
                Button(SuggestionsPresentation.dismissButton) { store.dismissSuggestions([suggestion.id]) }
                    .buttonStyle(.glass)
                    .help(SuggestionsPresentation.dismissHelp)
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button(SuggestionsPresentation.importButton) { store.importSuggestions([suggestion.id]) }
                .disabled(!SuggestionsPresentation.canAct(state))
            Button(SuggestionsPresentation.openPageButton) { store.openPage(of: suggestion) }
                .disabled(!SuggestionsPresentation.canOpenPage(suggestion))
            Divider()
            Button(SuggestionsPresentation.dismissButton) { store.dismissSuggestions([suggestion.id]) }
                .disabled(!SuggestionsPresentation.canAct(state))
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
                        Button {
                            store.importSuggestions([suggestion.id])
                        } label: {
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
