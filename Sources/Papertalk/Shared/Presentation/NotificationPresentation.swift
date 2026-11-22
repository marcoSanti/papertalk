// What a system notification says, the same on macOS and Linux.

import Foundation

extension NotificationEvent {
    /// The notification's two lines, for the paper titled `title`.
    func content(title: String) -> (title: String, body: String) {
        switch self {
        case .ready: return (L("Episode ready"), title)
        case .failed(let reason): return (L("Conversion failed"), "\(title): \(reason)")
        case .needsInput(let question): return (question, title)
        case .suggestions(let found): return (title, found)
        }
    }
}
