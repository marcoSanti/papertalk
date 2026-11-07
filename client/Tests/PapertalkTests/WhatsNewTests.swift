// Tests of the "What's new" screen: parsing the embedded changelog lines, when it shows, and
// that CHANGELOG.md's Unreleased entries follow the form the app reads.

import Foundation
import XCTest
@testable import Papertalk

@MainActor
final class WhatsNewTests: PapertalkTestCase {
    private let notes = "- 📚 **Cited papers**: listed one by one.\n- not an entry\n- 🎉 **No colon** still read"

    func testParseReadsEmojiTitleAndDetailAndSkipsOtherLines() {
        XCTAssertEqual(WhatsNew.parse(notes), [
            .init(emoji: "📚", title: "Cited papers", detail: "listed one by one."),
            .init(emoji: "🎉", title: "No colon", detail: "still read"),
        ])
    }

    func testShownOnceAfterAnUpdateNeverOnAFirstLaunch() {
        let build = AppBuild(version: "0.7.0", commit: nil, whatsNew: notes)
        XCTAssertEqual(WhatsNew.toShow(for: build, seen: nil, onboarded: true)?.title, "What's new in Papertalk 0.7.0")
        XCTAssertEqual(WhatsNew.toShow(for: build, seen: "older", onboarded: true)?.items.count, 2)
        XCTAssertNil(WhatsNew.toShow(for: build, seen: notes, onboarded: true))
        XCTAssertNil(WhatsNew.toShow(for: build, seen: nil, onboarded: false))
        XCTAssertNil(WhatsNew.toShow(for: AppBuild(version: "1", commit: nil), seen: nil, onboarded: true))
        XCTAssertNil(WhatsNew.toShow(for: AppBuild(version: "1", commit: nil, whatsNew: "junk"), seen: nil, onboarded: true))
    }

    func testStoreShowsItOnceAndHoldsBackTheUpdateQuestion() async {
        let defaults = UserDefaults(suiteName: "whatsnew-\(UUID().uuidString)")!
        let store = AppStore(storage: LocalStorage(root: Fixtures.tempDir()))
        store.showOnboarding = false
        let build = AppBuild(version: "0.7.0", commit: nil, whatsNew: notes)
        store.showWhatsNewIfUpdated(build: build, defaults: defaults)
        XCTAssertEqual(store.whatsNew?.items.count, 2)
        store.checkUpdatesAtLaunch = nil
        await store.launchUpdateCheck()
        XCTAssertFalse(store.askAboutUpdateChecks)

        store.whatsNew = nil
        store.showWhatsNewIfUpdated(build: build, defaults: defaults)
        XCTAssertNil(store.whatsNew, "same entries: not again")
    }

    func testFirstLaunchRemembersTheEntriesWithoutShowingThem() {
        let defaults = UserDefaults(suiteName: "whatsnew-\(UUID().uuidString)")!
        let store = AppStore(storage: LocalStorage(root: Fixtures.tempDir()))
        store.showOnboarding = true
        store.showWhatsNewIfUpdated(build: AppBuild(version: "0.7.0", commit: nil, whatsNew: notes), defaults: defaults)
        XCTAssertNil(store.whatsNew)
        XCTAssertEqual(defaults.string(forKey: AppStore.whatsNewSeenKey), notes)
    }

    /// Every entry agents add under `## Unreleased` must be one the screen can show.
    func testChangelogEntriesFollowTheForm() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let entries = text.components(separatedBy: .newlines).filter { $0.hasPrefix("- ") }
        XCTAssertFalse(entries.isEmpty)
        for line in entries {
            XCTAssertEqual(WhatsNew.parse(line).count, 1, "not in the `- <emoji> **Title**: text` form: \(line)")
        }
    }
}
