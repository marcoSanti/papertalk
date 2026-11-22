# Tests

Part of the [development guide](../../AGENTS.md): the XCTest suite, its mocks and helpers.

- The suite is **XCTest only**. `app.sh test` runs `swift test --disable-swift-testing`, so the
  empty Swift Testing pass doesn't print a confusing "0 tests" line. If you ever add
  `import Testing` / `@Test` tests, drop that flag or they will silently not run.
- Every test class subclasses **`PapertalkTestCase`** (`TestSupport.swift`), never
  `XCTestCase` directly. It installs `NetworkGuard`, which blocks and fails any request that
  isn't answered by a mock. Tests must never reach a real LLM, doi2bib or storage server.
- **LLM calls**: use `MockLLM.install { request in ... }` and match on
  `MockLLM.allText(in:)` (e.g. outline prompts contain `"segments": [{"title"`, dialogue prompts
  `TARGET LENGTH: about N words`, monologue prompts `METHOD TEXT`). Reply with
  `MockLLM.chatReply(_:)`. The storage server is faked the same way (`HttpStorageServerTests`);
  `StorageServerTests` runs the real one on a loopback port, let through by
  `NetworkGuard.allowLocal(port:)`.
- **`AppStore`**: always `AppStore(storage: LocalStorage(root: Fixtures.tempDir()))`. Never build
  a store on the default storage: that's the user's real library. Seed finished papers on disk
  and let the store's startup scan load them (it drops in-memory-only papers). Keep converting
  papers (`running`/`queued`) **in memory only**: on disk the scan would resume them and call the
  LLM. Edits save asynchronously; assert on disk with `waitUntil { ... }`.
- Don't start conversions, regeneration or playback (`upload`, a real `rerun`,
  `togglePlayback`, `previewVoice`) in tests: they need the LLM or Kokoro. Kokoro synthesis and
  the Keychain are deliberately untested.
- The suite never reaches the login Keychain: `PapertalkTestCase` turns `KeychainStore` off. Keep
  it so: the Keychain is per user, and a test that saved settings would replace the user's real keys.
  Checkouts from before 0.9.1 don't have this guard: running their tests can overwrite those keys.
- Helpers: `TempLibraryTestCase`, `Fixtures.paper(...)`, `Fixtures.blankPaper(...)`, `Fixtures.transcript(...)`, `Fixtures.silentWAV(seconds:)`,
  `Fixtures.tempDir()`, `waitUntil`. `@MainActor` test classes need fixtures marked
  `nonisolated(unsafe)` and `async` test methods.
- When fixing a bug, add a regression test and check it fails without the fix (temporarily
  revert the line, run, restore).
