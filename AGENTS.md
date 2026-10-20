# AGENTS.md

Guidance for coding agents working on Papertalk. Read `README.md` for what the app does; this
file covers how to work on it and the traps that have already bitten. `CLAUDE.md` only imports
this file (for Claude Code), so keep the guidance here.

## Repo map

- `client/`: the Swift package (`Package.swift`, target `Papertalk`). It is the macOS app and
  also builds the Linux binary (tooling in `client/linux-dev/`). `Sources/Papertalk/` is split by
  platform: `Shared/` (both), `macOS/` (macOS only) and `Linux/` (Linux only). The UI and
  the whole pipeline (PDF → metadata → cast → script → audio) run in-process.
  - `Shared/Controllers/AppStore.swift`: the single `@MainActor` `ObservableObject` holding all app
    state, the import pipeline orchestration, and every mutation. Start here.
  - `Shared/Controllers/Pipeline.swift`: LLM calls (`LocalPipeline`): metadata, cast proposal, plan,
    dialogue/monologue writing, JSON parsing.
  - `macOS/Controllers/KokoroEngine.swift`: the only Kokoro TTS instance (on Linux,
    `Linux/KokoroCompat.swift`). `Shared/Controllers/Kokoro.swift` holds voice lists, labels
    and pools.
  - `Shared/Controllers/PlayerController.swift`: episode playback and voice-sample previews.
  - `Shared/Controllers/Storage.swift`: `LocalStorage` (Application Support) and `HttpStorage`
    (`server/storage_server.py`), plus the `K` key layout.
  - `Shared/Presentation/`: everything the views show or decide, as pure Swift with no SwiftUI:
    wording and labels, form state and validation (`ImportForm`, `MetadataForm`,
    `LLMSettingsForm`, `ServerSettingsForm`, `CastForm`), grouping/sorting (`AuthorsPresentation`),
    and display decisions (`EpisodeProgress`, `BottomBarContent`, `PlayerPane`, `PlaybackStatus`).
  - `macOS/Views/`, `macOS/Components/`: SwiftUI layout only (see "Views hold no logic" below).
    `macOS/Support/Theme.swift` has shared styling (`glassCard`, `StatusBadge`, `FlowLayout`,
    `Color.stable(for:)`); `macOS/Support/Clipboard.swift` copies text.
- `server/storage_server.py`: optional stdlib-only HTTP key/value file store. No compute.
- `VERSION`: the app version, edited by hand (`app.sh version` prints it).
- `scripts/coverage.sh`, `scripts/coverage_summary.py`: code coverage (`app.sh coverage`).
- `.github/workflows/`: `tests.yml` (pull requests) and `release.yml` (`main`: dev + stable releases).
- `shared/`: app icon.
- Linux port pieces: `client/Sources/Papertalk/Linux/` (compat shims, `#if os(Linux)`),
  `python/papertalk_platform/` (PDF, Kokoro, keyring services for Linux, with pytest tests),
  `client/linux-dev/` (dev container `Dockerfile`, `dev.sh`).
- `client/Tests/PapertalkTests/`: the XCTest suite (see "Tests" below).
- `todo.md`: the backlog. Remove an item in the PR that completes it.

## Build and test

```bash
swift build          # compile (from client/)
../app.sh test       # the whole suite, ~10 s, no network or real data (from client/)
../app.sh coverage   # the suite with coverage → ../coverage/ (summary.md, report.txt, lcov.info)
../app.sh app        # build dist/Papertalk.app (debug); `app.sh release` → dist/Papertalk-<version>.zip
```

`app.sh` (repo root) replaces the old Makefile: build/app/run/release/test/coverage/clean/version.
It's run from anywhere; from `client/` prefix it with `../`.

- Requires macOS 26 and Swift 6.2 tools; app and tests compile in Swift 5 language mode.
- After every change, run `swift build` **and** `app.sh test`, and report the results. Read the
  build output for **warnings**, not just errors: the app should compile warning-free in both
  debug and release (`swift build -c release`) configurations. Ignore warnings from dependencies:
  `.build/checkouts/`, and the three `swift-cross-ui` "pkg-config" lines on macOS (it's a
  Linux-only dependency whose GTK probe SwiftPM still runs). Several warnings here become errors in
  Swift 6 mode (e.g. main-actor calls from timer closures). Run the
  suite a few times when touching anything async; it has caught real races.
- `open dist/Papertalk.app` and `screencapture` may be blocked in a sandboxed agent shell. Don't
  launch a second copy of the app if the user already has it open, and never `pkill` it. If you
  can't see the UI, say so plainly instead of claiming a visual check.

## CI, pull requests and versions

- Work goes through pull requests into `main` (squash or rebase; one approving review). CI does
  only what's needed, on GitHub's `macos-26` runner:
  - `tests.yml`, on every PR: `app.sh coverage` (the suite, once, with coverage) and a syntax
    check of the storage server. No app bundle: nothing would be uploaded. PRs that change only
    Markdown skip it (no check is required, so they can still merge).
  - `release.yml`, on every push to `main` (Markdown-only pushes skip it): `app.sh test`, then the
    release build and the GitHub release (see below). It's the only run on `main`, so it's what
    tests `main`. It can be started by hand to retry a release, from `main` only.
  - The Linux jobs in both are paused (`if: false`); see "Linux port".
  Keep it green: a change that needs new tooling must update the workflows too.
- The version lives only in `VERSION` (semver, `MAJOR.MINOR.PATCH`). `app.sh` stamps it into
  the built app's `Info.plist`, with the short commit hash as the build number (shown as
  "Version 0.0.1 (a1b2c3d)" in About Papertalk). Don't hard-code
  versions elsewhere; read them with `app.sh version`.
- Coverage needs no external service: `tests.yml` runs `app.sh coverage` and appends
  `coverage/summary.md` to the job summary (and uploads `coverage/` as a run artifact). Nothing is
  published elsewhere. `scripts/coverage.sh` and `scripts/coverage_summary.py` produce the files;
  the "logic" figure excludes `macOS/Views/`, `macOS/Components/`, `macOS/App/` and
  `macOS/Support/Theme.swift`.
- Bump by editing `VERSION` as part of a PR. Patch for fixes, minor for features, major for
  breaking changes (e.g. a library format that older builds can't read).
- Stable releases are CI-driven: merge the bumped `VERSION` to `main` and
  `.github/workflows/release.yml` publishes a full release tagged `v<VERSION>`, marked Latest.
- Icons: the `CHANNEL` env var of `app.sh` (default `dev`) picks the app icon. Only the stable
  release (a `VERSION` bump merged to `main`) builds with `CHANNEL=stable` and gets the official
  `shared/icon.icns`; every other build (local, CI, dev pre-releases) gets a "DEV" stripe version
  generated into `client/.build/icons/` by `scripts/dev_icon.swift`. Don't ship the official icon
  from anything but a stable release.
- `app.sh release` also writes `dist/Papertalk-<version>-source.tar.gz` (`git archive` of HEAD);
  the release workflow publishes it, with checksums, beside the app zip.
- Dev builds: every push to `main` that didn't bump the version publishes a **pre-release**
  `v<VERSION>-dev.<short commit>`, built with `VERSION=<that> app.sh release` (the `VERSION`
  env overrides the file for that build only). It keeps the newest 10 dev builds and deletes
  older ones with their tags. Never create `-dev.` tags by hand, and never push tags or bump the
  version unless the user asks.

## Linux port

- The `Papertalk` target builds on macOS and Linux. macOS-only files are wrapped in
  `#if os(macOS)` (App, Views, Components, Theme, Clipboard, Notifier, PDFViewerWindow,
  MindMapWindow, KokoroEngine), which live under `macOS/`. Linux supplies same-named compat shims in `Linux/`,
  so shared code compiles unchanged. Prefer extending a shim to adding `#if` in shared code.
  Never change how the macOS app looks or behaves for the port's sake.
- A new file goes in `Shared/`, `macOS/` or `Linux/` by where it compiles, and files in `macOS/`
  and `Linux/` keep their whole-file `#if os(...)` guard (one target compiles every folder;
  SwiftPM can't exclude files per platform).
- Build and test Linux with Docker (OrbStack here): `client/linux-dev/dev.sh build` once, then
  `client/linux-dev/dev.sh test` (Swift suite + pytest) and `client/linux-dev/dev.sh e2e` (the opt-in
  `EndToEndImportTests`: a real import with Kokoro, LLM mocked). Run `swift build` and
  `app.sh test` on macOS too, after every change to shared code.
- Python is called only through `PythonRuntime` (one thread). Nothing time-critical goes through
  it (playback stays in Swift), because it can be busy with Kokoro for seconds.
- Linux traps: `Timer.scheduledTimer` is unavailable in async code; `URLProtocol`s are consulted
  in registration order; sync test methods in `@MainActor` test classes crash test discovery
  (make them `async`); files using URLSession types need `FoundationNetworking`.
- The Linux UI (`Linux/UI/`) is SwiftCrossUI 0.9.0 on GTK 4 (`GtkBackend`; `DefaultBackend`
  fails to build on Linux) over the shared `AppStore`. `StoreBridge` forwards `AppStore`'s and
  `PlayerController`'s `objectWillChange` to SwiftCrossUI's own `ObservableObject` and is the
  only UI file that imports OpenCombine. Views follow the same "no logic" rule as macOS:
  wording and decisions come from `Shared/Presentation/` (with tests); Linux-only store
  helpers go in `Linux/UI/AppStore+Linux.swift`.
- SwiftCrossUI 0.9 traps (each one cost a debugging session):
  - Write every `body` in view-builder style. `let` is fine; an explicit `return` skips the
    builder's tuple wrapping, and views inserted later (a selected paper) never appear.
  - The `NavigationSplitView` must be the window's root, with no modifiers on it, and a pane's
    root view takes no modifiers either (with a `List` inside, the pane is then laid out at its
    minimum size, centred and clipped). Pad rows instead; `PaneWidth` widens a column.
    Alerts and sheets go on an inner view (the player bar).
  - Sheets asked for before the window has appeared, or during the first layout, are dropped:
    launch-time sheets wait for `StoreBridge.windowReady`.
  - `Picker` shows `"\(option)"`: wrap values in `PickerOption` for readable labels. Menu items
    have no keyboard shortcuts.
- Look at the UI headless: `client/linux-dev/dev.sh screenshot` runs it under Xvfb and openbox on
  a demo library and saves PNGs to `client/.build-linux/shots/`; `PAPERTALK_UI_SCRIPT` drives it
  with xdotool and `PAPERTALK_UI_ARGS` passes a PDF to import. xdotool can't type into GTK 4's
  file dialog, so pass the PDF as an argument. `PAPERTALK_AUDIO_SINK` replaces the sound
  server's player (e.g. `cat > /dev/null` where there is no sound card).

Done in the Linux UI: library (sidebar, search, covers), detail pane, player bar (playback,
scrubber, import progress), import sheet (and `Papertalk paper.pdf`), cast and duplicate
prompts, delete/rerun confirmation, settings and first-run setup.

Packaging: `client/linux-dev/dev.sh appimage` (with `VERSION`, `CHANNEL`) builds
`client/dist/Papertalk-<version>-<arch>.AppImage`: release binary with the Swift runtime
static, a bundled Python 3.12 with the packages (so nothing is installed at first launch), every
other library except the GTK / graphics / glibc stack, and a `.desktop` file with `%f`.
`client/linux-dev/appimage_smoke.sh` checks it on plain Ubuntu. CI used to pack and smoke-test it
on every PR and upload it to each release (x86_64); those jobs are paused (`if: false` in both
workflows, plus the `LINUX_BUILDS` guard in the release notes) until the Linux work resumes.
If you add a Python package or a native dependency, run the smoke test: a library missing from
the bundle only shows up on a clean system.

Still to do, in order:
1. **Rest of the Linux UI:** authors view, transcript view, metadata editing, tag editing,
   clipboard copy, and `Notifier.isAppActive` from the window's focus (notifications are off
   until then). Then a pass on looks (spacing, a grid layout option).
2. **Updates on Linux:** the update check (menu on macOS) and `UpdateCheck` picking the
   AppImage asset; the Linux build has no version stamped in yet (macOS uses Info.plist).
3. Later: an arm64 AppImage (an `ubuntu-24.04-arm` runner), an in-app PDF viewer from
   pypdfium2 renders, and a re-check of OpenSwiftUI for a Linux renderer.

## Tests (`client/Tests/PapertalkTests`)

- The suite is **XCTest only**. `app.sh test` runs `swift test --disable-swift-testing`, so the
  empty Swift Testing pass doesn't print a confusing "0 tests" line. If you ever add
  `import Testing` / `@Test` tests, drop that flag or they will silently not run.
- Every test class subclasses **`PapertalkTestCase`** (`TestSupport.swift`), never
  `XCTestCase` directly. It installs `NetworkGuard`, which blocks and fails any request that
  isn't answered by a mock. Tests must never reach a real LLM, doi2bib or storage server.
- **LLM calls**: use `MockLLM.install { request in ... }` and match on
  `MockLLM.allText(in:)` (e.g. outline prompts contain `"segments": [{"title"`, dialogue prompts
  `TARGET LENGTH: about N words`, monologue prompts `METHOD TEXT`). Reply with
  `MockLLM.chatReply(_:)`. The storage server is faked the same way (`HttpStorageServerTests`).
- **`AppStore`**: always `AppStore(storage: LocalStorage(root: Fixtures.tempDir()))`. Never build
  a store on the default storage: that's the user's real library. Seed finished papers on disk
  and let the store's startup scan load them (it drops in-memory-only papers). Keep converting
  papers (`running`/`queued`) **in memory only**: on disk the scan would resume them and call the
  LLM. Edits save asynchronously; assert on disk with `waitUntil { ... }`.
- Don't start conversions, regeneration or playback (`upload`, a real `rerun`,
  `togglePlayback`, `previewVoice`) in tests: they need the LLM or Kokoro. Kokoro synthesis and
  the Keychain are deliberately untested.
- Helpers: `Fixtures.paper(...)`, `Fixtures.transcript(...)`, `Fixtures.silentWAV(seconds:)`,
  `Fixtures.tempDir()`, `waitUntil`. `@MainActor` test classes need fixtures marked
  `nonisolated(unsafe)` and `async` test methods.
- When fixing a bug, add a regression test and check it fails without the fix (temporarily
  revert the line, run, restore).

## Data and storage

- Local library: `~/Library/Application Support/papertalk/papers/<id>/`, containing
  `paper.json`, `source.pdf`, `transcript.json`, `mindmap.json`, `audio.json` (manifest) and
  `turns/<n>.wav`.
  Kokoro models: `~/.cache/fluidaudio/Models/kokoro*`.
- Everything for a paper lives under `K.folder(id)`. Delete a paper with
  `storage.deleteFolder(K.folder(id))`, never with a hand-written list of keys (that left
  orphaned folders before).
- **`Paper` is decoded from disk with synthesized `Codable`.** A new non-optional property added
  to `CodingKeys` makes every existing `paper.json` fail to decode, and those papers silently
  vanish from the library. Add new fields as optionals (see `storedSpeakers` and its computed
  `speakers` wrapper), or write a tolerant `init(from:)`. A property left *out* of `CodingKeys`
  is silently never saved.
- API keys live in the Keychain only (`KeychainStore`). `LLMSettings.save()` and
  `SpeechSettings.save()` strip the key before writing user defaults; keep it that way.

## Pipeline rules

- **Audio is baked at import** and saved per turn; playback uses the baked audio. Live synthesis
  in `PlayerController.prepare(transcript:)` is only a fallback for papers without complete
  audio, and it plays progressively. Don't move the normal path to live synthesis.
- Memory on 8 GB Macs: papers are voiced one at a time (`AppStore.audioGate`), and every turn
  goes to Kokoro in pieces of at most 200 characters (`KokoroSpeech.pieces`, joined with
  `joinWAVs`). One call holds all its samples and Core ML buffers until it returns, so a long
  monologue in one call peaked at ~1.2 GB and got the app killed; pieces keep it near 0.45 GB.
- `bakeAudio` reuses turns already on disk, so re-running it resumes. On failure it returns a
  message and the paper goes to an error state via `failAudio`, never to "done" without audio.
- **Synthesis goes through `SpeechBackend`** (`Shared/Controllers/SpeechBackend.swift`), picked
  only by `SpeechSettings.makeBackend()` via `AppStore.speechBackend` (the player gets the same
  one). `LocalSpeechBackend` wraps `KokoroEngine.shared`; `RemoteSpeechBackend` calls an
  OpenAI-compatible `/audio/speech` and never touches Core ML. Whatever a backend returns goes
  through `SpeechAudio.normalizedWAV`, so stored turns are always 24 kHz mono 16-bit WAV with a
  44-byte header (`wavDuration` and `joinWAVs` assume it). `bakeAudio` voices up to
  `backend.parallelRequests` turns at once (always 1 for local Kokoro; the user's setting on a
  server) and writes each turn as it finishes, so resuming still works. Remote voices are the
  cast's Kokoro ids, sent as they are. Tests pass a fake backend to `AppStore(storage:speech:)`.
- **Use `KokoroEngine.shared` for all local synthesis.** Never create another `KokoroAneManager`: two
  model copies on the Neural Engine, or overlapping calls into one (actors are re-entrant across
  `await`), fail with "unable to compute the asynchronous prediction".
- `LocalPipeline.extractJSON` takes text from the first `{` to the last `}`. **Ask the LLM for a
  JSON object, never a top-level array**: an array gets mangled and the parse silently falls
  back to defaults (this broke the cast step for a long time).
- Depth: only `.inDepth` may have full-length method monologues; `generateTranscript` forces
  every other depth to dialogue. Summary's ceiling is the import sheet's length
  (`SummaryLength`, 5–60 min, default 35, saved as `Paper.targetMinutes` for reruns); it aims
  for 6/7 of it, and the ceiling is enforced segment by segment on what was *written*: each
  segment is told its limit (`lengthLimit`), and one that runs >15% over is condensed by the LLM
  once, then cut (`LocalPipeline.trimTurns`). Models overshoot short targets 2×, so never trust
  the request alone. In-depth has no cap and scales with the paper. Lengths
  assume about 145 spoken words per minute at the default pace.
- Cast: the interviewer keeps the signature voice for their gender (Heart / Michael); the guest
  gets `KokoroSpeech.guestVoice` (same gender, different voice, stable per name). Gender comes
  from the LLM (per speaker and per author); `KokoroSpeech.guessGender(fromName:)` is only a
  fallback. The sheet shows the gender so the user can correct it. Never let an unknown gender
  quietly become a female voice.
- The cast prompt can answer **Skip audio** (`resolveCast(_:voiceAudio: false)`): the script
  is written and the paper finishes "done" with `hasAudio == false`; Regenerate audio voices it.
- Mind map (`MindMap`, `LocalPipeline.mindMap`): drawn after the script, before voicing, and
  best-effort (a failure logs and toasts, never fails the import; Create mind map retries).
  `MindMap.parse` repairs the reply (short labels, orphans under their branch root, cycles,
  stray links) and returns nil unless all three pillars exist; the pipeline asks once more when a
  pillar has fewer than two parts. Layout is `MindMapLayout` (pure, tested); `Paper.hasMindMap`
  is optional so older records decode.
- The duplicate and cast prompts pause the pipeline on a `CheckedContinuation`. Prompts queue,
  one at a time. Only *new* imports (`existing == nil`) may be discarded by the duplicate
  prompt, because declining deletes the paper.

## Views hold no logic

- A view lays out what it's given and forwards user actions. Anything that decides, computes,
  formats, validates, filters, sorts or picks wording goes in `Presentation/` (pure functions or
  value types, unit-tested) or, if it changes app state, in a method on `AppStore`.
- Allowed in views: layout and styling, `@State` for purely visual state (hover, focus, which
  sheet or disclosure is open, a drag in progress), bindings to a form value type, and calls like
  `store.requestRerun(paper)` or `form.rename(id, to:)`.
- Not allowed in views: `?:` or `if` on app data to choose text, counts or enablement (use e.g.
  `PaperPresentation.playButton`, `LibraryPresentation.badge`), string building and pluralising,
  trimming or parsing input, filtering/sorting collections, file or network access (use
  `PDFFile`, store methods), or duplicating a rule that exists elsewhere.
- Shared forms keep Settings and the setup wizard identical: both use `LLMSettingsForm`,
  `ServerSettingsForm` and `KeySourceFields`.
- Every new presentation type or store method gets tests (`PresentationTests.swift`,
  `AppStoreTests.swift`). Coverage of `Presentation/` should stay near 100%.

## SwiftUI conventions and known traps

- Paper records are saved through `AppStore.persist(id)`, a serial queue that writes the
  *latest* state. Never save a record from a fire-and-forget `Task` with a captured snapshot:
  quick edits then land out of order. `delete` awaits the queue before removing the folder.
- Toasts: always `store.show(_:)`. `toast` is `private(set)` because direct assignment never
  auto-dismissed.
- Destructive confirmations go through `store.pendingConfirmation`, presented once from
  `ContentView`. A `confirmationDialog` attached inside a context menu is torn down when the
  menu closes.
- Sheets whose content depends on async-loaded data use `.sheet(item:)` with the data as the
  item. `isPresented` plus separate state can render the empty branch (the transcript sheet
  showed "No transcript yet" this way).
- `@AppStorage` inside an `ObservableObject` does not publish changes. Use `@Published` with a
  `didSet` that writes `UserDefaults` (see `PlayerController.voiceSpeed`).
- The inspector is a manual pane on purpose. `.inspector()` was removed in c5a0161 to fix an
  Auto Layout invalidation-loop crash during playback; don't bring it back.
- The sidebar uses the native `List(selection:)`. Its highlight follows the user's system accent,
  not the app's orange tint; a hand-drawn replacement was tried and rejected. Keep native.
- Cover images are keyed on `store.artworkRevision[id]`; call `pdfStored(id)` whenever a PDF is
  written so covers reload.
- System notifications (`Notifier`) post only while the app is in the background and need a
  `.app` bundle; they are skipped under `swift run`.
- Settings pages save silently and only when values change; the Save button shows an inline
  "Saved". Don't add toasts there, because the toast overlay sits behind the settings sheet.

## Style

- Match the surrounding code: comments explain *why*, not what, and stay short. Keep the existing
  naming and idioms (glass styles, `Theme` helpers, `Color.appAccent`).
- User-facing copy: plain and specific. Say what happened and what to do next.
- Keep `README.md` in step with user-visible behaviour (shortcuts, settings, data locations). Its
  opening warning note stays exactly as written.
- The user often has uncommitted work in progress. Build on top of it, and don't commit, revert,
  or reformat unrelated code unless asked.
