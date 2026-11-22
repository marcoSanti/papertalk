// Suggested papers in the store: the daily check (Semantic Scholar), ranking by the LLM,
// dismissing, and importing the chosen ones (a free PDF directly, else from the Downloads folder).

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The chosen suggestions being imported, one at a time, and where the current one is.
struct PaperFetch: Equatable {
    /// What happens to the current paper now.
    enum Step: Equatable {
        /// Downloading its free PDF.
        case downloading
        /// Waiting for the user to download its PDF in the browser.
        case waiting
        /// A PDF arrived (its file name) and is being imported.
        case importing(String)
    }
    var current: Suggestion
    /// The ones after it.
    var queue: [Suggestion]
    var step: Step
    /// How many were chosen, and the position of `current` (from 1).
    var total: Int
    var position: Int
    /// The library each chosen suggestion is filed in, by suggestion id; missing: no library.
    var libraries: [String: String] = [:]
}

extension AppStore {
    /// While the app runs: check for suggestions when one is due (once a day), then look again
    /// every hour, so a Mac left on gets the next day's too.
    func runSuggestionChecks() async {
        while !Task.isCancelled {
            await checkSuggestionsIfDue()
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    /// Check now if the user turned checks on, setup is over, and today's check hasn't run.
    func checkSuggestionsIfDue(now: Date = Date()) async {
        guard suggestionsEnabled, !showOnboarding,
              Suggestions.isDue(lastCheckIso: suggestionLog.lastCheckIso, now: now) else { return }
        await checkSuggestions(now: now)
    }

    /// The Google Scholar alerts source, when the user set up a mail account for it.
    var alertSource: ScholarAlertSource? {
        let password = mailPassword()
        guard mail.isReady(password: password) else { return nil }
        return ScholarAlertSource(settings: mail, password: password, makeTransport: makeMailTransport)
    }

    /// Ask the sources (Semantic Scholar for papers like the library's, the user's Google Scholar
    /// alert emails) for suggestions, add the new ones, rank the waiting ones with the LLM and say
    /// how many arrived (a notification while in the background). One source failing doesn't
    /// lose the other's papers.
    func checkSuggestions(source: SemanticScholar = SemanticScholar(), now: Date = Date()) async {
        guard !isCheckingSuggestions else { return }
        let seeds = Suggestions.seeds(allPapers)
        let alerts = alertSource
        guard !seeds.isEmpty || alerts != nil else { suggestionsStatus = SuggestionsPresentation.noSeeds; return }
        isCheckingSuggestions = true
        defer { isCheckingSuggestions = false }
        await reloadSuggestionLog()
        var found: [Suggestion] = []
        var failures: [String] = []
        var anyAnswered = false
        var readAlerts: [String] = []
        // Alerts first: Google's own picks lead when the LLM doesn't rank.
        if let alerts {
            do {
                let result = try await alerts.suggestions(now: now, alreadyRead: Set(suggestionLog.readAlerts ?? []))
                found += result.papers
                readAlerts = result.read
                anyAnswered = true
            } catch {
                failures.append(SuggestionsPresentation.alertsFailed(error.localizedDescription))
            }
        }
        if !seeds.isEmpty {
            do {
                found += try await source.recommendations(for: seeds)
                anyAnswered = true
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        guard anyAnswered else {
            suggestionsStatus = SuggestionsPresentation.checkFailed(failures.joined(separator: " "))
            return
        }
        var (log, added) = Suggestions.merge(found, into: suggestionLog, library: allPapers)
        log.lastCheckIso = ISO8601DateFormatter().string(from: now)
        if !readAlerts.isEmpty { log.readAlerts = ScholarAlerts.remember(readAlerts, in: log.readAlerts) }
        suggestionLog = log
        suggestionsStatus = SuggestionsPresentation.checkResult(added: added.count, failures: failures)
        if !added.isEmpty {
            await rankSuggestions()
            notifier.post(.suggestions(SuggestionsPresentation.found(added.count)),
                          paperId: Self.suggestionsNotificationId, title: SuggestionsPresentation.windowTitle)
            // The notification only shows in the background; in front, a toast says it.
            show(SuggestionsPresentation.foundToast(added.count))
        }
        persistSuggestions()
    }

    /// Save Settings' mail page: the account in user defaults, the password in the Keychain,
    /// each only when it changed.
    func saveMailSettings(_ form: MailSettingsForm) {
        let next = form.settings
        if next != mail { mail = next }
        if form.password != mailPassword() { storeMailPassword(form.password) }
    }

    /// Settings' Test Connection: sign in with what the form holds and count recent alerts.
    func testMailConnection(_ form: MailSettingsForm, now: Date = Date()) async {
        guard !isTestingMail else { return }
        isTestingMail = true
        defer { isTestingMail = false }
        let source = ScholarAlertSource(settings: form.settings, password: form.password, makeTransport: makeMailTransport)
        do {
            mailTestResult = MailSettingsForm.testSucceeded(alerts: try await source.test(now: now), days: form.lookBackDays)
        } catch {
            mailTestResult = MailSettingsForm.testFailed(error.localizedDescription)
        }
    }

    /// Order the waiting suggestions by the LLM's sense of fit, with its reasons. Without an LLM,
    /// or when its reply can't be read, they keep the source's order.
    func rankSuggestions() async {
        guard !llm.baseUrl.isEmpty else { return }
        let ranked = Array(suggestionLog.pending.prefix(Suggestions.maxRanked))
        guard ranked.count > 1 else { return }
        var pipeline = LocalPipeline(baseUrl: llm.baseUrl, apiKey: llm.resolvedKey(),
                                     model: llm.model.isEmpty ? "llama3.1:70b" : llm.model)
        pipeline.log = { [weak self] in self?.appendLog($0) }
        let titles = allPapers.filter { !$0.isSlides }.map(\.displayTitle)
        do {
            let raw = try await pipeline.rankSuggestions(library: titles, candidates: ranked)
            guard let order = Suggestions.applyRanking(raw, to: ranked) else {
                appendLog("Suggestions: the ranking reply couldn't be read; kept Semantic Scholar's order")
                return
            }
            // Pending may have changed while the LLM answered: keep only what's still there.
            let still = Set(suggestionLog.pending.map(\.id))
            let head = order.filter { still.contains($0.id) }
            let headIds = Set(head.map(\.id))
            suggestionLog.pending = head + suggestionLog.pending.filter { !headIds.contains($0.id) }
        } catch {
            appendLog("Suggestions: ranking failed (\(error.localizedDescription)); kept Semantic Scholar's order")
        }
    }

    /// The suggestion in the details panel; nil when none is picked (or it was handled).
    var selectedSuggestion: Suggestion? {
        selectedSuggestionId.flatMap { id in suggestionLog.pending.first { $0.id == id } }
    }

    /// The Suggested section's depth menu, over `importChoice` (the rest of it is kept).
    var suggestionDepth: Depth {
        get { importChoice.resolvedDepth }
        set { importChoice.depth = newValue.rawValue }
    }

    /// Alerts are read in checks (Settings filled in, with a password).
    var alertsReady: Bool { alertSource != nil }

    /// Never show these again. Ones being imported stay (Stop or Skip first).
    func dismissSuggestions(_ ids: Set<String>) {
        let busy = Set(paperFetch.map { [$0.current.id] + $0.queue.map(\.id) } ?? [])
        suggestionLog = Suggestions.handle(ids.subtracting(busy), in: suggestionLog)
        persistSuggestions()
    }

    /// Import the chosen suggestions one at a time, in the list's order, filed in `library` (nil:
    /// none). While others are being imported, they join the end of the queue.
    func importSuggestions(_ ids: Set<String>, library: String? = nil) {
        let busy = Set(paperFetch.map { [$0.current.id] + $0.queue.map(\.id) } ?? [])
        let chosen = suggestionLog.pending.filter { ids.contains($0.id) && !busy.contains($0.id) }
        let filed = library.map { lib in Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, lib) }) } ?? [:]
        if paperFetch != nil {
            paperFetch?.queue += chosen
            paperFetch?.total += chosen.count
            paperFetch?.libraries.merge(filed) { $1 }
            return
        }
        guard let first = chosen.first else { return }
        paperFetch = PaperFetch(current: first, queue: Array(chosen.dropFirst()), step: .downloading,
                                total: chosen.count, position: 1, libraries: filed)
        Task { await fetchCurrent() }
    }

    /// Open a suggestion's page in the browser: to read about it, or to download its PDF.
    func openPage(of s: Suggestion) {
        guard let page = s.pageURL, let url = URL(string: page) else { return }
        _ = NSWorkspace.shared.open(url)
    }

    /// Leave the current suggestion waiting and go to the next.
    func skipFetch() { advanceFetch() }

    /// Stop importing; the ones not imported stay in the window.
    func stopFetch() {
        downloadsWatch?.cancel()
        downloadsWatch = nil
        paperFetch = nil
    }

    /// Get the current suggestion's PDF: its free copy when it has one, else wait for the user's download.
    private func fetchCurrent() async {
        guard let fetch = paperFetch else { return }
        let id = fetch.current.id
        if let link = fetch.current.pdfURL.flatMap(URL.init(string:)) {
            paperFetch?.step = .downloading
            if let data = await PaperDownload.pdf(at: link) {
                guard paperFetch?.current.id == id else { return }   // stopped or skipped meanwhile
                await importFetched(data, fileName: Suggestions.fileName(for: fetch.current))
                return
            }
            guard paperFetch?.current.id == id else { return }
            appendLog("Suggestions: the free PDF of “\(fetch.current.title)” didn't download; waiting for the browser")
        }
        paperFetch?.step = .waiting
        watchDownloads(for: id)
    }

    /// Look at the Downloads folder until a new PDF finishes downloading, then import it as the
    /// current suggestion. Files already there when the wait began never count.
    private func watchDownloads(for id: String) {
        downloadsWatch?.cancel()
        let folder = downloadsFolder
        let interval = downloadsPollInterval
        let before = Set(PaperDownload.listing(folder).keys)
        downloadsWatch = Task { [weak self] in
            var previous: [String: Int64] = [:]
            while !Task.isCancelled {
                let now = PaperDownload.listing(folder)
                if let name = Suggestions.finishedPDF(now: now, previous: previous, before: before),
                   let data = try? Data(contentsOf: folder.appendingPathComponent(name)), PaperDownload.isPDF(data) {
                    guard let self, self.paperFetch?.current.id == id else { return }
                    await self.importFetched(data, fileName: name)
                    return
                }
                previous = now
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Import a suggestion's PDF with the last import's choices, warn when it doesn't look like the
    /// suggested paper, mark it handled and go to the next.
    private func importFetched(_ data: Data, fileName: String) async {
        guard let s = paperFetch?.current else { return }
        paperFetch?.step = .importing(fileName)
        let opening = await Task.detached { LocalPipeline.extractPages(data).prefix(2).joined(separator: " ") }.value
        guard paperFetch?.current.id == s.id else { return }   // stopped or skipped meanwhile
        if !Suggestions.titleMatches(s.title, text: opening) {
            show(SuggestionsPresentation.mismatch(file: fileName, title: s.title))
        }
        let choice = importChoice
        upload(data, filename: fileName, depth: choice.resolvedDepth, depthNote: choice.depthNote,
               targetMinutes: choice.targetMinutes, scriptLanguage: choice.resolvedLanguage,
               library: paperFetch?.libraries[s.id])
        suggestionLog = Suggestions.handle([s.id], in: suggestionLog)
        persistSuggestions()
        advanceFetch()
    }

    /// On to the next chosen suggestion, or done.
    private func advanceFetch() {
        downloadsWatch?.cancel()
        downloadsWatch = nil
        guard var fetch = paperFetch, let next = fetch.queue.first else { paperFetch = nil; return }
        fetch.current = next
        fetch.queue.removeFirst()
        fetch.position += 1
        fetch.step = .downloading
        paperFetch = fetch
        Task { await fetchCurrent() }
    }
}
