# CI, pull requests and releases

Part of the [development guide](../../AGENTS.md): workflows, versions, the changelog, icons and the updater.

- Work goes through pull requests into `main` (squash or rebase; one approving review). CI does
  only what's needed, on GitHub's `macos-26` runner:
  - `tests.yml`, on every PR into `main` (not on one stacked on another branch): `app.sh coverage`
    (the layer check and the suite, once, with coverage; it builds and tests the storage server
    too). No app bundle: nothing would be uploaded. PRs that change only
    Markdown skip it (no check is required, so they can still merge).
  - `release.yml`, on every push to `main` (Markdown-only pushes skip it): `app.sh test`, then the
    release build and the GitHub release (see below). It's the only run on `main`, so it's what
    tests `main`. It can be started by hand to retry a release, from `main` only.
  - The Linux jobs in both are paused (`if: false`); see [Linux port](linux.md).
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
- **Before merging, every PR with a user-visible change adds one line to `CHANGELOG.md`**
  under `## Unreleased`: `- <emoji> **Title**: one short sentence.` Pick one emoji that shows
  the action (📚 a new list, 🐛 a fix, ⚡️ faster, 🎨 looks), keep the title to a few words
  named as the UI names things, and say what changed for the user, not how. CI-only, test-only
  and refactoring PRs add nothing. `WhatsNewTests` fails on a line the app can't read.
  `app.sh` embeds only the build's section (`## <VERSION>` without any `-dev` suffix, else
  `## Unreleased`) as the `PapertalkWhatsNew` Info.plist string. After an update the app shows
  those entries once (`WhatsNew`, `AppStore.showWhatsNewIfUpdated`), never on a first launch.
  When bumping `VERSION` to `X.Y.0`, rename `## Unreleased` to `## X.Y.0` and add a new empty
  `## Unreleased` above it. Patch bumps leave it alone: giving a patch its own section releases it
  as stable (below).
- Bump by editing `VERSION` as part of a PR. Patch for fixes, minor for features, major for
  breaking changes (e.g. a library format that older builds can't read).
- Stable releases are CI-driven: on a push to `main`, `.github/workflows/release.yml` publishes
  a full release tagged `v<VERSION>`, marked Latest, when that tag doesn't exist yet and either:
  - `VERSION` is `X.Y.0`, or
  - `VERSION` is a patch and `CHANGELOG.md` has a line that is exactly `## <VERSION>`.
  Any other patch ships as dev pre-releases (`v<VERSION>-dev.<commit>`), so users of stable builds
  only get it with the next stable release.
- **A patch's changelog section is its release switch.** Write one only when the user asks to
  release that patch: in the PR that bumps `VERSION`, rename `## Unreleased` as for `X.Y.0`.
  There is nothing to edit in the workflow. A section merged later in a Markdown-only PR doesn't
  start the workflow: run Release by hand from `main`. Deleting the tag of the current `VERSION`
  makes the next run publish it again.
- Icons: the `CHANNEL` env var of `app.sh` (default `dev`) picks the app icon. Only a stable
  release (see above) builds with `CHANNEL=stable` and gets the official
  `shared/icon.icns`; every other build (local, CI, dev pre-releases) gets a "DEV" stripe version
  generated into `.build/icons/` by `scripts/icons.swift dev`. Don't ship the official icon
  from anything but a stable release. The exception is the Finder icon of `.papertalk` files
  (`PaperDocument.icns`, a page with the app icon on it, from `scripts/icons.swift document`): it's
  made from the official icon on every channel, so a file's icon doesn't depend on the build.
- The official icon is drawn in code: change `AppIcon` in `scripts/icons.swift`, run
  `swift scripts/icons.swift app shared/icon.icns`, and commit both. Every other icon (dev,
  document, the Help Book's `icon.png`, the Linux AppImage's PNG) is generated from that file at
  build time, so never edit those. Keep shapes filled and thick: it has to read at 16 px.
- The in-app updater (`UpdateInstall`, `macOS/Controllers/UpdateInstaller.swift`) installs a stable
  release from its `Papertalk-<version>.zip` and `Papertalk-<version>.zip.sha256` assets, checks the
  unzipped app's bundle id and version, and swaps it in with `UpdateInstall.swapScript` after the app
  quits. Renaming those release assets, or the zip's top-level `Papertalk.app`, breaks it: keep them.
- `app.sh release` also writes `dist/Papertalk-<version>-source.tar.gz` (`git archive` of HEAD);
  the release workflow publishes it, with checksums, beside the app zip.
- Dev builds: every other push to `main`, unless it changes only Markdown, publishes a **pre-release**
  `v<VERSION>-dev.<short commit>`, built with `VERSION=<that> app.sh release` (the `VERSION`
  env overrides the file for that build only). It keeps the newest 10 dev builds and deletes
  older ones with their tags. Never create `-dev.` tags by hand, and never push tags or bump the
  version unless the user asks.
