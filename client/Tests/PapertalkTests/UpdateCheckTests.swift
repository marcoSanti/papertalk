import XCTest
@testable import Papertalk

/// Release parsing and the "is there something newer?" decision.
final class UpdateCheckTests: PapertalkTestCase {
    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> GitHubRelease {
        GitHubRelease(tagName: tag, htmlURL: URL(string: "https://github.com/x/y/releases/tag/\(tag)")!,
                      prerelease: prerelease, draft: draft)
    }
    private func candidate(_ tag: String, prerelease: Bool = false) -> UpdateCheck.Candidate {
        UpdateCheck.Candidate(release: release(tag, prerelease: prerelease), version: ReleaseVersion(tag)!)
    }

    func testParsesVersions() {
        XCTAssertEqual(ReleaseVersion("v1.2.3")?.text, "1.2.3")
        XCTAssertEqual(ReleaseVersion("0.0.1-dev.a1b2c3d")?.devCommit, "a1b2c3d")
        XCTAssertNil(ReleaseVersion("1.2"))
        XCTAssertNil(ReleaseVersion("1.2.3.4"))
        XCTAssertNil(ReleaseVersion("1.2.x"))
        XCTAssertNil(ReleaseVersion("1.2.3-beta.1"))
        XCTAssertNil(ReleaseVersion("1.2.3-dev."))
    }

    func testVersionOrder() {
        let v = { ReleaseVersion($0)! }
        XCTAssertEqual(v("0.1.0").compare(v("0.0.9")), .orderedDescending)
        XCTAssertEqual(v("1.0.0").compare(v("1.0.1")), .orderedAscending)
        XCTAssertEqual(v("1.0.0-dev.abc1").compare(v("1.0.0")), .orderedAscending)
        XCTAssertEqual(v("1.0.0").compare(v("1.0.0-dev.abc1")), .orderedDescending)
        XCTAssertEqual(v("1.0.0-dev.abc1").compare(v("1.0.0-dev.def2")), .orderedSame)
        XCTAssertEqual(v("1.0.0-dev.abc1").compareCore(v("1.0.0")), .orderedSame)
    }

    func testBuildFromInfoPlist() {
        let b = AppBuild.from(info: ["CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "a1b2c3d"])
        XCTAssertEqual(b, AppBuild(version: "0.0.1", commit: "a1b2c3d"))
        XCTAssertEqual(b.display, "0.0.1 (a1b2c3d)")
        // The source Info.plist's placeholder build number isn't a commit.
        XCTAssertNil(AppBuild.from(info: ["CFBundleVersion": "1"]).commit)
        XCTAssertEqual(AppBuild(version: "0.0.1-dev.a1b2c3d", commit: "a1b2c3d").display, "0.0.1-dev.a1b2c3d")
        XCTAssertEqual(AppBuild.from(info: nil).display, "an unknown version")
    }

    func testNewestPicksPerChannel() {
        let list = [release("v0.0.3-dev.ccc3", prerelease: true), release("v0.0.2"),
                    release("v0.0.9", draft: true), release("v0.0.10"), release("v0.0.3-dev.bbb2", prerelease: true),
                    release("nightly")]
        XCTAssertEqual(UpdateCheck.newest(in: list, channel: .stable)?.version.text, "0.0.10")
        XCTAssertEqual(UpdateCheck.newest(in: list, channel: .dev)?.version.text, "0.0.3-dev.ccc3")
        XCTAssertNil(UpdateCheck.newest(in: [release("v0.0.2")], channel: .dev))
        XCTAssertNil(UpdateCheck.newest(in: [release("v0.0.2", prerelease: true)], channel: .stable))
    }

    func testStableOutcomes() {
        let latest = candidate("v0.0.2")
        func outcome(_ version: String?) -> UpdateCheck.Outcome {
            UpdateCheck.outcome(build: AppBuild(version: version, commit: "abc1234"), newest: latest, channel: .stable)
        }
        XCTAssertEqual(outcome("0.0.1"), .available(latest))
        XCTAssertEqual(outcome("0.0.2-dev.abc1234"), .available(latest))
        XCTAssertEqual(outcome("0.0.2"), .upToDate(latest))
        XCTAssertEqual(outcome("0.0.3-dev.abc1234"), .upToDate(latest))
        XCTAssertEqual(outcome(nil), .unknownBuild(latest))
        XCTAssertEqual(UpdateCheck.outcome(build: AppBuild(), newest: nil, channel: .stable), .noRelease)
    }

    func testDevOutcomes() {
        let latest = candidate("v0.0.2-dev.bbb2222", prerelease: true)
        func outcome(_ version: String?, _ commit: String?, ahead: Bool? = nil) -> UpdateCheck.Outcome {
            UpdateCheck.outcome(build: AppBuild(version: version, commit: commit), newest: latest,
                                channel: .dev, devIsAhead: ahead)
        }
        XCTAssertEqual(outcome("0.0.2-dev.bbb2222", "bbb2222"), .upToDate(latest))
        XCTAssertEqual(outcome(nil, "bbb22"), .upToDate(latest), "same commit, shorter hash")
        XCTAssertEqual(outcome("0.0.1", "aaa1111"), .available(latest))
        XCTAssertEqual(outcome("0.0.3", "aaa1111"), .upToDate(latest))
        XCTAssertEqual(outcome("0.0.2", "aaa1111", ahead: false), .upToDate(latest))
        XCTAssertEqual(outcome("0.0.2", "aaa1111", ahead: true), .available(latest))
        XCTAssertEqual(outcome("0.0.2", "aaa1111", ahead: nil), .available(latest), "unknown order offers the build")
        XCTAssertEqual(outcome(nil, nil), .unknownBuild(latest))
    }

    func testCommitsToCompareOnlyForSameNumberDifferentCommit() {
        let latest = candidate("v0.0.2-dev.bbb2222", prerelease: true)
        let build = AppBuild(version: "0.0.2", commit: "aaa1111")
        XCTAssertEqual(UpdateCheck.commitsToCompare(build: build, newest: latest, channel: .dev)?.base, "aaa1111")
        XCTAssertEqual(UpdateCheck.commitsToCompare(build: build, newest: latest, channel: .dev)?.head, "bbb2222")
        XCTAssertNil(UpdateCheck.commitsToCompare(build: build, newest: latest, channel: .stable))
        XCTAssertNil(UpdateCheck.commitsToCompare(build: AppBuild(version: "0.0.1", commit: "aaa1111"), newest: latest, channel: .dev))
        XCTAssertNil(UpdateCheck.commitsToCompare(build: AppBuild(version: "0.0.2", commit: "bbb2222"), newest: latest, channel: .dev))
        XCTAssertNil(UpdateCheck.commitsToCompare(build: AppBuild(version: "0.0.2", commit: nil), newest: latest, channel: .dev))
    }

    func testCompareStatusAndFailures() {
        XCTAssertEqual(UpdateCheck.headIsAhead(compareStatus: "ahead"), true)
        XCTAssertEqual(UpdateCheck.headIsAhead(compareStatus: "diverged"), true)
        XCTAssertEqual(UpdateCheck.headIsAhead(compareStatus: "behind"), false)
        XCTAssertEqual(UpdateCheck.headIsAhead(compareStatus: "identical"), false)
        XCTAssertNil(UpdateCheck.headIsAhead(compareStatus: "?"))
        XCTAssertTrue(UpdateCheck.failureMessage(httpStatus: nil).contains("internet connection"))
        XCTAssertTrue(UpdateCheck.failureMessage(httpStatus: 403).contains("Try again in an hour"))
        XCTAssertTrue(UpdateCheck.failureMessage(httpStatus: 500).contains("HTTP 500"))
    }

    func testAlertWording() {
        let build = AppBuild(version: "0.0.1", commit: "aaa1111")
        let stable = candidate("v0.0.2")
        let dev = candidate("v0.0.2-dev.bbb2222", prerelease: true)

        let available = UpdateAlert(.available(stable), channel: .stable, build: build)
        XCTAssertEqual(available.title, "Papertalk 0.0.2 is available")
        XCTAssertTrue(available.message.contains("You have 0.0.1 (aaa1111)"))
        XCTAssertEqual(available.actionLabel, "View Release")
        XCTAssertEqual(available.link, stable.release.htmlURL)

        XCTAssertEqual(UpdateAlert(.available(dev), channel: .dev, build: build).title, "A newer dev build is available")
        let current = UpdateAlert(.upToDate(dev), channel: .dev, build: build)
        XCTAssertEqual(current.title, "Papertalk is up to date")
        XCTAssertNil(current.link)
        XCTAssertNil(current.actionLabel)
        XCTAssertTrue(UpdateAlert(.upToDate(stable), channel: .stable, build: build).message.hasPrefix("0.0.2 is the latest release"))

        XCTAssertEqual(UpdateAlert(.noRelease, channel: .stable, build: build).title, "No releases yet")
        XCTAssertEqual(UpdateAlert(.noRelease, channel: .dev, build: build).link, UpdateCheck.releasesPage)
        XCTAssertTrue(UpdateAlert(.unknownBuild(dev), channel: .dev, build: AppBuild()).message.contains("newest dev build is 0.0.2-dev.bbb2222"))
        let failed = UpdateAlert(.failed("Offline."), channel: .stable, build: build)
        XCTAssertEqual(failed.message, "Offline.")
        XCTAssertNil(failed.actionLabel)
    }
}

/// The store's update check, against a mocked GitHub API.
@MainActor
final class UpdateCheckStoreTests: PapertalkTestCase {
    private func makeStore(version: String?, commit: String?) -> AppStore {
        let store = AppStore(storage: LocalStorage(root: Fixtures.tempDir()))
        store.build = AppBuild(version: version, commit: commit)
        return store
    }

    private func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }
    private func releaseJSON(_ tag: String, prerelease: Bool = false) -> [String: Any] {
        ["tag_name": tag, "html_url": "https://github.com/marcoSanti/papertalk/releases/tag/\(tag)",
         "prerelease": prerelease, "draft": false]
    }

    func testStableUpdateAvailable() async {
        MockLLM.install { req in
            XCTAssertEqual(req.url, UpdateCheck.releasesURL)
            return (200, self.json([self.releaseJSON("v0.0.3-dev.ccc3333", prerelease: true), self.releaseJSON("v0.0.2")]))
        }
        let store = makeStore(version: "0.0.1", commit: "aaa1111")
        await store.checkForUpdates(.stable)
        XCTAssertEqual(store.updateAlert?.title, "Papertalk 0.0.2 is available")
        XCTAssertEqual(store.updateAlert?.link?.absoluteString, "https://github.com/marcoSanti/papertalk/releases/tag/v0.0.2")
        XCTAssertFalse(store.isCheckingForUpdates)
    }

    func testDevBuildOrderedByGitHubCompare() async {
        var compared: URL?
        MockLLM.install { req in
            if req.url!.path.contains("/compare/") {
                compared = req.url
                return (200, self.json(["status": "behind"]))
            }
            return (200, self.json([self.releaseJSON("v0.0.1-dev.bbb2222", prerelease: true)]))
        }
        let store = makeStore(version: "0.0.1", commit: "aaa1111")
        await store.checkForUpdates(.dev)
        XCTAssertEqual(compared, UpdateCheck.compareURL(base: "aaa1111", head: "bbb2222"))
        XCTAssertEqual(store.updateAlert?.title, "Papertalk is up to date")
    }

    func testDevCompareFailureStillOffersBuild() async {
        MockLLM.install { req in
            if req.url!.path.contains("/compare/") { return (404, Data()) }
            return (200, self.json([self.releaseJSON("v0.0.1-dev.bbb2222", prerelease: true)]))
        }
        let store = makeStore(version: "0.0.1", commit: "aaa1111")
        await store.checkForUpdates(.dev)
        XCTAssertEqual(store.updateAlert?.title, "A newer dev build is available")
    }

    func testRateLimitAndBadReplies() async {
        MockLLM.install { _ in (403, Data()) }
        let store = makeStore(version: "0.0.1", commit: "aaa1111")
        await store.checkForUpdates(.stable)
        XCTAssertEqual(store.updateAlert?.title, "Couldn’t check for updates")
        XCTAssertTrue(store.updateAlert?.message.contains("Try again in an hour") ?? false)

        MockLLM.install { _ in (200, Data("{}".utf8)) }
        await store.checkForUpdates(.stable)
        XCTAssertEqual(store.updateAlert?.message, UpdateCheck.unreadableMessage)

        MockLLM.install { _ in (200, self.json([])) }
        await store.checkForUpdates(.dev)
        XCTAssertEqual(store.updateAlert?.title, "No dev builds yet")
    }
}
