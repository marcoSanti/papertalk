// What every HTTP client in the app does the same way.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URL {
    /// `text` as an http(s) URL with a host; nil for anything else (typed URLs can be anything).
    static func web(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

extension URLRequest {
    /// Send `token` as a bearer token; nothing when it's empty.
    mutating func setBearer(_ token: String) {
        if !token.isEmpty { setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }
}

extension URLResponse {
    /// The HTTP status; nil for a response that isn't HTTP.
    var httpStatus: Int? { (self as? HTTPURLResponse)?.statusCode }
    /// An HTTP answer with a 2xx status.
    var isSuccess: Bool { httpStatus.map { (200..<300).contains($0) } ?? false }
}

/// The wait between tries of a failed request.
enum RetryDelay {
    /// Nanoseconds to wait after try `attempt` (from 0): 1 s, 2 s, 4 s… at most 8 s.
    static func after(attempt: Int) -> UInt64 { UInt64(min(1 << attempt, 8)) * 1_000_000_000 }
}
