import AppKit
import UserNotifications

/// System notifications for things that happen while the user is in another
/// app: an episode finished or failed, or an import is waiting for an answer.
/// Nothing is posted while Papertalk is frontmost — the window already shows it.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the paper id when the user clicks a notification.
    var onOpen: ((String) -> Void)?

    /// `UNUserNotificationCenter` needs a real app bundle; a bare `swift run`
    /// binary would crash on first use, so notifications are simply skipped there.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    private var askedPermission = false

    override init() {
        super.init()
        center?.delegate = self
    }

    /// Ask for permission once, the first time it's relevant (an import starts).
    func requestPermissionIfNeeded() {
        guard let center, !askedPermission else { return }
        askedPermission = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    enum Event {
        case ready, failed(String), needsInput(String)
    }

    func post(_ event: Event, paperId: String, title: String) {
        // No app bundle (tests, `swift run`) or frontmost: nothing to post.
        guard let center, !(NSApp?.isActive ?? true) else { return }
        let content = UNMutableNotificationContent()
        content.userInfo = ["paperId": paperId]
        content.sound = .default
        let identifier: String
        switch event {
        case .ready:
            content.title = "Episode ready"
            content.body = title
            identifier = "ready-\(paperId)"
        case .failed(let reason):
            content.title = "Conversion failed"
            content.body = "\(title): \(reason)"
            identifier = "failed-\(paperId)"
        case .needsInput(let question):
            content.title = question
            content.body = title
            content.interruptionLevel = .timeSensitive
            identifier = "input-\(paperId)"
            // Also bounce the Dock icon until the app is brought forward.
            NSApp?.requestUserAttention(.criticalRequest)
        }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Withdraw a "your input is needed" notification once it's been answered.
    func clearInputRequest(paperId: String) {
        center?.removeDeliveredNotifications(withIdentifiers: ["input-\(paperId)"])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["paperId"] as? String
        Task { @MainActor in
            NSApp.activate()
            if let id { self.onOpen?(id) }
        }
        completionHandler()
    }

    /// Frontmost: don't show a banner (we normally don't post at all then).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
