// Reading Google Scholar alert emails over IMAP: a minimal client (sign in, open a mailbox
// read-only, search, fetch), its TLS connection (Network.framework on macOS), and the source
// that turns the alerts into suggested papers.

import Foundation
#if canImport(Network)
import Network
#endif

/// A byte stream to an IMAP server. The real one is `TLSTransport`; tests script a fake server.
protocol IMAPTransport: AnyObject {
    func open() async throws
    func send(_ data: Data) async throws
    /// Some bytes from the server (at least one); throws once the connection is gone.
    func receive() async throws -> Data
    func close()
}

/// Why talking to the mail server failed, in words for the Suggested section.
struct IMAPError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// The few IMAP commands reading alerts needs. Replies are read line by line; a line ending in
/// `{n}` is followed by an n-byte literal (a message's body), collected beside the lines.
final class IMAPClient {
    /// The untagged lines of a command's reply, and its literals in order.
    struct Reply { var lines: [String] = []; var literals: [Data] = [] }

    private let transport: IMAPTransport
    private var buffer = Data()
    private var counter = 0

    init(_ transport: IMAPTransport) { self.transport = transport }

    /// Connect and read the server's greeting.
    func connect() async throws {
        try await transport.open()
        let (greeting, _) = try await readLine()
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw IMAPError(message: L("The mail server didn't greet Papertalk: {0}", greeting))
        }
    }

    func login(_ account: String, password: String) async throws {
        do {
            _ = try await command("LOGIN \(Self.quoted(account)) \(Self.quoted(password))")
        } catch let e as IMAPError {
            throw IMAPError(message: L("The mail server refused the sign-in: {0}", e.message))
        }
    }

    /// Open `mailbox` read-only, so reading never marks alerts as seen.
    func examine(_ mailbox: String) async throws {
        do {
            _ = try await command("EXAMINE \(Self.quoted(mailbox))")
        } catch let e as IMAPError {
            throw IMAPError(message: L("Couldn't open the mailbox “{0}”: {1}", mailbox, e.message))
        }
    }

    /// The UIDs of messages from `sender` since `date` (`ScholarAlerts.imapDate`), oldest first.
    func search(from sender: String, since date: String) async throws -> [Int] {
        let reply = try await command("UID SEARCH SINCE \(date) FROM \(Self.quoted(sender))")
        return reply.lines.filter { $0.hasPrefix("* SEARCH") }
            .flatMap { $0.dropFirst("* SEARCH".count).split(separator: " ").compactMap { Int($0) } }
            .sorted()
    }

    /// The raw message with `uid`, without marking it seen.
    func fetch(uid: Int) async throws -> Data? {
        try await command("UID FETCH \(uid) BODY.PEEK[]").literals.first
    }

    /// Say goodbye and close; failures don't matter by then.
    func logout() async {
        _ = try? await command("LOGOUT")
        transport.close()
    }

    /// Send a tagged command and read up to its tagged reply, which must be OK.
    func command(_ text: String) async throws -> Reply {
        counter += 1
        let tag = "a\(counter)"
        try await transport.send(Data("\(tag) \(text)\r\n".utf8))
        var reply = Reply()
        while true {
            let (line, literals) = try await readLine()
            reply.literals += literals
            guard line.hasPrefix(tag + " ") else { reply.lines.append(line); continue }
            let status = String(line.dropFirst(tag.count + 1))
            guard status.hasPrefix("OK") else { throw IMAPError(message: status) }
            return reply
        }
    }

    /// One logical reply line (without CRLF), with any literals it carries.
    private func readLine() async throws -> (String, [Data]) {
        var line = Data()
        var literals: [Data] = []
        while true {
            let chunk = try await take(untilCRLF: ())
            line += chunk
            let text = String(decoding: chunk, as: UTF8.self)
            if let open = text.lastIndex(of: "{"), text.hasSuffix("}"), let n = Int(text[text.index(after: open)..<text.index(before: text.endIndex)]), n >= 0 {
                literals.append(try await take(count: n))
                continue   // the line goes on after the literal
            }
            return (String(decoding: line, as: UTF8.self), literals)
        }
    }

    private func take(untilCRLF _: Void) async throws -> Data {
        let crlf = Data("\r\n".utf8)
        while true {
            if let r = buffer.range(of: crlf) {
                let out = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer = buffer.subdata(in: r.upperBound..<buffer.endIndex)
                return out
            }
            buffer += try await transport.receive()
        }
    }

    private func take(count n: Int) async throws -> Data {
        while buffer.count < n { buffer += try await transport.receive() }
        let out = buffer.subdata(in: buffer.startIndex..<buffer.startIndex + n)
        buffer = buffer.subdata(in: buffer.startIndex + n..<buffer.endIndex)
        return out
    }

    /// An IMAP quoted string: backslashes and quotes escaped.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

#if canImport(Network)
/// IMAP over TLS with Network.framework.
// shortcut: no timeout on a server that accepts the connection and then stalls; add one if that's seen.
final class TLSTransport: IMAPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "papertalk.imap")

    init(host: String, port: Int) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .imaps,
                                  using: NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp))
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; c.resume()
                case .failed(let e), .waiting(let e): once.done = true; c.resume(throwing: e)
                case .cancelled: once.done = true; c.resume(throwing: CancellationError())
                default: break
                }
            }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error { c.resume(throwing: error) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else if isComplete { c.resume(throwing: IMAPError(message: L("The mail server closed the connection."))) }
                else { c.resume(returning: Data()) }
            }
        }
    }

    func close() { connection.cancel() }
}

/// Whether `open`'s continuation was resumed; only touched on the connection's queue.
private final class ResumeOnce: @unchecked Sendable { var done = false }
#endif

/// Google Scholar alert emails as suggested papers.
struct ScholarAlertSource {
    var settings: MailSettings
    var password: String
    /// The connection to the server; tests pass a scripted one.
    var makeTransport: (MailSettings) throws -> IMAPTransport = ScholarAlertSource.defaultTransport

    static func defaultTransport(_ s: MailSettings) throws -> IMAPTransport {
        #if canImport(Network)
        return TLSTransport(host: s.host, port: s.port)
        #else
        throw IMAPError(message: L("Reading Google Scholar alerts isn't available on Linux yet."))
        #endif
    }

    /// The papers in the alerts of the look-back window not read before (`alreadyRead`), newest
    /// first and at most `ScholarAlerts.maxMessages` emails; with the ids of the emails read.
    func suggestions(now: Date, alreadyRead: Set<String>) async throws -> (papers: [Suggestion], read: [String]) {
        let client = try await signedIn()
        do {
            let since = ScholarAlerts.searchStart(lookBackDays: settings.lookBack, now: now)
            let uids = try await client.search(from: ScholarAlerts.sender, since: ScholarAlerts.imapDate(since))
            var found: [Suggestion] = []
            var read: [String] = []
            for uid in ScholarAlerts.toRead(uids, read: alreadyRead, account: settings.account, mailbox: settings.mailbox) {
                let raw = try await client.fetch(uid: uid)
                read.append(ScholarAlerts.alertId(account: settings.account, mailbox: settings.mailbox, uid: uid))
                guard let raw, let html = ScholarAlerts.html(ofMessage: raw) else { continue }
                found += ScholarAlerts.papers(inAlert: html)
            }
            await client.logout()
            return (found, read)
        } catch {
            await client.logout()
            throw error
        }
    }

    /// Sign in and count the alert emails in the look-back window: Settings' Test Connection.
    func test(now: Date = Date()) async throws -> Int {
        let client = try await signedIn()
        do {
            let since = ScholarAlerts.searchStart(lookBackDays: settings.lookBack, now: now)
            let n = try await client.search(from: ScholarAlerts.sender, since: ScholarAlerts.imapDate(since)).count
            await client.logout()
            return n
        } catch {
            await client.logout()
            throw error
        }
    }

    /// Connected, signed in and with the mailbox open.
    private func signedIn() async throws -> IMAPClient {
        let client = IMAPClient(try makeTransport(settings))
        do {
            try await client.connect()
        } catch let e as IMAPError {
            throw e
        } catch {
            throw IMAPError(message: L("Couldn't connect to {0}: {1}", settings.host, error.localizedDescription))
        }
        do {
            try await client.login(settings.account, password: password)
            try await client.examine(settings.mailbox)
        } catch {
            await client.logout()
            throw error
        }
        return client
    }
}
