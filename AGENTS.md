# AGENTS.md

Guidance for anyone, human or agent, working on Papertalk. Read `README.md` for what the app does.
This file holds the rules for every change. The details, and the traps that have already bitten,
are in `docs/development/`: **read the page for an area before changing it.**

## Guides

| Before you touch | Read |
| --- | --- |
| Anything, if you don't know where it lives | [Architecture](docs/development/architecture.md) |
| `AppStore` saves, `Storage`, the server, settings, the Keychain, Erase | [Data and storage](docs/development/storage.md) |
| Imports, prompts, LLM replies, speech, Kokoro (FluidAudio #817), mind maps | [Pipeline](docs/development/pipeline.md) |
| A view, a presentation type, interface text | [Interface](docs/development/ui.md) |
| A test | [Tests](docs/development/testing.md) |
| `VERSION`, `CHANGELOG.md`, workflows, `app.sh`, icons, the updater | [CI and releases](docs/development/releases.md) |
| Anything a user will notice | [User guide](docs/development/user-guide.md) |
| `Linux/`, `linux-dev/`, `python/` | [Linux port](docs/development/linux.md) |

When a change makes a page wrong, fix that page in the same PR. A new trap goes on its area's
page; only a rule for every change goes here.

## Never

- **Lose the user's data.** A failed read is not an empty one: never save it back. Save papers
  through `persist`, mind maps through `saveMindMap`, and add new `Paper` fields as optionals.
- **Touch the user's real library, settings or Keychain from a test.** Subclass `PapertalkTestCase`
  and never build an `AppStore` on the default storage. Checkouts from before 0.9.1 have no
  Keychain guard: don't run their tests outside a sandbox.
- **Put a secret outside the Keychain**: no API key or password in user defaults or files.
- **Trust an LLM reply or a file**: check numbers, ids and URLs from them before use.
- **Disturb the running app**: don't start a second copy, `pkill` it, or use `app.sh run` while
  the user has it open.
- **Release by accident**: don't bump `VERSION`, push tags, or give a patch its own `CHANGELOG.md`
  section (that publishes it as stable) unless the user asks.
- **Touch work that isn't yours**: the user often has uncommitted work in progress. Build on top
  of it, and don't commit, revert, or reformat unrelated code unless asked.

## Every change

- A bug fix comes with a regression test that fails without the fix; a new presentation type or
  store method comes with tests.
- Interface text goes through `L("…")`, with the key in every pack.
- A change users will notice adds one line under `## Unreleased` in `CHANGELOG.md`, and updates
  the Help Book and `README.md`.

## Build and test

```bash
swift build          # compile (from the repo root)
./app.sh test        # the layer check, then the whole suite: no network, Keychain or real data
./app.sh coverage    # the suite with coverage → coverage/ (summary.md, report.txt, lcov.info)
./app.sh app         # build dist/Papertalk.app (debug); `app.sh release` → dist/Papertalk-<version>.zip
```

`app.sh` (repo root) replaces the old Makefile: build/app/run/release/test/coverage/server/clean/version.
It's run from anywhere.
Every build of the app bundle (`app`, `run`, `release`) registers it with Launch Services and
unregisters every other `Papertalk.app` macOS knows, except copies in `/Applications` (an installed
release stays), so Finder, "Open With" and Help open the build just made. `app.sh run` also quits
the Papertalk that is running: don't use it while the user has the app open.

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

## MVC layers

Dependencies point one way: Views → Controllers → Presentation → Model.

- **Model** (`Shared/Models/`, `Shared/Support/`, `Shared/Localization/`, `Sources/PapertalkStore/`): data, its rules and
  how it's saved. No `L(...)` wording, no network, no UI, nothing from the layers above.
- **Presentation** (`Shared/Presentation/`): wording, forms and display decisions, computed from
  the Model alone. It never names `AppStore`, `PlayerController` or a client. State both it and
  the store need is a Model type (`Shared/Models/AppState.swift`).
- **Controllers** (`*/Controllers/`, and `Linux/AppStore+Linux.swift`): all state changes, and all I/O
  beyond the Model's own saving (settings, Keychain, `LocalStorage`). A record change that words a
  message goes here (`PaperTransitions.swift`).
- **Views** (`macOS/Views/`, `macOS/Components/`, `Linux/UI/`): see [Interface](docs/development/ui.md). They talk to the store,
  the player and the window openers, and never assign their properties.

Two checks enforce it, both in `app.sh test` and CI. `scripts/check_layers.sh` compiles the Model
alone and Model + Presentation alone, so a reference upwards doesn't compile. A file the Model
needs from outside its folders is listed in that script (today only `CompressedAudio.swift`).
`ArchitectureTests` reads the sources for what a compiler can't see (a view writing state or doing
I/O, wording in the Model). Fix the code rather than widening the test's lists.

Before writing a helper, look in `Shared/Support/` (text, HTTP, saved JSON), `Fixtures` (tests)
and `macOS/Components/CommonViews.swift` / `ZoomableMap.swift` (UI).

## Linux port

Paused in CI. macOS and Linux build from one target: prefer a shim in `Linux/` to `#if` in shared
code, and never change the macOS app for the port's sake. Details: [Linux port](docs/development/linux.md).

## Style

- Every source file (Swift, Python, shell) opens with a short comment saying what the file does,
  above its imports and `#if os(...)` guard. Every type, and every function or property whose
  name doesn't say it all, gets a short `///` doc comment (a docstring in Python).
- Match the surrounding code: comments explain *why*, not what, and stay short. Keep the existing
  naming and idioms (glass styles, `Theme` helpers, `Color.appAccent`).
- User-facing copy: plain and specific. Say what happened and what to do next.
- Keep `README.md` in step with user-visible behaviour (shortcuts, settings, data locations). Its
  opening warning note stays exactly as written.
