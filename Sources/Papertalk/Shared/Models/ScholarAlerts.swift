// Google Scholar alert emails as a source of suggested papers: the mail account settings
// (the password lives in the Keychain), and the pure parsing of an alert, from the raw
// message through its MIME parts to the papers listed in its HTML.

import Foundation

/// The mail account that receives Google Scholar alerts, read over IMAP. Saved in user
/// defaults; the password never is (`passwordAccount` in the Keychain).
struct MailSettings: Codable, Equatable {
    /// Read the alerts during the daily check.
    var enabled = false
    var host = "imap.gmail.com"
    /// IMAP over TLS.
    var port = 993
    /// The address signed in with, e.g. "me@gmail.com".
    var account = ""
    /// Where the alerts arrive. Gmail filters may skip the inbox: then "[Gmail]/All Mail".
    var mailbox = "INBOX"
    /// How many days back alert emails are read; older ones never are. Nil: `defaultLookBack`.
    /// Optional, so settings saved before it existed still decode.
    var lookBackDays: Int? = nil

    /// The choices Settings offers, in days.
    static let lookBackChoices = [7, 14, 30, 60, 90, 180, 365]
    static let defaultLookBack = 14
    /// `lookBackDays`, or the default.
    var lookBack: Int { lookBackDays ?? Self.defaultLookBack }

    static let defaultsKey = "papertalk.mail.json"
    /// The Keychain entry holding the app password.
    static let passwordAccount = "papertalk.mail.password"

    static func load(_ defaults: UserDefaults = .standard) -> MailSettings {
        defaults.decoded(MailSettings.self, forKey: defaultsKey) ?? MailSettings()
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.setEncoded(self, forKey: Self.defaultsKey)
    }

    /// On, with an account and a password to sign in with.
    func isReady(password: String) -> Bool { enabled && !account.isEmpty && !password.isEmpty }
}

/// Reading Google Scholar alert emails, as pure functions.
enum ScholarAlerts {
    /// The address every Scholar alert comes from.
    static let sender = "scholaralerts-noreply@google.com"
    /// At most this many alert emails are read per check: the newest not read before. A long
    /// look-back is worked through over several checks.
    static let maxMessages = 20
    /// How many read alerts `SuggestionLog.readAlerts` remembers.
    static let maxRemembered = 2_000

    // MARK: Searching

    /// The day to search from: `days` before `now`.
    static func searchStart(lookBackDays days: Int, now: Date) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// How an alert read once is remembered: its account, mailbox and UID.
    static func alertId(account: String, mailbox: String, uid: Int) -> String { "\(account)|\(mailbox)|\(uid)" }

    /// Of the UIDs found, the newest `maxMessages` not in `read`, newest first.
    static func toRead(_ uids: [Int], read: Set<String>, account: String, mailbox: String) -> [Int] {
        Array(uids.sorted().reversed().filter { !read.contains(alertId(account: account, mailbox: mailbox, uid: $0)) }
            .prefix(maxMessages))
    }

    /// The remembered alerts plus `new`, dropping the oldest beyond `maxRemembered`.
    static func remember(_ new: [String], in read: [String]?) -> [String] {
        Array(((read ?? []) + new).suffix(maxRemembered))
    }

    /// IMAP's date form, "13-Nov-2026" (English month, whatever the system language).
    static func imapDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d-MMM-yyyy"
        return f.string(from: date)
    }

    // MARK: MIME

    /// The HTML of a raw email: its own body when it's text/html, else the first text/html part
    /// of a multipart message, with the transfer encoding undone. Nil when there is none.
    static func html(ofMessage raw: Data) -> String? {
        html(ofPart: String(decoding: raw, as: UTF8.self))
    }

    private static func html(ofPart part: String) -> String? {
        let normalised = part.replacingOccurrences(of: "\r\n", with: "\n")
        guard let split = normalised.range(of: "\n\n") else { return nil }
        let headers = self.headers(String(normalised[..<split.lowerBound]))
        let body = String(normalised[split.upperBound...])
        let type = headers["content-type"] ?? "text/plain"
        let lower = type.lowercased()
        if lower.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: type) else { return nil }
            let parts = body.components(separatedBy: "--" + boundary).dropFirst()
            for p in parts where !p.hasPrefix("--") {
                if let found = html(ofPart: p.hasPrefix("\n") ? String(p.dropFirst()) : p) { return found }
            }
            return nil
        }
        guard lower.hasPrefix("text/html") else { return nil }
        switch (headers["content-transfer-encoding"] ?? "").lowercased().trimmingCharacters(in: .whitespaces) {
        case "quoted-printable": return String(decoding: decodeQuotedPrintable(body), as: UTF8.self)
        case "base64":
            let compact = body.components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: compact).map { String(decoding: $0, as: UTF8.self) }
        default: return body
        }
    }

    /// Header names (lowercased) to values, with folded lines joined.
    static func headers(_ block: String) -> [String: String] {
        var out: [String: String] = [:]
        var last: String?
        for line in block.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", let key = last {
                out[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                out[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                last = key
            }
        }
        return out
    }

    /// A header parameter such as `boundary="abc"`.
    static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.components(separatedBy: ";").dropFirst() {
            let kv = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == name { return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
    }

    /// Quoted-printable to bytes: "=3D" is "=", a "=" at a line's end joins it to the next.
    static func decodeQuotedPrintable(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }            // soft break
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                    out.append(hi << 4 | lo); i += 3; continue
                }
            }
            out.append(b); i += 1
        }
        return out
    }

    // MARK: The alert's HTML

    /// The papers an alert lists. Each is an `<h3>` holding a link to the paper (through Scholar's
    /// redirect), maybe marked "[PDF]", followed by a byline `<div>` ("A Author, B Author - Venue,
    /// 2026") and a snippet. Read by shape rather than class names, which Google may change.
    static func papers(inAlert html: String) -> [Suggestion] {
        let blocks = html.components(separatedBy: "<h3").dropFirst()
        return blocks.compactMap { block -> Suggestion? in
            guard let close = block.range(of: "</h3>") else { return nil }
            let heading = String(block[..<close.lowerBound])
            let after = String(block[close.upperBound...])
            guard let link = firstMatch(#"<a\s[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: heading),
                  link.count == 3 else { return nil }
            let title = text(link[2])
            guard !title.isEmpty, let target = targetURL(decodeEntities(link[1])) else { return nil }
            let byline = firstMatch(#"<div[^>]*>(.*?)</div>"#, in: after).map { text($0[1]) } ?? ""
            let snippet = firstMatch(#"<div[^>]*class="[^"]*sni[^"]*"[^>]*>(.*?)</div>"#, in: after).map { text($0[1]) }
            let (authors, year) = parseByline(byline)
            let links = paperLinks(target, markedPDF: heading.contains("[PDF]"))
            let doi = self.doi(in: target)
            return Suggestion(id: Suggestions.key(title: title, doi: doi), title: title, authors: authors, year: year,
                              abstract: snippet, doi: doi, pageURL: links.page, pdfURL: links.pdf,
                              source: .scholarAlert, reason: nil)
        }
    }

    /// Scholar's redirect ("…/scholar_url?url=https://…&hl=en") unwrapped to the paper's own address.
    static func targetURL(_ href: String) -> String? {
        guard let c = URLComponents(string: href), c.scheme?.hasPrefix("http") == true else { return nil }
        if c.host?.contains("scholar.google.") == true, let inner = c.queryItems?.first(where: { $0.name == "url" })?.value {
            return inner
        }
        return href
    }

    /// Where to read the paper and where its free PDF is: arXiv gives both; a "[PDF]" link or a
    /// .pdf address is the PDF itself.
    static func paperLinks(_ url: String, markedPDF: Bool) -> (page: String, pdf: String?) {
        if let id = firstMatch(#"arxiv\.org/(?:abs|pdf)/([0-9]{4}\.[0-9]{4,5})"#, in: url)?[1] {
            return ("https://arxiv.org/abs/" + id, "https://arxiv.org/pdf/" + id)
        }
        let path = URLComponents(string: url)?.path.lowercased() ?? ""
        return (url, markedPDF || path.hasSuffix(".pdf") ? url : nil)
    }

    /// A DOI in a publisher's address ("doi.org/10.1/x", "/doi/10.1/x"), if there is one.
    static func doi(in url: String) -> String? {
        guard let raw = firstMatch(#"(10\.[0-9]{4,9}/[^?#&\s]+)"#, in: url)?[1] else { return nil }
        let doi = raw.removingPercentEncoding ?? raw
        return doi.lowercased().hasSuffix(".pdf") ? String(doi.dropLast(4)) : doi
    }

    /// "A Vaswani, N Shazeer… - arXiv preprint arXiv:1706.03762, 2017" → the names and 2017.
    static func parseByline(_ byline: String) -> (authors: [String], year: Int?) {
        let parts = byline.components(separatedBy: " - ")
        let authors = (parts.first ?? "").components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "…"))) }
            .filter { !$0.isEmpty }
        let rest = parts.dropFirst().joined(separator: " - ")
        let years = matches(#"\b((?:19|20)[0-9]{2})\b"#, in: rest).compactMap { Int($0[1]) }
        return (parts.count > 1 ? authors : [], years.last)
    }

    /// HTML to plain text: tags dropped, entities decoded, spaces collapsed.
    static func text(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(noTags).singleSpaced
    }

    /// The entities alerts use: named ones and numeric ones.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&nbsp;": " ", "&hellip;": "…", "&ndash;": "–", "&mdash;": "—"]
        var out = s
        for (k, v) in named where k != "&amp;" { out = out.replacingOccurrences(of: k, with: v) }
        for m in matches(#"&#(x?[0-9a-fA-F]+);"#, in: out) {
            let code = m[1].hasPrefix("x") ? UInt32(m[1].dropFirst(), radix: 16) : UInt32(m[1])
            if let code, let scalar = Unicode.Scalar(code) { out = out.replacingOccurrences(of: m[0], with: String(Character(scalar))) }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")   // last, so "&amp;lt;" stays "&lt;"
    }

    // MARK: Regex helpers

    /// The first match's groups (the whole match first), case-insensitive, "." across lines.
    private static func firstMatch(_ pattern: String, in s: String) -> [String]? { matches(pattern, in: s).first }

    private static func matches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
}
