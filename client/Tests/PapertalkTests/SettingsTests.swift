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