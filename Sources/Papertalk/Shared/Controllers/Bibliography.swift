// Looking a DOI up: its BibTeX citation from doi2bib, and its publication date and reference
// list from Crossref.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The two DOI registries the app asks. Neither can fail an import: both answer nil instead.
enum Bibliography {
    /// Ask doi2bib to turn a DOI into a BibTeX citation. Returns nil on any
    /// failure, so citation resolution never blocks or fails an import.
    static func citation(doi: String) async -> String? {
        guard let doi = lookupDOI(doi),
              let url = URL(string: "https://www.doi2bib.org/8350e5a3e24c153df2275c9f80692773/doi2bib?id=" + doi),
              let data = await body(url) else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("@") ? s : nil
    }

    /// Best-effort publication date (YYYY, YYYY-MM or YYYY-MM-DD; nil when the registry has
    /// none) and reference list for a DOI, from Crossref. Nil when the lookup fails.
    static func crossref(doi: String) async -> (published: String?, references: [CitedPaper])? {
        guard let doi = lookupDOI(doi),
              let url = URL(string: "https://api.crossref.org/works/" + (doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi)),
              let data = await body(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else { return nil }
        let references = CitedPaper.fromCrossref(message)
        let parts = (message["published"] as? [String: Any])?["date-parts"] as? [[Int]]
            ?? (message["issued"] as? [String: Any])?["date-parts"] as? [[Int]]
        guard let p = parts?.first, p.first ?? 0 > 0 else { return (nil, references) }
        var s = String(p[0])
        if p.count > 1, p[1] > 0 {
            s += String(format: "-%02d", p[1])
            if p.count > 2, p[2] > 0 { s += String(format: "-%02d", p[2]) }
        }
        return (s, references)
    }

    /// The DOI as the registries are sent it; nil when empty.
    private static func lookupDOI(_ doi: String) -> String? {
        var doi = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !doi.isEmpty else { return nil }
        if doi.hasPrefix("doi:") { doi = String(doi.dropFirst(4)) }
        return CitedPaper.afterResolver(doi)
    }

    /// A 2xx answer's body; nil for anything else.
    private static func body(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isSuccess else { return nil }
        return data
    }
}
