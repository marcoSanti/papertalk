# AGENTS.md

Guidance for coding agents working on Papertalk. Read `README.md` for what the app does; this
file covers how to work on it and the traps that have already bitten.

## Repo map

- `client/`: the macOS app, a Swift package (`Package.swift`, target `Papertalk`). The UI and
  the whole pipeline (PDF → metadata → cast → script → audio) run in-process.
  - `Controllers/AppStore.swift`: the single `@MainActor` `ObservableObject` holding all app
    state, the import pipeline orchestration, and every mutation. Start here.
  - `Controllers/Pipeline.swift`: LLM calls (`LocalPipeline`): metadata, cast proposal, plan,
    dialogue/monologue writing, JSON parsing.
  - `Controllers/KokoroEngine.swift`: the only Kokoro TTS instance. `Kokoro.swift` holds voice
    lists, labels and pools.
  - `Controllers/PlayerController.swift`: episode playback and voice-sample previews.
  - `Controllers/Storage.swift`: `LocalStorage` (Application Support) and `HttpStorage`
    (`server/storage_server.py`), plus the `K` key layout.
  - `Views/`, `Components/`: SwiftUI. `Support/Theme.swift` has shared styling (`glassCard`,
    `StatusBadge`, `FlowLayout`, `Color.stable(for:)`).
- `server/storage_server.py`: optional stdlib-only HTTP key/value file store. No compute.
- `shared/`: app icon.
- `client/UI_ISSUES.md`: running list of UI/UX issues and fix notes. Update it when you fix or
  find one.

## Build and check

```bash
cd client
swift build          # compile; this is the main check (there is no test target)
make app             # build dist/Papertalk.app (debug); `make release` for an optimized zip
```

- Requires macOS 26 and Swift 6.2 tools; the target compiles in Swift 5 language mode.
- Always run `swift build` after a change and report the result. There are no automated tests.
  For logic that can be isolated (parsers, decoders), a throwaway `swiftc` script in a scratch
  directory is a quick way to check it.
- `open dist/Papertalk.app` and `screencapture` may be blocked in a sandboxed agent shell. Don't
  launch a second copy of the app if the user already has it open, and never `pkill` it. If you
  can't see the UI, say so plainly instead of claiming a visual check.

## Data and storage

- Local library: `~/Library/Application Support/papertalk/papers/<id>/`, containing
  `paper.json`, `source.pdf`, `transcript.json`, `audio.json` (manifest) and `turns/<n>.wav`.
  Kokoro models: `~/.cache/fluidaudio/Models/kokoro*`.
- Everything for a paper lives under `K.folder(id)`. Delete a paper with
  `storage.deleteFolder(K.folder(id))`, never with a hand-written list of keys (that left
  orphaned folders before).
- **`Paper` is decoded from disk with synthesized `Codable`.** A new non-optional property added
  to `CodingKeys` makes every existing `paper.json` fail to decode, and those papers silently
  vanish from the library. Add new fields as optionals (see `storedSpeakers` and its computed
  `speakers` wrapper), or write a tolerant `init(from:)`. A property left *out* of `CodingKeys`
  is silently never saved.
- API keys live in the Keychain only (`KeychainStore`). `LLMSettings.save()` strips the key
  before writing user defaults; keep it that way.

## Pipeline rules

- **Audio is baked at import** and saved per turn; playback uses the baked audio. Live synthesis
  in `PlayerController.prepare(transcript:)` is only a fallback for papers without complete
  audio, and it plays progressively. Don't move the normal path to live synthesis.
- `bakeAudio` reuses turns already on disk, so re-running it resumes. On failure it returns a
  message and the paper goes to an error state via `failAudio`, never to "done" without audio.
- **Use `KokoroEngine.shared` for all synthesis.** Never create another `KokoroAneManager`: two
  model copies on the Neural Engine, or overlapping calls into one (actors are re-entrant across
  `await`), fail with "unable to compute the asynchronous prediction".
- `LocalPipeline.extractJSON` takes text from the first `{` to the last `}`. **Ask the LLM for a
  JSON object, never a top-level array**: an array gets mangled and the parse silently falls
  back to defaults (this broke the cast step for a long time).
- Depth: only `.inDepth` may have full-length method monologues; `generateTranscript` forces
  every other depth to dialogue. Summary aims for about 30 minutes, with a hard 35-minute word
  ceiling enforced segment by segment. In-depth has no cap and scales with the paper. Lengths
  assume about 145 spoken words per minute at the default pace.
- Cast: the interviewer keeps the signature voice for their gender (Heart / Michael); the guest
  gets `KokoroSpeech.guestVoice` (same gender, different voice, stable per name). Gender comes
  from the LLM (per speaker and per author); `KokoroSpeech.guessGender(fromName:)` is only a
  fallback. The sheet shows the gender so the user can correct it. Never let an unknown gender
  quietly become a female voice.
- The duplicate and cast prompts pause the pipeline on a `CheckedContinuation`. Prompts queue,
  one at a time. Only *new* imports (`existing == nil`) may be discarded by the duplicate
  prompt, because declining deletes the paper.

## SwiftUI conventions and known traps

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
