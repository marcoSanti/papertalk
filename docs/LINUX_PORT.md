# Porting Papertalk to Linux: plan

Status: **planning** (branch `port/linux-plan`). Nothing here is implemented yet.

The goal is a Linux build of Papertalk that does what the macOS app does: import a PDF, write the
episode with an LLM, bake the audio with Kokoro, and play it, all with the same library format.

## Ground rules

1. **Swift stays the language.** The app logic (`AppStore`, `LocalPipeline`, storage, everything
   in `Presentation/` and `Models/`) is shared by both platforms, not rewritten.
2. **The macOS app stays exactly the same.** Same SwiftUI views, same look, same behaviour;
   Linux gets its own UI (decided). Beyond that, change as little as possible. Shared
   code changes only where a macOS-only type leaks into it, and then by putting a small
   protocol in front of that type instead of rewriting the caller.
3. **Native macOS pieces get a Python replacement on Linux**, called from Swift through
   [PythonKit](https://github.com/pvieito/PythonKit). Where plain Swift or a command-line tool
   does the job (opening a URL, revealing a file), we skip Python.
4. **One library format.** A library folder copied from a Mac must open on Linux and the other
   way round (`paper.json`, `transcript.json`, `audio.json`, `turns/<n>.wav`).
5. Each phase lands as its own PR and leaves `main` green on macOS.

## What is macOS-only today

The inventory comes from the imports and symbols in `client/Sources/Papertalk` (~11k lines). About
1.7k lines (`Models/` and `Presentation/`) are Foundation-only and should build on Linux as they are.

| Area | Where | macOS API | Linux replacement |
|---|---|---|---|
| UI (3.7k lines) | `Views/`, `Components/`, `App/`, `Support/Theme.swift` | SwiftUI (macOS 26: `glassEffect`, `NavigationSplitView`, `List(selection:)`, sheets, `confirmationDialog`, `.commands`, `.searchable`, `fileImporter`, `dropDestination`) | See [UI](#the-ui-question) |
| PDF text | `Pipeline.swift` (`extractText`) | PDFKit `PDFDocument` | Python **pypdfium2** |
| PDF covers | `AppStore.thumbnail(of:)`, `PaperComponents` | PDFKit + `NSImage` | pypdfium2 page → PNG `Data` |
| PDF viewer | `PDFViewerWindow.swift` | `NSWindow`, CoreGraphics `CGPDFDocument` | Open the file in the system viewer (`xdg-open`); an in-app viewer can come later |
| Speech (TTS) | `KokoroEngine.swift`, `Kokoro.swift`, model download in `AppStore` | FluidAudio `KokoroAneManager` (Core ML / Neural Engine) | Python **kokoro-onnx** (ONNX Runtime, CPU). Same Kokoro voices (`af_heart`, `am_michael`, …) |
| Playback | `PlayerController.swift` | `AVAudioPlayer` (play, pause, seek, `currentTime`, delegate) | Python **sounddevice** (PortAudio) behind a small player protocol |
| API key | `Models/Settings.swift` (`KeychainStore`) | Security `SecItem*` | Python **keyring** (Secret Service / KWallet) |
| Notifications | `Notifier.swift` | UserNotifications, `NSApp` | `notify-send`, or Python `desktop-notifier` |
| Open / reveal | `AppStore` (`NSWorkspace`) | `NSWorkspace` | `xdg-open`, and the FileManager1 D-Bus `ShowItems` call (via `gdbus`). No Python needed |
| Clipboard | `Support/Clipboard.swift` | `NSPasteboard` | The UI toolkit's clipboard, or `wl-copy`/`xclip` |
| Reactive state | `AppStore` (2 `.sink`s), every `ObservableObject` | Combine | [OpenCombine](https://github.com/OpenCombine/OpenCombine), or the UI toolkit's own `ObservableObject` (see spike S1) |
| Networking | `Pipeline`, `Storage`, `UpdateChecker`, `AppStore` | `URLSession` (fine) | `import FoundationNetworking` under `#if canImport` |
| Paths | `Storage.swift` | Application Support | Foundation maps it to `~/.local/share` on Linux, so no change |

The local storage server (`server/storage_server.py`) and the LLM calls already run on any OS.

## The UI question

**OpenSwiftUI can't do this yet.** Its README calls the project early development, "for
learning and research purposes". On Linux it only builds a *stdout* renderer: "Linux UI
framework integration is not available yet", and text layout is Darwin-only. There is no tagged
release. It's worth re-checking every few months, because it aims to be source-compatible with
SwiftUI, and then our macOS views could compile on Linux nearly as they are. We can't build on
it today.

Other options, in the order I'd recommend them:

1. **[SwiftCrossUI](https://github.com/moreSwift/swift-cross-ui) with its GTK 4 backend.** It is a
   SwiftUI-*inspired* framework, not a source-compatible one. Its views share much of SwiftUI's
   API, it's still in active development, and GTK 4 is its default Linux backend.
   Plan: keep `Views/` for macOS untouched and add a **separate, thin Linux view layer**
   (`PapertalkLinux` target) that uses the same `AppStore` and `Presentation/` types. AGENTS.md
   already requires views to hold no logic, so this layer is layout only. That's the payoff of the
   "views hold no logic" rule. A first full port is a few thousand lines of layout, and we expect
   less because there's no glass styling to reproduce.
2. **SwiftOpenUI** (GTK 4, SwiftUI-shaped API): the author describes it as experimental, and in
   September 2026 said it was suspended. Not a base to build on.
3. **Python GUI (PySide6 or GTK via PyGObject) driven from Swift.** It would work, but every
   `@Published` change would have to be bridged into Python by hand. That's a lot of glue, and it
   goes against "keep Swift". Fallback only.

Spike S1 below decides between 1 and 3 before any UI work starts.

## Target architecture

```
client/
  Package.swift              platforms: macOS 26 + Linux
  Sources/
    PapertalkCore/           library: Models/, Presentation/, AppStore, Pipeline, Storage,
                             PlayerController, KokoroEngine *protocols*. No UI imports.
    PapertalkMac/            platform services for macOS (PDFKit, FluidAudio, AVAudioPlayer,
                             Keychain, UserNotifications, NSWorkspace). Moved, not rewritten.
    PapertalkLinux/          platform services for Linux (PythonKit + Process)
    Papertalk/               the macOS app: today's App/, Views/, Components/ (unchanged)
    PapertalkGTK/            the Linux app: SwiftCrossUI views (new)
  Tests/PapertalkTests/      depends on PapertalkCore only, so it runs on both OSes
python/papertalk_platform/   the Python side: pdf.py, tts.py, audio.py, secrets.py
python/requirements.txt      pypdfium2, kokoro-onnx, onnxruntime, sounddevice, numpy, keyring
```

The seams are a handful of small protocols in `PapertalkCore`, injected into `AppStore`, with
the current code as the macOS implementation:

```swift
protocol PDFService      { func text(of pdf: Data) -> String; func coverPNG(of pdf: Data, width: Double) -> Data? }
protocol SpeechEngine    { func prepare(progress: ...) async throws; func synthesize(text:, voice:, speed:) async throws -> Data /* WAV */ }
protocol AudioOutput     { /* load WAV, play, pause, seek, currentTime, duration, onFinish */ }
protocol SecretStore     { func read() -> String?; func write(_:); func delete() }
protocol SystemShell     { func open(_ url: URL); func reveal(_ file: URL); func copy(_ text: String); func notify(...) }
```

The only change macOS code really needs is that covers become PNG `Data` instead of `NSImage`,
with the view turning them into an image. That's one line in `PaperComponents`.

### Python from Swift

- **One `PythonRuntime` actor** owns the interpreter, and every PythonKit call goes through it on
  a single dedicated thread, so the GIL and thread affinity are never in question. That matches how
  `KokoroEngine` already serialises Kokoro calls.
- Python modules live in `python/papertalk_platform`. Swift imports them with
  `Python.import("papertalk_platform.tts")` and exchanges only simple values (`str`, `bytes`,
  numbers), never Python objects held across calls.
- **Dependencies:** on first launch the app creates a virtualenv at `~/.local/share/papertalk/venv`
  and runs `pip install -r requirements.txt`, the way the Kokoro models are downloaded today. It
  shows progress in the existing setup UI. Packaged builds can ship the venv instead (see
  Phase 5). `PYTHON_LIBRARY` points PythonKit at the matching `libpython3.x.so`.
- **Fallback if embedding misbehaves** (crashes inside ONNX Runtime take the whole app down): the
  same Python modules run as a child process speaking JSON lines over stdin/stdout. The protocols
  above don't change, so the switch is local to `PapertalkLinux`.

## Phases

Each phase ends with `swift build` and the test suite green on macOS and, from Phase 2 on, on
Linux too.

### Phase 0: groundwork and spikes (this branch, then small PRs)
- Linux toolchain: Docker image `swift:6.2` (OrbStack is installed here; start it before use) and
  an `ubuntu-24.04` job in `tests.yml`. It's allowed to fail until Phase 2.
- **S1, UI spike:** a SwiftCrossUI/GTK 4 window with a sidebar `List` with selection, a grid of
  covers from PNG data, a sheet, an alert, a menu with shortcuts, a file-open dialog and a text
  field bound to an `ObservableObject`. Also check whether its `ObservableObject` can be the same
  one `AppStore` uses (with Combine/OpenCombine) or needs an adapter. The result decides SwiftCrossUI
  vs Python GUI.
- **S2, Python spike:** from Swift via PythonKit in the container: pypdfium2 text and cover PNG,
  then kokoro-onnx synthesising `af_heart` to WAV, then sounddevice playing it with
  pause/seek. Also measure kokoro-onnx speed on CPU for a 30-minute episode, so the import
  progress estimates can be adjusted.

### Phase 1: split the package (macOS only, no behaviour change)
- Create the `PapertalkCore` library from `Models/`, `Presentation/` and the controllers. The tests
  depend on it. Move the Apple-specific code behind the protocols above into `PapertalkMac`.
- `Image(nsImage:)` → PNG `Data` for covers. `AppStore` gets its services injected, and tests
  inject fakes (Kokoro and the Keychain stay untested, as today).
- Done when the macOS app looks and behaves identically and the suite passes. Before merging,
  compare screenshots of every screen (library, detail, player, import, settings, cast,
  authors) before and after the split.

### Phase 2: `PapertalkCore` builds and tests on Linux
- `#if canImport(FoundationNetworking)`, `#if canImport(Combine)` → OpenCombine, and
  guard the remaining Apple-only APIs.
- `NetworkGuard`/`MockLLM` rely on `URLProtocol`, which works on Linux. Verify.
- Done when the Linux CI job is green and required.

### Phase 3: Linux platform services
- `PythonRuntime`, then PDF, TTS (with model download into `~/.cache/papertalk/kokoro`), audio
  output, secrets, and shell (xdg-open, D-Bus reveal, notify-send, clipboard).
- Swift-side tests use fakes. Python modules get their own small pytest suite, which runs in CI on
  Linux.
- Done when a headless `papertalk-cli import paper.pdf` (a tiny debug executable) produces a
  complete episode folder on Linux that the macOS app can play.

### Phase 4: the Linux UI (`PapertalkGTK`)
Port screen by screen, in this order: library grid and list → detail pane → bottom player bar
→ import sheet → settings and setup wizard → cast sheet → authors view → transcript view. Every
string, count and enablement comes from `Presentation/`. If a Linux view needs a decision that
isn't there yet, add it to `Presentation/` with a test, and the macOS view should use it too.

### Phase 5: packaging and releases
- `.desktop` file and PNG icons generated from `shared/icon.icns`, with the DEV stripe for dev
  builds as on macOS.
- An AppImage (first choice; Flatpak later), with the Python venv bundled.
- `app.sh` learns Linux targets. `release.yml` adds an `ubuntu` job that uploads
  `Papertalk-<version>-linux-x86_64.AppImage` beside the macOS zip. The update checker
  (`UpdateCheck`) then needs to know which asset fits the platform.

### Later
- Re-check OpenSwiftUI. If it gains a Linux renderer, try compiling the macOS `Views/` against it
  and retire `PapertalkGTK`.
- An in-app PDF viewer on Linux, built from pypdfium2 page renders.

## Decisions needed from you

1. **Distros and CPU:** Ubuntu 24.04 / Fedora 41+ on x86_64 only, or arm64 too?
2. **GTK 4** as the Linux toolkit is the plan; KDE users still get a GTK app. OK?
3. **Python dependencies:** download them on first launch (small download, needs Python 3.10+ on
   the system), or bundle them in the AppImage (≈400 MB with ONNX Runtime)?

## Risks

- SwiftCrossUI is pre-1.0. API churn and missing pieces may need workarounds or upstream PRs.
  Spike S1 is there to find these early.
- Kokoro on CPU is much slower than on the Neural Engine, so long in-depth episodes may take a
  long time to bake. Spike S2 measures this.
- Swift on Linux has some Foundation gaps (`URLSession` details, `ProcessInfo`, file attributes).
  Phase 2 surfaces them through the tests.
- Embedding Python means a crash in a native extension kills the app. The subprocess fallback
  is designed in from the start.
