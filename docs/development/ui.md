# Interface

Part of the [development guide](../../AGENTS.md): views, wording and SwiftUI traps.

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
  store methods such as `readPDF`), or duplicating a rule that exists elsewhere.
- Shared forms keep Settings and the setup wizard identical: both use `LLMSettingsForm`,
  `ServerSettingsForm` and `KeySourceFields`.
- Interface text goes through `L("English wording", args…)` (`Shared/Localization/`), with
  values as `{0}`, `{1}` placeholders, never `\(…)` interpolation. Add each new key to every pack
  in `Shared/Localization/Packs/`; `LocalizationTests` scans the sources and fails on a missing
  or stale key. Only the interface is translated: prompts, logs and what the LLM writes stay
  English, unless an import sets `Paper.scriptLanguage` (then `LocalPipeline.outputLanguage`
  appends the `outputLanguage` prompt).
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
