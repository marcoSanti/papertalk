// The Settings page for Google Scholar alert emails: the form's values and rules, and its
// wording (how to get alerts and an app password, the Test Connection result).

import Foundation

/// Settings → Suggested Papers: the mail account Scholar alerts are read from.
struct MailSettingsForm: Equatable {
    var enabled: Bool
    var host: String
    /// As typed; `settings` keeps the saved port when it isn't a number in range.
    var port: String
    var account: String
    var password: String
    var mailbox: String
    /// One of `MailSettings.lookBackChoices`.
    var lookBackDays: Int
    private let savedPort: Int

    init(_ s: MailSettings, password: String) {
        enabled = s.enabled
        host = s.host
        port = String(s.port)
        account = s.account
        self.password = password
        mailbox = s.mailbox
        lookBackDays = s.lookBack
        savedPort = s.port
    }

    /// What to save: trimmed, an empty server or mailbox back to the default.
    var settings: MailSettings {
        let d = MailSettings()
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedBox = mailbox.trimmingCharacters(in: .whitespaces)
        return MailSettings(enabled: enabled, host: trimmedHost.isEmpty ? d.host : trimmedHost,
                            port: portNumber ?? savedPort, account: account.trimmingCharacters(in: .whitespaces),
                            mailbox: trimmedBox.isEmpty ? d.mailbox : trimmedBox, lookBackDays: lookBackDays)
    }

    private var portNumber: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65_535).contains($0) ? $0 : nil } }

    /// Under the port field when it isn't a port; nil when it is.
    var portProblem: String? { portNumber == nil ? L("Enter a port from 1 to 65535.") : nil }

    /// An account and a password to sign in with.
    var canTest: Bool { !account.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && portNumber != nil }

    // MARK: Wording

    static var title: String { L("Google Scholar alerts") }
    static var enableToggle: String { L("Read my Google Scholar alert emails") }
    static var intro: String {
        L("Papertalk signs in to your mailbox, reads only the alert emails Google Scholar sent since the last check, and adds their papers to Suggested Papers. It never changes or deletes mail.")
    }
    /// How to get alerts and a password, step by step.
    static var steps: [String] {
        [L("Create alerts at scholar.google.com: open the menu, then Alerts. Recommended articles and new citations to your papers work too."),
         L("For Gmail, turn on 2-Step Verification, then make an app password at myaccount.google.com/apppasswords and paste it below."),
         L("If a Gmail filter skips the inbox for alerts, set the mailbox to [Gmail]/All Mail.")]
    }
    static var serverLabel: String { L("IMAP server") }
    static var portLabel: String { L("Port") }
    static var accountLabel: String { L("Email address") }
    static var passwordLabel: String { L("App password") }
    static var passwordHelp: String { L("Kept in the Keychain, never in Papertalk's settings file.") }
    static var mailboxLabel: String { L("Mailbox") }
    static var lookBackLabel: String { L("Look back") }
    /// Under the look-back picker: what it limits and how a long one is read.
    static var lookBackHelp: String {
        L("Alert emails older than this are never read. Each check reads up to 20 alert emails it hasn't read before, newest first, so a long look-back is worked through over a few days.")
    }
    /// The picker's choices, with their names: "1 week", "2 weeks", "30 days", "1 year".
    static var lookBackOptions: [(days: Int, label: String)] {
        MailSettings.lookBackChoices.map { ($0, lookBackLabel(days: $0)) }
    }
    static func lookBackLabel(days: Int) -> String {
        switch days {
        case 7: return L("1 week")
        case 14: return L("2 weeks")
        case 365: return L("1 year")
        default: return L("{0} days", days)
        }
    }
    static func testButton(testing: Bool) -> String { testing ? L("Testing…") : L("Test Connection") }

    /// The Test Connection result, over the chosen look-back.
    static func testSucceeded(alerts n: Int, days: Int) -> String {
        switch n {
        case 0: return L("Signed in. No Google Scholar alert emails in the last {0} days: create some at scholar.google.com.", days)
        case 1: return L("Signed in. Found 1 Google Scholar alert email from the last {0} days.", days)
        default: return L("Signed in. Found {0} Google Scholar alert emails from the last {1} days.", n, days)
        }
    }
    static func testFailed(_ reason: String) -> String { L("Couldn't read the alerts: {0}", reason) }
}
