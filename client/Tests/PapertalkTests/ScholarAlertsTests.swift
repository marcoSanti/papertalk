// Tests of Google Scholar alerts as suggested papers: undoing MIME, reading an alert's HTML,
// the IMAP client against a scripted server (replies cut into small chunks), the mail settings
// form, and the store's check reading alerts beside Semantic Scholar.

import XCTest
@testable import Papertalk

/// A scripted IMAP server: answers each command through `respond`, sending its replies a few
/// bytes at a time so the client's buffering is exercised.
final class FakeIMAPServer: IMAPTransport {
    var greeting = "* OK Gimap ready\r\n"
    /// Command (without its tag) → reply lines; "TAG" is replaced by the command's tag.
    var respond: (String) -> String = { _ in "TAG OK done\r\n" }
    private(set) var commands: [String] = []
    private(set) var closed = false
    var failOpen: Error?
    private var outgoing = Data()
    private let chunk = 7

    func open() async throws {
        if let failOpen { throw failOpen }
        outgoing += Data(greeting.utf8)
    }

    func send(_ data: Data) async throws {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let space = line.firstIndex(of: " ")!
        let tag = String(line[..<space]), command = String(line[line.index(after: space)...])
        commands.append(command)
        outgoing += Data(respond(command).replacingOccurrences(of: "TAG", with: tag).utf8)
    }

    func receive() async throws -> Data {
        guard !outgoing.isEmpty else { throw IMAPError(message: "nothing to read") }
        let n = min(chunk, outgoing.count)
        defer { outgoing = outgoing.subdata(in: n..<outgoing.count) }
        return outgoing.subdata(in: 0..<n)
    }

    func close() { closed = true }
}

@MainActor
final class ScholarAlertsTests: PapertalkTestCase {
    nonisolated(unsafe) private var storage: LocalStorage!

    override func setUp() {
        super.setUp()
        storage = LocalStorage(root: Fixtures.tempDir())
    }

    /// An alert's HTML as Scholar sends it: a [PDF] arXiv paper, a publisher page with a DOI, and
    /// a heading that isn't a paper.
    nonisolated static let alertHTML = """
    <html><body><h3 style="font-weight:normal">Scholar Alert Digest</h3>
    <h3 style="font-weight:normal;margin:0"><span style="font-size:11px">[PDF]</span> <a href="https://scholar.google.com/scholar_url?url=https://arxiv.org/pdf/2611.01234v2&amp;hl=en&amp;sa=X&amp;scisig=AAA" class="gse_alrt_title" style="font-size:17px">Sparse <b>Attention</b> &amp; Long Context</a></h3>
    <div style="color:#006621">A Lovelace, B Kernighan, C Hopper… - arXiv preprint arXiv:2611.01234, 2026</div>
    <div class="gse_alrt_sni" style="line-height:17px">We show that sparse&nbsp;attention&#8230; scales.</div>
    <h3 style="font-weight:normal;margin:0"><a href="https://scholar.google.com/scholar_url?url=https://dl.acm.org/doi/abs/10.1145/3600006.3613165&amp;hl=en" class="gse_alrt_title">Retrieval at Scale</a></h3>
    <div style="color:#006621">D Ritchie - Proceedings of SOSP, 2025</div>
    <div class="gse_alrt_sni">Retrieval is hard.</div>
    </body></html>
    """

    /// The alert as a raw email: quoted-printable HTML inside a multipart message.
    nonisolated static func alertEmail() -> String {
        // Long lines get soft breaks, as mail servers write them (cut before encoding, so no "=3D" splits).
        let qp = alertHTML.components(separatedBy: "\n").map { line -> String in
            stride(from: 0, to: max(line.count, 1), by: 60).map { start -> String in
                let from = line.index(line.startIndex, offsetBy: start)
                let to = line.index(from, offsetBy: min(60, line.count - start))
                return String(line[from..<to]).replacingOccurrences(of: "=", with: "=3D")
            }.joined(separator: "=\r\n")
        }.joined(separator: "\r\n")
        return """
        From: Google Scholar Alerts <scholaralerts-noreply@google.com>\r
        Subject: New articles\r
        Content-Type: multipart/alternative;\r
         boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=UTF-8\r
        \r
        Plain text version\r
        --b1\r
        Content-Type: text/html; charset=UTF-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        \(qp)\r
        --b1--\r
        """
    }

    // MARK: Parsing

    func testAnAlertEmailGivesItsPapersWithLinksAndBylines() throws {
        let html = try XCTUnwrap(ScholarAlerts.html(ofMessage: Data(Self.alertEmail().utf8)))
        XCTAssertTrue(html.contains("Sparse <b>Attention</b>"))
        let papers = ScholarAlerts.papers(inAlert: html)
        XCTAssertEqual(papers.map(\.title), ["Sparse Attention & Long Context", "Retrieval at Scale"])
        let arxiv = papers[0]
        XCTAssertEqual(arxiv.authors, ["A Lovelace", "B Kernighan", "C Hopper"])
        XCTAssertEqual(arxiv.year, 2026)
        XCTAssertEqual(arxiv.pdfURL, "https://arxiv.org/pdf/2611.01234")
        XCTAssertEqual(arxiv.pageURL, "https://arxiv.org/abs/2611.01234")
        XCTAssertEqual(arxiv.abstract, "We show that sparse attention… scales.")
        XCTAssertEqual(arxiv.source, .scholarAlert)
        let acm = papers[1]
        XCTAssertEqual(acm.doi, "10.1145/3600006.3613165")
        XCTAssertEqual(acm.id, "doi:10.1145/3600006.3613165")
        XCTAssertEqual(acm.pageURL, "https://dl.acm.org/doi/abs/10.1145/3600006.3613165")
        XCTAssertNil(acm.pdfURL)
        XCTAssertEqual(acm.year, 2025)
    }

    func testMIMEPartsAndEncodings() {
        let base64 = "Content-Type: text/html\r\nContent-Transfer-Encoding: base64\r\n\r\n" + Data("<b>hé</b>".utf8).base64EncodedString()
        XCTAssertEqual(ScholarAlerts.html(ofMessage: Data(base64.utf8)), "<b>hé</b>")
        XCTAssertEqual(ScholarAlerts.html(ofMessage: Data("Content-Type: text/html\n\n<p>x</p>".utf8)), "<p>x</p>")
        XCTAssertNil(ScholarAlerts.html(ofMessage: Data("Content-Type: text/plain\n\nhi".utf8)))
        XCTAssertNil(ScholarAlerts.html(ofMessage: Data("no headers".utf8)))
        XCTAssertEqual(String(decoding: ScholarAlerts.decodeQuotedPrintable("caf=C3=A9 =3D x=\r\ny"), as: UTF8.self), "café = xy")
        XCTAssertEqual(ScholarAlerts.parameter("boundary", in: "multipart/mixed; boundary=\"abc\""), "abc")
        XCTAssertEqual(ScholarAlerts.headers("Subject: a\n b\nX: y")["subject"], "a b")
    }

    func testLinksBylinesAndEntities() {
        XCTAssertEqual(ScholarAlerts.targetURL("https://scholar.google.it/scholar_url?url=https://x.org/p&hl=it"), "https://x.org/p")
        XCTAssertEqual(ScholarAlerts.targetURL("https://x.org/p"), "https://x.org/p")
        XCTAssertNil(ScholarAlerts.targetURL("mailto:x@y"))
        XCTAssertEqual(ScholarAlerts.paperLinks("https://x.org/a.PDF", markedPDF: false).pdf, "https://x.org/a.PDF")
        XCTAssertEqual(ScholarAlerts.paperLinks("https://x.org/a", markedPDF: true).pdf, "https://x.org/a")
        XCTAssertNil(ScholarAlerts.paperLinks("https://x.org/a", markedPDF: false).pdf)
        XCTAssertEqual(ScholarAlerts.doi(in: "https://doi.org/10.1000/abc.pdf?x=1"), "10.1000/abc")
        XCTAssertNil(ScholarAlerts.doi(in: "https://x.org/p"))
        let none = ScholarAlerts.parseByline("Just a venue")
        XCTAssertEqual(none.authors, [])
        XCTAssertNil(none.year)
        XCTAssertEqual(ScholarAlerts.decodeEntities("&amp;lt; &#x41; &quot;"), "&lt; A \"")
        XCTAssertEqual(ScholarAlerts.text("<p>a <i>b</i>\n c</p>"), "a b c")
    }

    func testTheSearchCoversTheLookBackAndSkipsAlertsAlreadyRead() {
        let now = ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z")!
        XCTAssertEqual(ScholarAlerts.imapDate(ScholarAlerts.searchStart(lookBackDays: 14, now: now)), "6-Nov-2026")
        XCTAssertEqual(ScholarAlerts.imapDate(ScholarAlerts.searchStart(lookBackDays: 365, now: now)), "20-Nov-2025")
        XCTAssertEqual(MailSettings().lookBack, 14)
        XCTAssertEqual(MailSettings(lookBackDays: 90).lookBack, 90)
        let read: Set<String> = [ScholarAlerts.alertId(account: "me", mailbox: "INBOX", uid: 9)]
        XCTAssertEqual(ScholarAlerts.toRead([3, 9, 5], read: read, account: "me", mailbox: "INBOX"), [5, 3])
        // Another mailbox's UID 9 is a different email.
        XCTAssertEqual(ScholarAlerts.toRead([9], read: read, account: "me", mailbox: "Alerts"), [9])
        XCTAssertEqual(ScholarAlerts.toRead(Array(1...50), read: [], account: "me", mailbox: "INBOX").count, ScholarAlerts.maxMessages)
        XCTAssertEqual(ScholarAlerts.toRead(Array(1...50), read: [], account: "me", mailbox: "INBOX").first, 50)
        let many = (0..<ScholarAlerts.maxRemembered).map(String.init)
        XCTAssertEqual(ScholarAlerts.remember(["new"], in: many).last, "new")
        XCTAssertEqual(ScholarAlerts.remember(["new"], in: many).count, ScholarAlerts.maxRemembered)
        XCTAssertEqual(ScholarAlerts.remember(["a"], in: nil), ["a"])
    }

    func testOlderSettingsAndLogsStillDecode() throws {
        let oldMail = #"{"enabled":true,"host":"h","port":993,"account":"a","mailbox":"INBOX"}"#
        XCTAssertEqual(try JSONDecoder().decode(MailSettings.self, from: Data(oldMail.utf8)).lookBack, 14)
        let oldLog = #"{"pending":[],"handled":["x"]}"#
        XCTAssertNil(try JSONDecoder().decode(SuggestionLog.self, from: Data(oldLog.utf8)).readAlerts)
    }

    // MARK: IMAP

    /// A server holding the alert as message 42 (and an older one, 7, that isn't an alert).
    private func alertServer() -> FakeIMAPServer {
        let server = FakeIMAPServer()
        let email = Self.alertEmail()
        server.respond = { command in
            if command.hasPrefix("UID SEARCH") { return "* SEARCH 42 7\r\nTAG OK SEARCH completed\r\n" }
            if command == "UID FETCH 42 BODY.PEEK[]" {
                return "* 1 FETCH (UID 42 BODY[] {\(email.utf8.count)}\r\n\(email))\r\nTAG OK Success\r\n"
            }
            if command == "UID FETCH 7 BODY.PEEK[]" {
                return "* 2 FETCH (UID 7 BODY[] {13}\r\nnot an email.)\r\nTAG OK Success\r\n"
            }
            if command == "LOGOUT" { return "* BYE\r\nTAG OK bye\r\n" }
            return "TAG OK done\r\n"
        }
        return server
    }

    func testTheSourceSignsInReadsOnlyAndParsesTheAlerts() async throws {
        let server = alertServer()
        let settings = MailSettings(enabled: true, account: "me@gmail.com", mailbox: "[Gmail]/All Mail")
        let source = ScholarAlertSource(settings: settings, password: "pa\"ss") { _ in server }
        let now = ISO8601DateFormatter().date(from: "2026-11-27T00:00:00Z")!
        let (papers, read) = try await source.suggestions(now: now, alreadyRead: [])
        XCTAssertEqual(papers.map(\.title), ["Sparse Attention & Long Context", "Retrieval at Scale"])
        XCTAssertEqual(read, ["me@gmail.com|[Gmail]/All Mail|42", "me@gmail.com|[Gmail]/All Mail|7"])
        XCTAssertEqual(server.commands, [
            #"LOGIN "me@gmail.com" "pa\"ss""#,
            #"EXAMINE "[Gmail]/All Mail""#,
            #"UID SEARCH SINCE 13-Nov-2026 FROM "scholaralerts-noreply@google.com""#,
            "UID FETCH 42 BODY.PEEK[]", "UID FETCH 7 BODY.PEEK[]", "LOGOUT",
        ])
        XCTAssertTrue(server.closed)
    }

    func testARefusedSignInSaysSoAndCloses() async {
        let server = FakeIMAPServer()
        server.respond = { $0.hasPrefix("LOGIN") ? "TAG NO [AUTHENTICATIONFAILED] Invalid credentials\r\n" : "TAG OK\r\n" }
        let source = ScholarAlertSource(settings: MailSettings(enabled: true, account: "me"), password: "x") { _ in server }
        do {
            _ = try await source.suggestions(now: Date(), alreadyRead: [])
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The mail server refused the sign-in: NO [AUTHENTICATIONFAILED] Invalid credentials")
        }
        XCTAssertTrue(server.closed)
    }

    func testAnUnreachableServerAndABadGreetingAreExplained() async {
        let down = FakeIMAPServer()
        down.failOpen = URLError(.cannotConnectToHost)
        let source = ScholarAlertSource(settings: MailSettings(enabled: true, account: "me"), password: "x") { _ in down }
        do { _ = try await source.test(); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Couldn't connect to imap.gmail.com:"))
        }
        let rude = FakeIMAPServer()
        rude.greeting = "* BYE go away\r\n"
        let other = ScholarAlertSource(settings: MailSettings(enabled: true, account: "me"), password: "x") { _ in rude }
        do { _ = try await other.test(); XCTFail() } catch {
            XCTAssertEqual(error.localizedDescription, "The mail server didn't greet Papertalk: * BYE go away")
        }
    }

    func testTestConnectionCountsRecentAlerts() async throws {
        let source = ScholarAlertSource(settings: MailSettings(enabled: true, account: "me"), password: "x") { _ in self.alertServer() }
        let n = try await source.test(now: ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(IMAPClient.quoted(#"a\b"c"#), #""a\\b\"c""#)
    }

    // MARK: Settings form

    func testMailFormTrimsDefaultsAndValidates() {
        var form = MailSettingsForm(MailSettings(), password: "")
        XCTAssertFalse(form.canTest)
        form.account = "  me@gmail.com "
        form.password = "abcd"
        form.host = " "
        form.mailbox = ""
        form.port = "nope"
        XCTAssertFalse(form.canTest)
        XCTAssertEqual(form.portProblem, "Enter a port from 1 to 65535.")
        XCTAssertEqual(form.settings, MailSettings(enabled: false, host: "imap.gmail.com", port: 993, account: "me@gmail.com", mailbox: "INBOX", lookBackDays: 14))
        form.port = "143"
        XCTAssertTrue(form.canTest)
        XCTAssertNil(form.portProblem)
        XCTAssertEqual(form.settings.port, 143)
        XCTAssertTrue(MailSettings(enabled: true, account: "a").isReady(password: "p"))
        XCTAssertFalse(MailSettings(enabled: false, account: "a").isReady(password: "p"))
        XCTAssertFalse(MailSettings(enabled: true, account: "a").isReady(password: ""))
        XCTAssertEqual(MailSettingsForm.testSucceeded(alerts: 1, days: 30), "Signed in. Found 1 Google Scholar alert email from the last 30 days.")
        XCTAssertEqual(MailSettingsForm.testSucceeded(alerts: 3, days: 7), "Signed in. Found 3 Google Scholar alert emails from the last 7 days.")
        XCTAssertTrue(MailSettingsForm.testSucceeded(alerts: 0, days: 14).hasPrefix("Signed in. No Google Scholar"))
        XCTAssertEqual(MailSettingsForm.lookBackOptions.map(\.label),
                       ["1 week", "2 weeks", "30 days", "60 days", "90 days", "180 days", "1 year"])
        form.lookBackDays = 90
        XCTAssertEqual(form.settings.lookBackDays, 90)
        XCTAssertEqual(MailSettingsForm.testButton(testing: true), "Testing…")
        XCTAssertEqual(MailSettingsForm.steps.count, 3)
    }

    func testMailSettingsRoundTripWithoutThePassword() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "mail-\(UUID().uuidString)"))
        XCTAssertEqual(MailSettings.load(defaults), MailSettings())
        let s = MailSettings(enabled: true, host: "imap.x.org", port: 143, account: "me", mailbox: "Alerts", lookBackDays: 60)
        s.save(defaults)
        XCTAssertEqual(MailSettings.load(defaults), s)
        let saved = String(decoding: try XCTUnwrap(defaults.data(forKey: MailSettings.defaultsKey)), as: UTF8.self)
        XCTAssertFalse(saved.contains("password"))
    }

    // MARK: Store

    private func makeStore(_ papers: [Paper], server: FakeIMAPServer?) async -> AppStore {
        for p in papers { await storage.save(p, K.paper(p.id)) }
        let store = AppStore(storage: storage)
        await waitUntil { store.papers.count == papers.count }
        store.mailPassword = { "pw" }
        store.storeMailPassword = { _ in XCTFail("the test shouldn't write the Keychain") }
        if let server { store.makeMailTransport = { _ in server } }
        return store
    }

    func testTheCheckReadsAlertsWithoutAnyDOIs() async {
        let store = await makeStore([Fixtures.paper(id: "p", doi: "")], server: alertServer())
        let saved = store.mail
        defer { store.mail = saved }
        store.mail = MailSettings(enabled: true, account: "me@gmail.com")
        MockLLM.install { _ in (200, MockLLM.chatReply("can't rank")) }   // ranking, if an LLM is set
        await store.checkSuggestions()
        XCTAssertEqual(store.suggestionLog.pending.map(\.source), [.scholarAlert, .scholarAlert])
        XCTAssertEqual(store.suggestionsStatus, "2 new papers like yours.")
        XCTAssertEqual(store.suggestionLog.readAlerts, ["me@gmail.com|INBOX|42", "me@gmail.com|INBOX|7"])
        // The next check finds the same emails and doesn't read them again.
        let again = alertServer()
        store.makeMailTransport = { _ in again }
        await store.checkSuggestions()
        XCTAssertFalse(again.commands.contains { $0.hasPrefix("UID FETCH") })
        XCTAssertEqual(store.suggestionLog.readAlerts?.count, 2)
    }

    func testAFailingSourceKeepsTheOthersPapersAndIsReported() async {
        let store = await makeStore([Fixtures.paper(id: "p", doi: "10.1/p")], server: nil)
        let saved = store.mail
        defer { store.mail = saved }
        store.mail = MailSettings(enabled: true, account: "me@gmail.com")
        let down = FakeIMAPServer()
        down.failOpen = URLError(.notConnectedToInternet)
        store.makeMailTransport = { _ in down }
        MockLLM.install { _ in
            (200, Data(#"{"recommendedPapers": [{"title": "From S2", "externalIds": {}}]}"#.utf8))
        }
        await store.checkSuggestions()
        XCTAssertEqual(store.suggestionLog.pending.map(\.title), ["From S2"])
        XCTAssertNotNil(store.suggestionLog.lastCheckIso)
        let status = store.suggestionsStatus ?? ""
        XCTAssertTrue(status.hasPrefix("1 new paper like yours. Couldn't check for suggested papers: Google Scholar alerts: Couldn't connect to imap.gmail.com:"), status)
    }

    func testAlertsTurnedOffOrWithoutAPasswordAreNotRead() async {
        let server = alertServer()
        let store = await makeStore([Fixtures.paper(id: "p", doi: "")], server: server)
        let saved = store.mail
        defer { store.mail = saved }
        store.mail = MailSettings(enabled: false, account: "me@gmail.com")
        XCTAssertNil(store.alertSource)
        store.mail.enabled = true
        store.mailPassword = { "" }
        XCTAssertNil(store.alertSource)
        await store.checkSuggestions()
        XCTAssertEqual(store.suggestionsStatus, SuggestionsPresentation.noSeeds)
        XCTAssertTrue(server.commands.isEmpty)
    }

    func testSavingTheMailPageWritesOnlyWhatChanged() async {
        let store = await makeStore([], server: nil)
        let saved = store.mail
        defer { store.mail = saved }
        var written: [String] = []
        store.storeMailPassword = { written.append($0) }
        var form = MailSettingsForm(store.mail, password: "pw")
        store.saveMailSettings(form)
        XCTAssertEqual(written, [])
        form.account = "new@gmail.com"
        form.password = "new"
        store.saveMailSettings(form)
        XCTAssertEqual(store.mail.account, "new@gmail.com")
        XCTAssertEqual(written, ["new"])
    }

    func testTestConnectionReportsWhatItFound() async {
        let store = await makeStore([], server: alertServer())
        var form = MailSettingsForm(MailSettings(enabled: true), password: "pw")
        form.account = "me@gmail.com"
        await store.testMailConnection(form, now: ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!)
        XCTAssertEqual(store.mailTestResult, "Signed in. Found 2 Google Scholar alert emails from the last 14 days.")
        let refused = FakeIMAPServer()
        refused.respond = { $0.hasPrefix("LOGIN") ? "TAG NO bad\r\n" : "TAG OK\r\n" }
        store.makeMailTransport = { _ in refused }
        await store.testMailConnection(form)
        XCTAssertEqual(store.mailTestResult, "Couldn't read the alerts: The mail server refused the sign-in: NO bad")
    }

    func testCheckResultWording() {
        XCTAssertEqual(SuggestionsPresentation.checkResult(added: 2, failures: []), "2 new papers like yours.")
        XCTAssertEqual(SuggestionsPresentation.checkResult(added: 0, failures: ["x."]), "No new papers this time. Couldn't check for suggested papers: x.")
        XCTAssertEqual(SuggestionsPresentation.alertsFailed("down"), "Google Scholar alerts: down")
    }
}
