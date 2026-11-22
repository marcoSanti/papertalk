# Linux port

Part of the [development guide](../../AGENTS.md): the paused GTK port and its traps.

- The `Papertalk` target builds on macOS and Linux. macOS-only files are wrapped in
  `#if os(macOS)` and live under `macOS/` (App, Views, Components, Controllers, Support). Linux
  supplies same-named compat shims in `Linux/`, so shared code compiles unchanged. Prefer extending a shim to adding `#if` in shared code.
  Never change how the macOS app looks or behaves for the port's sake.
- A new file goes in `Shared/`, `macOS/` or `Linux/` by where it compiles, and files in `macOS/`
  and `Linux/` keep their whole-file `#if os(...)` guard (one target compiles every folder;
  SwiftPM can't exclude files per platform).
- Build and test Linux with Docker (OrbStack here): `linux-dev/dev.sh build` once, then
  `linux-dev/dev.sh test` (Swift suite + pytest) and `linux-dev/dev.sh e2e` (the opt-in
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
  helpers go in `Linux/AppStore+Linux.swift`.
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
- Look at the UI headless: `linux-dev/dev.sh screenshot` runs it under Xvfb and openbox on
  a demo library and saves PNGs to `.build-linux/shots/`; `PAPERTALK_UI_SCRIPT` drives it
  with xdotool and `PAPERTALK_UI_ARGS` passes a PDF to import. xdotool can't type into GTK 4's
  file dialog, so pass the PDF as an argument. `PAPERTALK_AUDIO_SINK` replaces the sound
  server's player (e.g. `cat > /dev/null` where there is no sound card).

Done in the Linux UI: library (sidebar, search, covers), detail pane, player bar (playback,
scrubber, import progress), import sheet (and `Papertalk paper.pdf`), cast and duplicate
prompts, delete/rerun confirmation, opening the PDF, settings and first-run setup.

Packaging: `linux-dev/dev.sh appimage` (with `VERSION`, `CHANNEL`) builds
`dist/Papertalk-<version>-<arch>.AppImage`: release binary with the Swift runtime
static, a bundled Python 3.12 with the packages (so nothing is installed at first launch), every
other library except the GTK / graphics / glibc stack, and a `.desktop` file with `%f`.
`linux-dev/appimage_smoke.sh` checks it on plain Ubuntu. CI used to pack and smoke-test it
on every PR and upload it to each release (x86_64); those jobs are paused (`if: false` in both
workflows, plus the `LINUX_BUILDS` guard in the release notes) until the Linux work resumes.
If you add a Python package or a native dependency, run the smoke test: a library missing from
the bundle only shows up on a clean system.

Still to do, in order:
1. **Rest of the Linux UI:** authors view, transcript view, metadata editing, tag editing,
   clipboard copy, and `Notifier.isAppActive` from the window's focus (notifications are off
   until then). Then a pass on looks (spacing, a grid layout option).
2. **Updates on Linux:** the update check (menu on macOS) and `UpdateCheck` picking the
   AppImage asset, and installing in place (`Linux/UpdateInstallerCompat.swift` only refuses);
   the Linux build has no version stamped in yet (macOS uses Info.plist).
3. Later: an arm64 AppImage (an `ubuntu-24.04-arm` runner), an in-app PDF viewer from
   pypdfium2 renders, and a re-check of OpenSwiftUI for a Linux renderer.
