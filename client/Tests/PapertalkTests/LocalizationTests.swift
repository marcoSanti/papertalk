// Tests of the language packs (complete, placeholders intact) and the episode language option.

import Foundation
import XCTest
@testable import Papertalk

/// The interface language packs, and the option to have the LLM write an
/// episode in the interface language.
final class LocalizationTests: PapertalkTestCase {
    override func tearDown() {
        Localization.language = .english
        UserDefaults.standard.removeObject(forKey: Localization.defaultsKey)
        super.tearDown()
    }

    // MARK: packs

    /// Every key passed to `L(…)` or `Localization.text(…)` in the app's sources.
    private static let sourceKeys: Set<String> = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Papertalk")
        let call = try! NSRegularExpression(pattern: #"(?:\bL|Localization\.text)\(\s*"((?:[^"\\\n]|\\.)*)""#)
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.contains("/Packs/"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for m in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = String(text[Range(m.range(at: 1), in: text)!])
                keys.insert(literal.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: #"\"#))
            }
        }
        return keys
    }()

    func testSourcesUseLiteralKeysWithoutInterpolation() {
        XCTAssertGreaterThan(Self.sourceKeys.count, 400, "the key scan found too few keys; did the sources move?")
        for key in Self.sourceKeys {
            XCTAssertFalse(key.contains(#"\("#), "interpolate with {0} instead: \(key)")
        }
    }

    func testEveryPackTranslatesExactlyTheKeysInUse() {
        for language in AppLanguage.allCases where language != .english {
            let pack = Set(language.pack.keys)
            XCTAssertEqual(Self.sourceKeys.subtracting(pack).sorted(), [], "\(language) is missing these")
            XCTAssertEqual(pack.subtracting(Self.sourceKeys).sorted(), [], "\(language) has keys no longer used")
        }
    }

    func testTranslationsKeepTheirPlaceholders() throws {
        let placeholder = try NSRegularExpression(pattern: #"\{\w+\}"#)
        func tokens(_ s: String) -> [String] {
            placeholder.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
        }
        for language in AppLanguage.allCases {
            for (key, value) in language.pack {
                XCTAssertEqual(tokens(key), tokens(value), "\(language): \(key)")
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
            }
        }
    }

    // MARK: lookup

    func testLookupFillsPlaceholdersAndFallsBackToEnglish() {
        XCTAssertEqual(Localization.text("Up to {0} minutes", [35], in: .english), "Up to 35 minutes")
        XCTAssertEqual(Localization.text("Up to {0} minutes", [35], in: .italian), "Fino a 35 minuti")
        XCTAssertEqual(Localization.text("Turn {0} of {1}", [3, 40], in: .german), "Redebeitrag 3 von 40")
        XCTAssertEqual(Localization.text("Not a key", [], in: .french), "Not a key")
    }

    func testPresentationFollowsTheCurrentLanguage() {
        Localization.language = .spanish
        XCTAssertEqual(LibraryPresentation.paperCount(1), "1 artículo")
        XCTAssertEqual(LibraryPresentation.paperCount(3), "3 artículos")
        XCTAssertEqual(Depth.summary.label, "Resumen")
        XCTAssertEqual(KokoroSpeech.label("am_michael"), "Michael · hombre")
        Localization.language = .english
        XCTAssertEqual(LibraryPresentation.paperCount(3), "3 papers")
    }

    func testStoppedPaperIsRecognisedWhateverLanguageItWasStoppedIn() {
        Localization.language = .french
        var p = Fixtures.paper(state: "error")
        p.statusError = ConversionPresentation.stoppedMessage
        Localization.language = .english
        XCTAssertTrue(ConversionPresentation.isStopped(p))
        XCTAssertEqual(PaperPresentation.failureTitle(p), "Conversion stopped")
        p.statusError = "LLM: HTTP 500"
        XCTAssertEqual(PaperPresentation.failureTitle(p), "Conversion failed")
    }

    // MARK: choosing the language

    func testPreferredLanguageComesFromTheSystemList() {
        XCTAssertEqual(AppLanguage.preferred(["it-IT", "en-US"]), .italian)
        XCTAssertEqual(AppLanguage.preferred(["ja-JP", "fr_CA"]), .french)
        XCTAssertEqual(AppLanguage.preferred(["ja-JP"]), .english)
        XCTAssertEqual(AppLanguage.preferred([]), .english)
    }

    func testSavedChoiceWinsOverTheSystem() {
        let defaults = UserDefaults(suiteName: "papertalk.tests.language")!
        defaults.removePersistentDomain(forName: "papertalk.tests.language")
        XCTAssertEqual(Localization.load(defaults: defaults, preferred: ["de-DE"]), .german)
        defaults.set("es", forKey: Localization.defaultsKey)
        XCTAssertEqual(Localization.load(defaults: defaults, preferred: ["de-DE"]), .spanish)
        defaults.set("xx", forKey: Localization.defaultsKey)
        XCTAssertEqual(Localization.load(defaults: defaults, preferred: ["de-DE"]), .german)
        defaults.removePersistentDomain(forName: "papertalk.tests.language")
    }

    @MainActor
    func testSetLanguageSwitchesAndRemembers() async {
        let store = AppStore(storage: LocalStorage(root: Fixtures.tempDir()))
        XCTAssertEqual(store.language, .english)
        store.setLanguage(.italian)
        XCTAssertEqual(store.language, .italian)
        XCTAssertEqual(Localization.language, .italian)
        XCTAssertEqual(UserDefaults.standard.string(forKey: Localization.defaultsKey), "it")
        XCTAssertEqual(LibraryPresentation.title(view: .all, tag: nil, author: nil), "Tutti gli articoli")
    }

    func testLanguageOptionsUseEachLanguagesOwnName() {
        Localization.language = .german
        XCTAssertEqual(LanguagePresentation.options.map(\.title), ["English", "Italiano", "Español", "Deutsch", "Français"])
        XCTAssertEqual(LanguagePresentation.generalTitle, "Allgemein")
    }

    // MARK: episode language

    func testImportToggleIsOffByDefaultAndOnlyOfferedOutsideEnglish() {
        var english = ImportForm()
        english.appLanguage = .english
        XCTAssertFalse(english.showsLanguageToggle)
        english.writeInAppLanguage = true
        XCTAssertEqual(english.scriptLanguage, .english)

        var italian = ImportForm()
        italian.appLanguage = .italian
        XCTAssertTrue(italian.showsLanguageToggle)
        XCTAssertFalse(italian.writeInAppLanguage)
        XCTAssertEqual(italian.scriptLanguage, .english, "English unless asked")
        italian.writeInAppLanguage = true
        XCTAssertEqual(italian.scriptLanguage, .italian)
        italian.setFile(name: "p.pdf", data: Data("x".utf8))
        XCTAssertEqual(italian.submission?.scriptLanguage, .italian)

        italian.depth = .direct   // nothing is written, so nothing to translate
        XCTAssertFalse(italian.showsLanguageToggle)
        XCTAssertEqual(italian.scriptLanguage, .english)
    }

    func testPaperKeepsItsEpisodeLanguageAndOldRecordsAreEnglish() throws {
        var p = Fixtures.paper()
        XCTAssertEqual(p.episodeLanguage, .english)
        p.scriptLanguage = "fr"
        let decoded = try JSONDecoder().decode(Paper.self, from: try JSONEncoder().encode(p))
        XCTAssertEqual(decoded.episodeLanguage, .french)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(p), as: UTF8.self).contains(#""script_language":"fr""#))
    }

    func testOlderSavedPromptsGetTheDefaultLanguageInstruction() throws {
        let decoded = try JSONDecoder().decode(PromptSettings.self, from: Data(#"{"metadata": "M"}"#.utf8))
        XCTAssertEqual(decoded.metadata, "M")
        XCTAssertEqual(decoded.outputLanguage, PromptSettings.defaults.outputLanguage)
        XCTAssertTrue(PromptCatalog.entries.contains { $0.id == "outputLanguage" && $0.tokens == ["language"] })
    }

    func testOnlyANonEnglishEpisodeGetsTheLanguageInstruction() {
        var p = LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m")
        XCTAssertEqual(p.inOutputLanguage("SYSTEM"), "SYSTEM")
        p.outputLanguage = .italian
        let system = p.inOutputLanguage("SYSTEM")
        XCTAssertTrue(system.hasPrefix("SYSTEM\n\nLANGUAGE:"))
        XCTAssertTrue(system.contains("in Italian"))
        XCTAssertFalse(system.contains("{language}"))
    }

    /// The instruction reaches the LLM with the mind map request, which uses
    /// the interface language's English name whatever the interface shows.
    func testMindMapRequestCarriesTheEpisodeLanguage() async throws {
        let sent = SentPrompts()
        MockLLM.install { request in
            sent.append(MockLLM.allText(in: request))
            return (200, MockLLM.chatReply(MindMapFixtures.reply()))
        }
        Localization.language = .german
        var p = LocalPipeline(baseUrl: "http://mock.local/v1", apiKey: "k", model: "m")
        _ = try await p.mindMap(title: "T", text: "x")
        XCTAssertFalse(sent.all[0].contains("LANGUAGE:"), "English episodes get no instruction")
        p.outputLanguage = .spanish
        _ = try await p.mindMap(title: "T", text: "x")
        XCTAssertTrue(sent.all[1].contains("write in Spanish anyway"))
    }

    private final class SentPrompts: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ v: String) { lock.withLock { items.append(v) } }
        var all: [String] { lock.withLock { items } }
    }
}
