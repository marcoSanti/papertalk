// What checking for and installing an update says: the build's version, why either failed, and
// the alert that reports it. The rules are in `Models/AppUpdate.swift`.

import Foundation

/// Wording for checking at startup.
enum UpdatePreferencePresentation {
    /// The toggle in setup and in Settings → General.
    static var toggle: String { L("Check for updates when Papertalk starts") }
    /// Under the toggle.
    static var note: String { L("Papertalk asks GitHub for a newer release at startup and offers to install it. Nothing is installed without asking.") }
    /// The question asked once at startup when the choice was never made.
    static var askTitle: String { L("Check for updates automatically?") }
    static var askMessage: String { L("Papertalk can look for a new release each time it starts and offer to install it. You can change this in Settings → General.") }
    static var askYes: String { L("Check Automatically") }
    static var askNo: String { L("Don’t Check") }
    /// The toast while an update downloads.
    static func downloading(_ version: String) -> String { L("Downloading Papertalk {0}…", version) }
}

/// What the update alert says, and where its button leads.
struct UpdateAlert: Identifiable, Equatable {
    /// The alert's title.
    let title: String
    /// The alert's text.
    let message: String
    /// The button that opens `link`; nil for an alert with only OK.
    let actionLabel: String?
    /// The page `actionLabel` opens.
    let link: URL?
    /// The release `actionLabel` installs in place (then `link` is only the fallback).
    var install: UpdateCheck.Candidate? = nil
    var id: String { title + message }

    /// The alert for a check's outcome on `channel`. `installable`: a stable update can be
    /// installed in place (`UpdateInstall.canInstall`).
    init(_ outcome: UpdateCheck.Outcome, channel: ReleaseChannel, build: AppBuild, installable: Bool = false) {
        switch outcome {
        case .available(let c) where channel == .stable && installable:
            title = L("Papertalk {0} is available", c.version.text)
            message = L("You have {0}. Install it now? Papertalk quits, updates itself and opens again.", build.display)
            actionLabel = L("Install and Relaunch")
            link = c.release.htmlURL
            install = c
        case .available(let c):
            title = channel == .stable
                ? L("Papertalk {0} is available", c.version.text)
                : L("A newer dev build is available")
            message = channel == .stable
                ? L("You have {0}. Download the new version from its release page, unzip it and replace Papertalk in Applications.", build.display)
                : L("Dev build {0} has the newest changes from main; you have {1}. Dev builds may have rough edges.", c.version.text, build.display)
            actionLabel = L("View Release")
            link = c.release.htmlURL
        case .upToDate(let c):
            title = L("Papertalk is up to date")
            message = channel == .stable
                ? L("{0} is the latest release. You have {1}.", c.version.text, build.display)
                : L("Dev build {0} is the newest; you have {1}.", c.version.text, build.display)
            actionLabel = nil
            link = nil
        case .noRelease:
            title = channel == .stable ? L("No releases yet") : L("No dev builds yet")
            message = channel == .stable
                ? L("There is no stable release of Papertalk yet. Dev builds of main may be available: use Check for Dev Builds.")
                : L("There are no dev builds of Papertalk on GitHub right now.")
            actionLabel = L("Open Releases")
            link = UpdateCheck.releasesPage
        case .unknownBuild(let c):
            title = L("Can’t tell which version this is")
            message = channel == .stable
                ? L("This copy of Papertalk wasn’t built as an app, so it has no version to compare. The newest release is {0}.", c.version.text)
                : L("This copy of Papertalk wasn’t built as an app, so it has no version to compare. The newest dev build is {0}.", c.version.text)
            actionLabel = L("View Release")
            link = c.release.htmlURL
        case .failed(let reason):
            title = L("Couldn’t check for updates")
            message = reason
            actionLabel = nil
            link = nil
        }
    }

    /// An install of `c` that failed: why, with its release page to do it by hand.
    init(installFailed failure: UpdateInstall.Failure, _ c: UpdateCheck.Candidate) {
        title = L("Couldn’t install Papertalk {0}", c.version.text)
        message = failure.message
        actionLabel = L("View Release")
        link = c.release.htmlURL
    }
}

extension AppBuild {
    /// "0.0.1 (a1b2c3d)", as About Papertalk shows it.
    var display: String {
        guard let version else { return L("an unknown version") }
        guard let commit, release?.devCommit == nil else { return version }
        return "\(version) (\(commit))"
    }
}

extension UpdateInstall.Failure {
    var message: String {
        switch self {
        case .download: return L("The update couldn’t be downloaded. Check your internet connection and try again.")
        case .checksum: return L("The downloaded update didn’t match its checksum, so it wasn’t installed. Try again later.")
        case .unzip: return L("The downloaded update couldn’t be unpacked. Try again later.")
        case .notPapertalk: return L("The downloaded file isn’t the expected version of Papertalk, so it wasn’t installed.")
        case .notWritable(let folder): return L("Papertalk can’t replace itself in {0}. Install the update from its release page instead.", folder)
        case .unsupported: return L("Installing updates isn’t supported on this system yet. Use the release page instead.")
        }
    }
}

extension UpdateCheck {
    /// Why GitHub couldn't be asked, by HTTP status (nil: no answer at all).
    static func failureMessage(httpStatus: Int?) -> String {
        switch httpStatus {
        case nil:
            return L("Papertalk couldn’t reach GitHub. Check your internet connection and try again.")
        case 403, 429:
            return L("GitHub is limiting requests from this network for now. Try again in an hour.")
        case let code?:
            return L("GitHub answered with an error (HTTP {0}). Try again later.", code)
        }
    }
    /// GitHub answered, but not with a release list.
    static var unreadableMessage: String { L("GitHub’s answer couldn’t be read. Try again later, or look at the releases page.") }
}
