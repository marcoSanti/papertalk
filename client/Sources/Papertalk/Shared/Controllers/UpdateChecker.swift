// The network half of "Check for Updates": fetching the release list and comparing commits
// on GitHub. What the answers mean is decided in `UpdateCheck`.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads Papertalk's releases from the public GitHub API (no token, so
/// GitHub's unauthenticated rate limit applies). Decisions are in `UpdateCheck`.
struct UpdateChecker {
    /// Why GitHub couldn't answer; `message` words it for the alert.
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

    /// Every published release, newest first.
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

    /// GET from the GitHub API; any failure becomes `Failure.http`.
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
