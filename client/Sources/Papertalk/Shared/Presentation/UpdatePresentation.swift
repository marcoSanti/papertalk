// Checking GitHub for a newer release: version parsing and ordering, the running build's
// version, which release is newest on each channel, and the alert that reports it.
// The network calls are in `UpdateChecker`.

import Foundation

/// Which kind of release "Check for Updates" looks at.
enum ReleaseChannel: Equatable {
    /// Tagged releases (`v1.2.3`), marked Latest on GitHub.
    case stable
    /// Pre-releases built from every merge to `main` (`v1.2.3-dev.<commit>`).
    case dev
}

/// A release version as the release workflow writes it: `1.2.3` for stable
/// builds, `1.2.3-dev.<short commit>` for dev builds. A leading `v` is accepted.
struct ReleaseVersion: Equatable {
    /// The MAJOR.MINOR.PATCH numbers.
    let major: Int, minor: Int, patch: Int
    /// The short commit of a dev build; nil for a stable release.
    let devCommit: String?

    /// Parses "1.2.3", "v1.2.3" or "1.2.3-dev.abc1234"; nil for anything else.
    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        let core = parts.first?.split(separator: ".").compactMap { Int($0) } ?? []
        guard core.count == 3, parts.first?.split(separator: ".").count == 3 else { return nil }
        (major, minor, patch) = (core[0], core[1], core[2])
        if parts.count == 2 {
            guard parts[1].hasPrefix("dev."), parts[1].count > 4 else { return nil }
            devCommit = String(parts[1].dropFirst(4))
        } else {
            devCommit = nil
        }
    }

    /// The version as tagged, without the "v".
    var text: String { "\(major).\(minor).\(patch)" + (devCommit.map { "-dev.\($0)" } ?? "") }

    /// Compares MAJOR.MINOR.PATCH only.
    func compareCore(_ other: ReleaseVersion) -> ComparisonResult {
        let a = [major, minor, patch], b = [other.major, other.minor, other.patch]
        for (x, y) in zip(a, b) where x != y { return x < y ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    /// Semver order, as far as the versions alone can tell: a dev build comes
    /// before the release of the same number. Two dev builds of the same number
    /// can't be ordered without git history, so they compare as the same.
    func compare(_ other: ReleaseVersion) -> ComparisonResult {
        let core = compareCore(other)
        guard core == .orderedSame else { return core }
        switch (devCommit == nil, other.devCommit == nil) {
        case (false, true): return .orderedAscending
        case (true, false): return .orderedDescending
        default: return .orderedSame
        }
    }
}

/// The running app's version and commit, read from its Info.plist (the
/// Makefile stamps both; the build number is the short commit hash).
struct AppBuild: Equatable {
    /// CFBundleShortVersionString; nil when not built as an app (`swift run`).
    var version: String?
    /// The short commit hash stamped as CFBundleVersion.
    var commit: String?

    /// Read from an Info.plist dictionary (ignores a build number that isn't a hash).
    static func from(info: [String: Any]?) -> AppBuild {
        let commit = (info?["CFBundleVersion"] as? String).flatMap { isCommitHash($0) ? $0 : nil }
        return AppBuild(version: info?["CFBundleShortVersionString"] as? String, commit: commit)
    }
    /// This running copy.
    static var current: AppBuild { from(info: Bundle.main.infoDictionary) }

    /// The version, parsed.
    var release: ReleaseVersion? { version.flatMap(ReleaseVersion.init) }

    /// "0.0.1 (a1b2c3d)", as About Papertalk shows it.
    var display: String {
        guard let version else { return L("an unknown version") }
        guard let commit, release?.devCommit == nil else { return version }
        return "\(version) (\(commit))"
    }

    private static func isCommitHash(_ s: String) -> Bool {
        s.count >= 4 && s.allSatisfy(\.isHexDigit)
    }
}

/// One entry of GitHub's release list.
struct GitHubRelease: Decodable, Equatable {
    /// e.g. "v1.2.3" or "v1.2.3-dev.abc1234".
    let tagName: String
    /// The release page.
    let htmlURL: URL
    /// Dev builds are published as pre-releases.
    let prerelease: Bool
    /// Unpublished; never offered.
    let draft: Bool
    /// The files attached to the release (the app zip and its checksum, the source).
    var assets: [Asset]? = nil

    /// One file attached to a release.
    struct Asset: Decodable, Equatable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, downloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", prerelease, draft, assets
    }
}

/// Installing a stable release in place: which files to fetch, how to check them, and the
/// script that swaps the app once it has quit. The downloading is `UpdateInstaller`'s.
enum UpdateInstall {
    /// Where to download the app zip and its checksum from.
    struct Files: Equatable {
        let zip: URL
        let checksum: URL
    }

    /// The release's `Papertalk-<version>.zip` and `.zip.sha256` (as the release workflow
    /// names them); nil when either is missing.
    static func files(for c: UpdateCheck.Candidate) -> Files? {
        let name = "Papertalk-\(c.version.text).zip"
        let assets = c.release.assets ?? []
        guard let zip = assets.first(where: { $0.name == name }),
              let sum = assets.first(where: { $0.name == name + ".sha256" }) else { return nil }
        return Files(zip: zip.downloadURL, checksum: sum.downloadURL)
    }

    /// Whether an update can be installed over the running copy at `app`: it's an app bundle
    /// with a version, and the release has the files.
    static func canInstall(_ c: UpdateCheck.Candidate, build: AppBuild, app: URL) -> Bool {
        app.pathExtension == "app" && build.release != nil && files(for: c) != nil
    }

    /// The SHA-256 in a `shasum -a 256` line ("<hex>  <file>"), lowercased; nil if there is none.
    static func checksum(in text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = first.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// Whether the unzipped app is Papertalk (`bundleId`) at the version that was offered.
    static func isExpectedApp(info: [String: Any]?, bundleId: String?, version: ReleaseVersion) -> Bool {
        guard let info, let id = info["CFBundleIdentifier"] as? String,
              let v = (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init) else { return false }
        return id == bundleId && v == version
    }

    /// The shell script that waits for the app (`$1`, a pid) to quit, swaps the installed app
    /// (`$2`) for `Papertalk.app` in the staging folder (`$3`, on the same volume), removes the
    /// staging folder and the old app, and opens the app unless `$4` is 0. If the new app can't
    /// be moved in, the old one goes back. Run as `/bin/sh -c script sh pid app staging open`.
    static let swapScript = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$2" "$3/Papertalk-old.app"; then
          mv "$3/Papertalk.app" "$2" || mv "$3/Papertalk-old.app" "$2"
        fi
        rm -rf "$3"
        [ "$4" = 0 ] || open "$2"
        """

    /// Why an install stopped, worded for the alert.
    enum Failure: Error, Equatable {
        case download, checksum, unzip, notPapertalk, notWritable(String), unsupported

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
}

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

/// Deciding whether a newer release exists. The network part lives in `UpdateChecker`.
enum UpdateCheck {
    /// The GitHub repository releases are published to.
    static let repository = "marcoSanti/papertalk"
    /// The API listing of releases (newest first).
    static let releasesURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!
    /// The releases page, opened by the alert's button.
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    /// GitHub's "compare two commits" endpoint, used to order dev builds.
    static func compareURL(base: String, head: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/compare/\(base)...\(head)")!
    }

    /// A release with its parsed version.
    struct Candidate: Equatable {
        let release: GitHubRelease
        let version: ReleaseVersion
    }

    /// What a check found.
    enum Outcome: Equatable {
        case available(Candidate)
        case upToDate(Candidate)
        case noRelease
        /// The running copy has no version (e.g. `swift run`), so nothing to compare with.
        case unknownBuild(Candidate)
        case failed(String)
    }

    /// The newest published release on `channel`. Stable: the highest
    /// non-pre-release version. Dev: the first dev pre-release, since GitHub
    /// lists releases newest first and dev numbers alone don't order them.
    static func newest(in releases: [GitHubRelease], channel: ReleaseChannel) -> Candidate? {
        let parsed = releases.filter { !$0.draft }.compactMap { r in
            ReleaseVersion(r.tagName).map { Candidate(release: r, version: $0) }
        }
        switch channel {
        case .stable:
            return parsed.filter { !$0.release.prerelease && $0.version.devCommit == nil }
                .max { $0.version.compare($1.version) == .orderedAscending }
        case .dev:
            return parsed.first { $0.version.devCommit != nil }
        }
    }

    /// When the dev build and the running app share a version number but not a
    /// commit, only git history can tell which is newer: the commits to ask
    /// GitHub about, as (base: ours, head: theirs).
    static func commitsToCompare(build: AppBuild, newest: Candidate?, channel: ReleaseChannel) -> (base: String, head: String)? {
        guard channel == .dev, let newest, let theirs = newest.version.devCommit,
              let ours = build.commit, let current = build.release,
              !sameCommit(ours, theirs), newest.version.compareCore(current) == .orderedSame else { return nil }
        return (ours, theirs)
    }

    /// `devIsAhead`: GitHub's answer for `commitsToCompare` (nil when it wasn't
    /// asked or couldn't say). Unknown counts as newer, so a dev build is offered
    /// rather than silently hidden.
    static func outcome(build: AppBuild, newest: Candidate?, channel: ReleaseChannel, devIsAhead: Bool? = nil) -> Outcome {
        guard let newest else { return .noRelease }
        if channel == .dev, let ours = build.commit, let theirs = newest.version.devCommit, sameCommit(ours, theirs) {
            return .upToDate(newest)
        }
        guard let current = build.release else { return .unknownBuild(newest) }
        switch channel {
        case .stable:
            return newest.version.compare(current) == .orderedDescending ? .available(newest) : .upToDate(newest)
        case .dev:
            switch newest.version.compareCore(current) {
            case .orderedDescending: return .available(newest)
            case .orderedAscending: return .upToDate(newest)
            case .orderedSame: return devIsAhead == false ? .upToDate(newest) : .available(newest)
            }
        }
    }

    /// Short hashes can differ in length (git lengthens them when ambiguous).
    static func sameCommit(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Whether GitHub's compare `status` means `head` has commits `base` lacks.
    static func headIsAhead(compareStatus: String) -> Bool? {
        switch compareStatus {
        case "ahead", "diverged": return true
        case "identical", "behind": return false
        default: return nil
        }
    }

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
