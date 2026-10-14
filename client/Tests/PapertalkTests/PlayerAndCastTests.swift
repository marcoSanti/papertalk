import XCTest
@testable import Papertalk

/// Playback timing over pre-baked audio. Nothing is synthesized and nothing
/// is actually played (no `playPause`), so no sound and no Kokoro model.
@MainActor
final class PlayerControllerTests: PapertalkTestCase {
    private func baked(_ seconds: [Double]) -> [BakedTurn] {
        seconds.map { BakedTurn(wav: Fixtures.silentWAV(seconds: $0), duration: $0) }
    }

    func testPrepareBakedBuildsTimelineWithGaps() {
        let p = PlayerController()
        p.prepare(baked: baked([1.0, 0.5, 2.0]))
        XCTAssertEqual(p.turnCount, 3)
        XCTAssertEqual(p.renderedCount, 3)
        XCTAssertFalse(p.isRendering)
        // 1.0 + 0.35 gap + 0.5 + 0.35 gap + 2.0
        XCTAssertEqual(p.duration, 4.2, accuracy: 0.0001)
    }

    func testPrepareEmptyBakedLeavesPlayerEmpty() {
        let p = PlayerController()
        p.prepare(baked: [])
        XCTAssertEqual(p.turnCount, 0)
        XCTAssertEqual(p.duration, 0)
    }

    func testSkipMovesByWholeTurnsAndClamps() {
        let p = PlayerController()
        p.prepare(baked: baked([1.0, 0.5, 2.0]))
        p.skip(by: 1)
        XCTAssertEqual(p.activeTurn, 1)
        XCTAssertEqual(p.currentTime, 1.35, accuracy: 0.0001)
        p.skip(by: 10)
        XCTAssertEqual(p.activeTurn, 2)
        p.skip(by: -10)
        XCTAssertEqual(p.activeTurn, 0)
        XCTAssertEqual(p.currentTime, 0)
    }

    func testSeekLandsInTheRightTurnAndClampsToItsEnd() {
        let p = PlayerController()
        p.prepare(baked: baked([1.0, 0.5, 2.0]))
        p.seek(toTime: 1.5)                       // 0.15 s into turn 1
        XCTAssertEqual(p.activeTurn, 1)
        XCTAssertEqual(p.currentTime, 1.5, accuracy: 0.0001)
        p.seek(toTime: 100)                       // past the end: last turn, at its end
        XCTAssertEqual(p.activeTurn, 2)
        XCTAssertEqual(p.currentTime, 2.2 + 2.0, accuracy: 0.0001)   // turn 2 starts at 2.2 s
    }

    func testStopAllResetsState() {
        let p = PlayerController()
        p.prepare(baked: baked([1.0, 1.0]))
        p.skip(by: 1)
        p.stopAll()
        XCTAssertEqual(p.turnCount, 0)
        XCTAssertEqual(p.renderedCount, 0)
        XCTAssertEqual(p.activeTurn, -1)
        XCTAssertFalse(p.isPlaying)
        XCTAssertFalse(p.isBuffering)
        XCTAssertNil(p.renderError)
    }

    func testStopPreviewClearsPreviewState() {
        let p = PlayerController()
        p.stopPreview()
        XCTAssertNil(p.preview)
        XCTAssertEqual(p.previewProgress, 0)
    }

    func testVoiceSpeedPersistsAndRejectsOutOfRangeValues() {
        let key = PlayerController.speedKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        let p = PlayerController()
        p.voiceSpeed = 1.6
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 1.6)
        XCTAssertEqual(PlayerController().voiceSpeed, 1.6)   // a new player reads it back

        UserDefaults.standard.set(9.0, forKey: key)          // corrupt / out of range
        XCTAssertEqual(PlayerController().voiceSpeed, PlayerController.defaultSpeed)
        XCTAssertEqual(PlayerController.speedRange.upperBound, 2.0)
    }
}

/// How the voice selection sheet casts voices before the user touches anything.
final class CastSheetVoiceTests: PapertalkTestCase {
    private func rows(_ proposals: [ProposedSpeaker]) -> [CastForm.Row] {
        CastForm.initialRows(proposals)
    }

    func testHostKeepsSignatureVoiceAndFemaleGuestGetsADifferentOne() {
        let r = rows([ProposedSpeaker(role: "Interviewer", gender: "female", name: "Jordan"),
                      ProposedSpeaker(role: "Scientist", gender: "female", name: "Tasnuva")])
        XCTAssertEqual(r[0].voice, KokoroSpeech.femaleVoice)      // Heart stays with the host
        XCTAssertNotEqual(r[1].voice, r[0].voice)
        XCTAssertEqual(KokoroSpeech.voiceGender(r[1].voice), "female")
    }

    func testMaleGuestNeverGetsAFemaleVoice() {
        // The "Bella for William" regression.
        let r = rows([ProposedSpeaker(role: "Interviewer", gender: "female", name: "Jordan"),
                      ProposedSpeaker(role: "Scientist", gender: "male", name: "William")])
        XCTAssertEqual(KokoroSpeech.voiceGender(r[1].voice), "male")
        XCTAssertEqual(r[1].gender, "male")
    }

    func testTwoMenStillSoundDifferent() {
        let r = rows([ProposedSpeaker(role: "Host", gender: "male", name: "Sam"),
                      ProposedSpeaker(role: "Scientist", gender: "male", name: "William")])
        XCTAssertEqual(r[0].voice, KokoroSpeech.maleVoice)
        XCTAssertNotEqual(r[1].voice, r[0].voice)
        XCTAssertEqual(KokoroSpeech.voiceGender(r[1].voice), "male")
    }

    func testUnknownGenderIsKeptVisibleNotGuessed() {
        let r = rows([ProposedSpeaker(role: "Interviewer", gender: "female", name: "Jordan"),
                      ProposedSpeaker(role: "Scientist", gender: nil, name: "Xyzzy")])
        XCTAssertNil(r[1].gender)                 // the sheet shows the gender switch unset
    }

    func testGuestVoiceIsStablePerAuthor() {
        let proposals = [ProposedSpeaker(role: "Interviewer", gender: "female", name: "Jordan"),
                         ProposedSpeaker(role: "Scientist", gender: "male", name: "William")]
        XCTAssertEqual(rows(proposals)[1].voice, rows(proposals)[1].voice)
    }

    func testHostRoleDetection() {
        for role in ["Interviewer", "Podcast host", "Anchor", "Moderator", "Presenter"] {
            XCTAssertTrue(CastForm.isHost(role), role)
        }
        for role in ["Scientist", "Guest", "First author"] {
            XCTAssertFalse(CastForm.isHost(role), role)
        }
    }
}

/// Notifications must be a silent no-op outside an app bundle (tests, `swift run`).
@MainActor
final class NotifierTests: PapertalkTestCase {
    func testPostingWithoutAnAppBundleDoesNothing() {
        let n = Notifier()
        n.requestPermissionIfNeeded()
        n.post(.ready, paperId: "p", title: "T")
        n.post(.failed("boom"), paperId: "p", title: "T")
        n.post(.needsInput("Choose voices"), paperId: "p", title: "T")
        n.clearInputRequest(paperId: "p")
    }
}

/// The guard itself: a stray request is blocked and reported, never sent.
final class NetworkGuardTests: PapertalkTestCase {
    func testStrayRequestIsBlockedAndRecorded() async {
        do {
            _ = try await URLSession.shared.data(from: URL(string: "https://example.invalid/llm")!)
            XCTFail("the request should have been blocked")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(NetworkGuard.blocked, ["https://example.invalid/llm"])
        NetworkGuard.reset()                      // expected here, so don't fail the test
    }
}
