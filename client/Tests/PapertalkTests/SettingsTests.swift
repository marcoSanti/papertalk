import XCTest
@testable import Papertalk

final class SettingsTests: PapertalkTestCase {
    private func settings(apiKey: String, keyEnv: String) -> LLMSettings {
        LLMSettings(baseUrl: "http://x", apiKey: apiKey, model: "m", keyEnv: keyEnv)
    }

    func testResolvedKeyUsesApiKeyByDefault() {
        XCTAssertEqual(settings(apiKey: "typed-secret", keyEnv: "").resolvedKey(), "typed-secret")
    }

    func testCandidateKeyEnvsOnlyReportsSetVars() {
        let env = ProcessInfo.processInfo.environment
        let candidate = ["OPENWEBUI_API_KEY", "LLM_API_KEY", "PAPERTALK_API_KEY"]
        let result = candidateKeyEnvs()
        for name in result {
            XCTAssertTrue(candidate.contains(name))
            XCTAssertFalse((env[name] ?? "").isEmpty)
        }
    }
}

final class PromptSettingsTests: PapertalkTestCase {
    func testDefaultsCarryExpectedTokens() {
        let d = PromptSettings.defaults
        XCTAssertTrue(d.outlineRules.contains("{minutes}"))
        XCTAssertTrue(d.outlineRules.contains("{plannedWords}"))
        XCTAssertTrue(d.writeForEar.contains("WRITE FOR THE EAR"))
        XCTAssertTrue(d.dialoguePersona.contains("{host}") && d.dialoguePersona.contains("{expert}"))
        XCTAssertTrue(d.monologuePersona.contains("{expert}"))
        XCTAssertTrue(d.segmentRequest.contains("TARGET LENGTH: about {targetWords} words"))
        XCTAssertTrue(d.monologueRules.contains("{position}"))
        XCTAssertTrue(d.depthCustom.contains("{note}"))
    }

    func testFillReplacesKnownTokensOnly() {
        XCTAssertEqual(PromptSettings.fill("{host} meets {expert} in {place}", ["host": "Jo", "expert": "Ada"]),
                       "Jo meets Ada in {place}")
    }

    func testOlderSavedPromptsKeepTheirEditsAndGetNewDefaults() throws {
        // A build before every prompt was editable saved only these four.
        let old = #"{"outlineRules":"MY RULES","dialoguePersona":"P","monologuePersona":"M","writeForEar":"E"}"#
        let p = try JSONDecoder().decode(PromptSettings.self, from: Data(old.utf8))
        XCTAssertEqual(p.outlineRules, "MY RULES")
        XCTAssertEqual(p.writeForEar, "E")
        XCTAssertEqual(p.metadata, PromptSettings.defaults.metadata)
        XCTAssertEqual(p.segmentRequest, PromptSettings.defaults.segmentRequest)
        let back = try JSONDecoder().decode(PromptSettings.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }
}

final class PromptCatalogTests: PapertalkTestCase {
    func testEveryPromptIsListedOnce() {
        let fields = Mirror(reflecting: PromptSettings.defaults).children.filter { $0.value is String }.count
        XCTAssertEqual(PromptCatalog.entries.count, fields)
        XCTAssertEqual(Set(PromptCatalog.entries.map(\.id)).count, fields)
        XCTAssertEqual(Set(PromptCatalog.entries.map(\.keyPath)).count, fields)
        XCTAssertEqual(PromptCatalog.groups.flatMap(\.entries).map(\.id), PromptCatalog.entries.map(\.id))
        XCTAssertEqual(PromptCatalog.groups.map(\.name), ["Paper details", "Planning", "Depth", "Dialogue", "Monologue"])
    }

    func testEachDefaultUsesOnlyTheTokensItLists() throws {
        let token = try NSRegularExpression(pattern: #"\{([A-Za-z]+)\}"#)
        for e in PromptCatalog.entries {
            let text = PromptSettings.defaults[keyPath: e.keyPath]
            let used = token.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range(at: 1), in: text)!]) }
            XCTAssertTrue(Set(used).isSubset(of: Set(e.tokens)), "\(e.id) uses \(used), lists \(e.tokens)")
        }
    }

    func testResetAndLabels() {
        let e = PromptCatalog.entry("cast")
        var p = PromptSettings.defaults
        XCTAssertTrue(e.isDefault(p))
        p.cast = "mine"
        XCTAssertFalse(e.isDefault(p))
        e.reset(&p)
        XCTAssertEqual(p, PromptSettings.defaults)
        XCTAssertEqual(e.tokensLabel, "No tokens.")
        XCTAssertEqual(PromptCatalog.entry("depthCustom").tokensLabel, "Tokens: {note}")
        XCTAssertEqual(PromptCatalog.entry("nope").id, PromptCatalog.entries[0].id)
    }
}

final class CustomDepthPresetsTests: PapertalkTestCase {
    func testRoundTrip() {
        let p = CustomDepthPresets(entries: [.init(name: "Deep", text: "go deep")])
        let data = try! JSONEncoder().encode(p)
        let back = try! JSONDecoder().decode(CustomDepthPresets.self, from: data)
        XCTAssertEqual(back.entries.count, 1)
        XCTAssertEqual(back.entries[0].name, "Deep")
    }

    func testIdFromName() {
        let e = CustomDepthPresets.Entry(name: "Deep", text: "x")
        XCTAssertEqual(e.id, "Deep")
    }
}