// The platform shims: sentence splitting (both platforms), and on Linux the C-backed
// stand-ins for PDFKit (poppler) and the Kokoro voice ids (sherpa-onnx).

import Foundation
import XCTest
@testable import Papertalk

/// `Sentences` behaves the same on macOS (Foundation) and Linux (its own splitter).
final class SentencesTests: PapertalkTestCase {
    private func sentences(_ text: String) -> [String] {
        var out: [String] = []
        Sentences.forEach(in: text) { s, _ in out.append(s) }
        return out
    }

    func testSplitsAfterTerminatorsKeepingTrailingSpace() {
        XCTAssertEqual(sentences("One. Two! Three?"), ["One. ", "Two! ", "Three?"])
    }

    func testKeepsClosingQuotesWithTheirSentence() {
        XCTAssertEqual(sentences("He said “stop.” Then left."), ["He said “stop.” ", "Then left."])
    }

    func testStopEndsTheWalk() {
        var seen: [String] = []
        Sentences.forEach(in: "A. B. C.") { s, stop in
            seen.append(s)
            if seen.count == 2 { stop = true }
        }
        XCTAssertEqual(seen, ["A. ", "B. "])
    }

    func testTextWithoutTerminatorIsOneSentence() {
        XCTAssertEqual(sentences("no full stop here"), ["no full stop here"])
        XCTAssertEqual(sentences(""), [])
    }
}

#if os(Linux)
/// The C-backed shims on Linux.
final class LinuxShimTests: PapertalkTestCase {
    func testSentencesDoNotSplitAbbreviationsOrDecimals() {
        var out: [String] = []
        Sentences.forEach(in: "We use e.g. attention. It scores 3.5 points.\nNew line") { s, _ in out.append(s) }
        XCTAssertEqual(out, ["We use e.g. attention. ", "It scores 3.5 points.\n", "New line"])
    }

    func testPDFTextComesFromPoppler() throws {
        let doc = try XCTUnwrap(PDFDocument(data: Fixtures.pdf(lines: ["First line", "Second line"])))
        XCTAssertEqual(doc.pageCount, 1)
        let text = try XCTUnwrap(doc.page(at: 0)?.string)
        XCTAssertTrue(text.contains("First line") && text.contains("Second line"), text)
        XCTAssertNil(doc.page(at: 1))
    }

    func testUnreadableDataIsNotAPDF() {
        XCTAssertNil(PDFDocument(data: Data("not a pdf".utf8)))
        XCTAssertNil(PDFDocument(data: Data()))
        XCTAssertNil(PDFDocument.coverPNG(of: Data("not a pdf".utf8), width: 100))
    }

    func testCoverIsAPNGOfTheAskedWidth() throws {
        let png = try XCTUnwrap(PDFDocument.coverPNG(of: Fixtures.pdf(lines: ["Cover"]), width: 120))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // IHDR's width, big-endian at bytes 16..<20.
        let width = png[png.startIndex + 16..<png.startIndex + 20].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(width, 120)
    }

    /// Regression: covers drawn on several threads at once crashed inside poppler. The race is
    /// in poppler's first-use set-up, so without the lock this crashes in only about one run in
    /// four or five: a guard that catches it over a few CI runs, not on every one.
    func testCoversRenderConcurrently() {
        let pdf = Fixtures.pdf(lines: ["Concurrent covers"])
        let rendered = NSLock()
        var count = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if PDFDocument.coverPNG(of: pdf, width: 200) != nil {
                rendered.lock(); count += 1; rendered.unlock()
            }
        }
        XCTAssertEqual(count, 32)
    }

    func testEveryVoiceHasASpeakerIdInTheModelsOrder() {
        let ids = KokoroAneConstants.englishVoices.compactMap(KokoroAneConstants.speakerId)
        XCTAssertEqual(ids.count, KokoroAneConstants.englishVoices.count)
        XCTAssertEqual(Set(ids), Set(0..<Int32(ids.count)))
        // The model's own order: Kokoro's list with em_santa added last.
        XCTAssertEqual(KokoroAneConstants.speakerId("af_alloy"), 0)
        XCTAssertEqual(KokoroAneConstants.speakerId("af_heart"), 3)
        XCTAssertEqual(KokoroAneConstants.speakerId("am_michael"), 16)
        XCTAssertEqual(KokoroAneConstants.speakerId("ff_siwis"), 30)
        XCTAssertEqual(KokoroAneConstants.speakerId("em_santa"), 53)
        XCTAssertNil(KokoroAneConstants.speakerId("xx_nobody"))
    }

    func testUnknownVoiceFailsBeforeLoadingTheModel() async {
        do {
            _ = try await KokoroEngine.shared.synthesize(text: "Hi", voice: "xx_nobody", speed: 1)
            XCTFail("expected unknownVoice")
        } catch KokoroLinuxError.unknownVoice(let voice) {
            XCTAssertEqual(voice, "xx_nobody")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testKeyringWithoutASessionBusFindsNothing() {
        // The test container has no session bus: reads come back empty instead of hanging.
        guard ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] == nil else { return }
        KeychainStore.set("x", account: "papertalk-tests")
        XCTAssertNil(KeychainStore.get("papertalk-tests"))
    }
}
#endif

#if os(Linux)
/// Reading the desktop's dark preference (SwiftCrossUI doesn't).
final class DesktopThemeTests: PapertalkTestCase {
    func testGTKThemeVariableWins() {
        XCTAssertTrue(DesktopTheme.prefersDark(gtkThemeEnv: "Adwaita:dark", colorScheme: "'prefer-light'", gtkTheme: nil))
        XCTAssertFalse(DesktopTheme.prefersDark(gtkThemeEnv: "Adwaita", colorScheme: "'prefer-dark'", gtkTheme: nil))
    }

    func testGNOMEColorSchemeThenThemeName() {
        XCTAssertTrue(DesktopTheme.prefersDark(gtkThemeEnv: nil, colorScheme: "'prefer-dark'", gtkTheme: "'Yaru'"))
        XCTAssertFalse(DesktopTheme.prefersDark(gtkThemeEnv: nil, colorScheme: "'prefer-light'", gtkTheme: "'Yaru-dark'"))
        XCTAssertTrue(DesktopTheme.prefersDark(gtkThemeEnv: "", colorScheme: "'default'", gtkTheme: "'Yaru-red-dark'"))
        XCTAssertFalse(DesktopTheme.prefersDark(gtkThemeEnv: nil, colorScheme: nil, gtkTheme: nil))
    }
}
#endif

#if os(Linux)
/// Choosing the sound server's player.
final class AudioSinkTests: PapertalkTestCase {
    /// Regression: without `--raw`, PipeWire's pw-cat rejected the PCM and nothing played.
    func testPipeWireIsAskedForRawPCM() {
        let pwCat = AVAudioPlayer.sinkCandidates(rate: 24_000, channels: 1).first { $0.first == "pw-cat" }
        XCTAssertEqual(pwCat?.contains("--raw"), true)
        XCTAssertEqual(pwCat?.contains("24000"), true)
    }

    func testEveryCandidateReadsRawPCM() {
        for command in AVAudioPlayer.sinkCandidates(rate: 24_000, channels: 1) {
            XCTAssertTrue(command.contains { $0.contains("raw") }, command.joined(separator: " "))
        }
    }
}
#endif
