import Foundation

/// Reads Papertalk's releases from the public GitHub API (no token, so
/// GitHub's unauthenticated rate limit applies). Decisions are in `UpdateCheck`.
struct UpdateChecker {
    enum Failure: Error, Equatable {
        case http(Int?)
        case unreadable

        var message: String {
            switch self {
            case .http(let status): return UpdateCheck.failureMessage(httpStatus: status)
            case .unreadable: return UpdateCheck.unreadableMessage
            }
        }
    }

    func releases() async throws(Failure) -> [GitHubRelease] {
        let data = try await get(UpdateCheck.releasesURL)
        guard let list = try? JSONDecoder().decode([GitHubRelease].self, from: data) else { throw .unreadable }
        return list
    }

    /// Whether `head` has commits that `base` lacks, or nil if GitHub can't say
    /// (e.g. `base` was never pushed).
    func isAhead(base: String, head: String) async -> Bool? {
        guard let data = try? await get(UpdateCheck.compareURL(base: base, head: head)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else { return nil }
        return UpdateCheck.headIsAhead(compareStatus: status)
    }

    private func get(_ url: URL) async throws(Failure) -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { throw .http(nil) }
        guard (200..<300).contains(http.statusCode) else { throw .http(http.statusCode) }
        return data
    }
}
