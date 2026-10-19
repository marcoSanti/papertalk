import XCTest
@testable import Papertalk

final class KokoroSpeechTests: PapertalkTestCase {
    func testDefaultVoiceByGender() {
        XCTAssertEqual(KokoroSpeech.defaultVoice(forGender: "male"), "am_michael")
        XCTAssertEqual(KokoroSpeech.defaultVoice(forGender: "female"), "af_heart")
        XCTAssertEqual(KokoroSpeech.defaultVoice(forGender: nil), "af_heart")
        XCTAssertEqual(KokoroSpeech.defaultVoice(forGender: "unknown"), "af_heart")
    }

    func testGuestVoiceIsStableByName() {
        let a = KokoroSpeech.guestVoice(forGender: "male", name: "Sam", avoiding: [])
        let b = KokoroSpeech.guestVoice(forGender: "male", name: "Sam", avoiding: [])
        XCTAssertEqual(a, b)
    }

    func testGuestVoiceAvoidsUsedVoices() {
        let used: Set<String> = ["af_heart", "af_bella", "af_nicole"]
        let v = KokoroSpeech.guestVoice(forGender: "female", name: "Sam", avoiding: used)
        XCTAssertFalse(used.contains(v), "chosen voice must not collide with reserved ones")
    }

    func testDefaultVoiceAvoidingUsed() {
        XCTAssertEqual(KokoroSpeech.defaultVoice(forGender: nil, avoiding: ["af_heart"]), "af_bella")
        // When everything is used, falls back to the pool's first.
        XCTAssertEqual(KokoroSpeech.defaultVoice(forGender: nil, avoiding: Set(KokoroSpeech.femalePool)), "af_heart")
    }

    func testGuessGender() {
        XCTAssertEqual(KokoroSpeech.guessGender(fromName: "Marco"), "male")
        XCTAssertEqual(KokoroSpeech.guessGender(fromName: "maria"), "female")
        XCTAssertEqual(KokoroSpeech.guessGender(fromName: "Maria Luisa"), "female")
        XCTAssertEqual(KokoroSpeech.guessGender(fromName: "UnknownName"), nil)
        XCTAssertEqual(KokoroSpeech.guessGender(fromName: ""), nil)
    }

    func testVoiceGender() {
        XCTAssertEqual(KokoroSpeech.voiceGender("af_heart"), "female")
        XCTAssertEqual(KokoroSpeech.voiceGender("am_michael"), "male")
        XCTAssertEqual(KokoroSpeech.voiceGender("x"), nil)
        XCTAssertEqual(KokoroSpeech.voiceGender(""), nil)
    }

    func testAccent() {
        XCTAssertEqual(KokoroSpeech.accent("am_michael"), "American")
        XCTAssertEqual(KokoroSpeech.accent("bf_emma"), "British")
        XCTAssertEqual(KokoroSpeech.accent("??"), "Other")
    }

    func testLabel() {
        XCTAssertEqual(KokoroSpeech.label("am_michael"), "Michael · male")
        XCTAssertEqual(KokoroSpeech.label("af_heart"), "Heart · female")
    }

    func testDisplayName() {
        XCTAssertEqual(KokoroSpeech.displayName("am_michael"), "Michael")
        XCTAssertEqual(KokoroSpeech.displayName("af_heart"), "Heart")
    }

    func testSamplePrompt() {
        XCTAssertEqual(KokoroSpeech.samplePrompt(for: "am_michael"),
                       "Hello, my name is Michael, and I am an AI generated voice.")
    }

    func testWavDuration() {
        // 24kHz mono 16-bit PCM -> 48000 bytes/sec.
        var wav = Data(count: 44 + 48000)     // 44-byte header + 1.0s of PCM
        XCTAssertEqual(KokoroSpeech.wavDuration(wav), 1.0, accuracy: 0.0001)
        wav = Data(count: 44 + 24000)          // 0.5s
        XCTAssertEqual(KokoroSpeech.wavDuration(wav), 0.5, accuracy: 0.0001)
    }

    func testWavDurationTrivialData() {
        XCTAssertEqual(KokoroSpeech.wavDuration(Data()), 0)
        XCTAssertEqual(KokoroSpeech.wavDuration(Data(count: 20)), 0)
        XCTAssertEqual(KokoroSpeech.wavDuration(Data(count: 44)), 0)
    }

    func testShortTurnIsOnePiece() {
        XCTAssertEqual(KokoroSpeech.pieces(of: "  Hello there. How are you?  "), ["Hello there. How are you?"])
        XCTAssertEqual(KokoroSpeech.pieces(of: "   "), [])
    }

    func testLongTurnSplitsAtSentencesWithinTheLimit() {
        let sentence = "Queries and keys are compared with a softmax over their similarities."
        let text = Array(repeating: sentence, count: 40).joined(separator: " ")
        let pieces = KokoroSpeech.pieces(of: text)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= KokoroSpeech.maxPieceLength })
        XCTAssertTrue(pieces.allSatisfy { $0.hasSuffix(".") }, "breaks fall between sentences")
        // Nothing lost or reordered.
        XCTAssertEqual(pieces.joined(separator: " "), text)
    }

    func testOverlongSentenceSplitsAtClausesFirst() {
        let text = "First we project the queries, then the keys, and finally the values; "
            + "after that a softmax weighs every position against every other one."
        let pieces = KokoroSpeech.pieces(of: text, max: 80)
        XCTAssertEqual(pieces, ["First we project the queries, then the keys, and finally the values;",
                                "after that a softmax weighs every position against every other one."])
    }

    func testOverlongSentenceSplitsBetweenWords() {
        let text = Array(repeating: "word", count: 300).joined(separator: " ")
        let pieces = KokoroSpeech.pieces(of: text, max: 50)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 50 && !$0.contains("  ") })
        XCTAssertEqual(pieces.joined(separator: " "), text)
    }

    func testJoinWAVsConcatenatesPCM() {
        func wav(seconds: Double, byte: UInt8) -> Data {
            Data(count: 44) + Data(repeating: byte, count: Int(seconds * 48000))
        }
        let a = wav(seconds: 1.0, byte: 1), b = wav(seconds: 0.5, byte: 2)
        let joined = KokoroSpeech.joinWAVs([a, b])
        XCTAssertEqual(KokoroSpeech.wavDuration(joined), 1.5, accuracy: 0.0001)
        XCTAssertEqual(joined.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(joined.subdata(in: 36..<40), Data("data".utf8))
        let size = joined.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: size)), 72000)
        XCTAssertEqual(joined[44], 1)
        XCTAssertEqual(joined.last, 2)
        // A single piece passes through untouched.
        XCTAssertEqual(KokoroSpeech.joinWAVs([a]), a)
    }

    func testVoiceGroupsPartitionAllVoices() {
        let grouped = KokoroSpeech.voiceGroups.flatMap { $0.voices }
        XCTAssertEqual(Set(grouped).count, grouped.count, "no voice listed twice")
        XCTAssertEqual(Set(grouped), Set(KokoroSpeech.allVoices))
    }

    func testPoolsRespectGender() {
        XCTAssertTrue(KokoroSpeech.femalePool.allSatisfy { KokoroSpeech.voiceGender($0) == "female" })
        XCTAssertTrue(KokoroSpeech.malePool.allSatisfy { KokoroSpeech.voiceGender($0) == "male" })
    }
}