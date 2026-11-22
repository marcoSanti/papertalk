// Where suggested papers come from and how their PDFs arrive: Semantic Scholar's
// recommendations, a direct download of a free PDF, and the Downloads folder.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a check for suggested papers failed, in words for the Suggested Papers window.
struct SuggestionError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Semantic Scholar's Recommendations API: papers like a list of example papers. No key needed;
/// unknown ids among the examples are skipped by the service.
struct SemanticScholar {
    var endpoint = "https://api.semanticscholar.org/recommendations/v1/papers/"

    /// Up to `limit` papers like `seeds` (`Suggestions.seeds`).
    func recommendations(for seeds: [String], limit: Int = 30) async throws -> [Suggestion] {
        var c = URLComponents(string: endpoint)!
        c.queryItems = [URLQueryItem(name: "fields", value: Suggestions.semanticScholarFields),
                        URLQueryItem(name: "limit", value: String(limit))]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["positivePaperIds": seeds])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = resp.httpStatus ?? 0
        guard status == 200 else { throw SuggestionError(message: L("Semantic Scholar answered HTTP {0}.", status)) }
        guard let found = Suggestions.parseSemanticScholar(data) else {
            throw SuggestionError(message: L("Semantic Scholar sent a reply Papertalk can't read."))
        }
        return found
    }
}

/// Getting a suggested paper's PDF without the user.
enum PaperDownload {
    /// The PDF at `url`, or nil when it isn't one (a landing page, a login wall, an error).
    static func pdf(at url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              resp.httpStatus == 200, isPDF(data) else { return nil }
        return data
    }

    /// The file starts like a PDF.
    static func isPDF(_ data: Data) -> Bool { data.prefix(5) == Data("%PDF-".utf8) }

    /// The user's Downloads folder.
    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// The folder's files and their sizes (empty when it can't be read).
    static func listing(_ folder: URL) -> [String: Int64] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var out: [String: Int64] = [:]
        for u in urls { out[u.lastPathComponent] = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return out
    }
}
