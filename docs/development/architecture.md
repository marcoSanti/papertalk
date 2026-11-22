# Architecture

Part of the [development guide](../../AGENTS.md): where the code lives.

- `Package.swift`: the Swift package, at the repo root (target `Papertalk`). It is the macOS app and
  also builds the Linux binary (tooling in `linux-dev/`). `Sources/Papertalk/` is split by
  platform: `Shared/` (both), `macOS/` (macOS only) and `Linux/` (Linux only). The UI and
  the whole pipeline (PDF → metadata → cast → script → audio) run in-process.
  - `Shared/Controllers/AppStore.swift`: the single `@MainActor` `ObservableObject` holding all app
    state, the import pipeline orchestration, and every mutation. Start here.
  - `Shared/Controllers/Pipeline.swift`: LLM calls (`LocalPipeline`): metadata, cast proposal, plan,
    dialogue/monologue writing, JSON parsing.
  - `macOS/Controllers/KokoroEngine.swift`: the only Kokoro TTS instance (on Linux,
    `Linux/KokoroCompat.swift`). `Shared/Models/Kokoro.swift` holds voice lists and pools;
    their labels are in `Shared/Presentation/VoicePresentation.swift`.
  - `Shared/Controllers/PlayerController.swift`: episode playback and voice-sample previews.
  - `Shared/Controllers/Storage.swift`: `StorageFactory` and `HttpStorage` (the storage
    server's client). `Shared/Models/LibraryStore.swift` re-exports `PapertalkStore`, so the app
    sees `Storage`, `K` and `LocalStorage` without importing it.
  - `Shared/Controllers/AppStore+Actions.swift`: the small actions views forward;
    `AppStore+Forms.swift`: the I/O forms need (model lists, the chosen PDF).
  - `Shared/Presentation/`: everything the views show or decide, as pure Swift with no SwiftUI:
    wording and labels, form state and validation (`ImportForm`, `MetadataForm`,
    `LLMSettingsForm`, `ServerSettingsForm`, `CastForm`), grouping/sorting (`AuthorsPresentation`),
    and display decisions (`EpisodeProgress`, `BottomBarContent`, `PlayerPane`, `PlaybackStatus`).
  - `macOS/Views/`, `macOS/Components/`: SwiftUI layout only (see [Views hold no logic](ui.md#views-hold-no-logic)).
    `macOS/Support/Theme.swift` has shared styling (`glassCard`, `StatusBadge`, `FlowLayout`,
    `Color.stable(for:)`); `macOS/Support/Clipboard.swift` copies text.
- `Sources/PapertalkStore/`: a library target shared by the app and the server:
  `Storage.swift` (the `Storage` protocol, the `K` key layout, `LocalStorage`) and
  `StorageServer.swift` (the HTTP key/value server over a `LocalStorage` folder; no compute).
  Foundation and POSIX sockets only: it must never depend on the app's frameworks.
- `Sources/PapertalkServer/main.swift`: the server's command line (`app.sh server`),
  configured by the `PAPER2POD_STORAGE_*` env vars (loopback only unless given a token or host). It replaced `server/storage_server.py`
  and adopts roots that script wrote (plain `papers/<id>/` folders become packages).
- `VERSION`: the app version, edited by hand (`app.sh version` prints it).
- `CHANGELOG.md`: what each release changes, shown in the app's "What's new" sheet (see [releases](releases.md)).
- `scripts/check_layers.sh`: the MVC layer check (see [MVC layers](../../AGENTS.md#mvc-layers)).
- `scripts/coverage.sh`, `scripts/coverage_summary.py`: code coverage (`app.sh coverage`).
- `.github/workflows/`: `tests.yml` (pull requests) and `release.yml` (`main`: dev + stable releases).
- `shared/`: app icon (`icon.icns`, drawn by `scripts/icons.swift`), and `Papertalk.help/`, the
  user guide (macOS Help Book, see [User guide](user-guide.md)).
- Linux port pieces: `Sources/Papertalk/Linux/` (compat shims, `#if os(Linux)`),
  `python/papertalk_platform/` (PDF, Kokoro, keyring services for Linux, with pytest tests),
  `linux-dev/` (dev container `Dockerfile`, `dev.sh`).
- `Tests/PapertalkTests/`: the XCTest suite (see [Tests](testing.md)).
