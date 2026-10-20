# Papertalk

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![Voices: Kokoro](https://img.shields.io/badge/voices-Kokoro%20(on--device)-D07040)
[![Tests](https://github.com/marcoSanti/paper2pod/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/marcoSanti/paper2pod/actions/workflows/tests.yml)

Papertalk turns a scientific paper into a podcast episode, right on your Mac. You give it a
PDF; it writes a conversation between an interviewer and one of the paper's authors, then
reads it aloud with neural voices that run on your own machine. It's a native macOS app written
in SwiftUI.

> [!WARNING]
> This app is vibecoded. I had the need not the time. Bugs are expected and help is appreciated

## How it works

When you import a paper, Papertalk first pulls the text out of the PDF and asks an LLM to fill
in the details: title, authors, affiliations, DOI and a few tags. If there's a DOI, it also
fetches a BibTeX citation for you.

Next it proposes a cast: an interviewer, and one of the paper's real authors as the guest. A
small sheet lets you rename them, pick which author is interviewed, and choose each person's
voice. You can play a short sample of any voice before you decide. **Skip audio** writes the
script with those names and voices but doesn't voice it yet; **Regenerate audio** voices it later.

Then the LLM plans the episode and writes the dialogue section by section, following the depth
you picked. *In-depth* walks through the method faithfully, *Summary* stays high-level and fits
the length you set on the import sheet (5 to 60 minutes), *Custom* follows your own instructions
(which you can save as presets), and *Direct read* skips the LLM entirely and reads the paper out
as-is.

It also draws a **mind map** of the paper: its key concepts as a graph around three branches,
the problem, the approach and the demonstration, each broken into its parts. Open it with
**Mind map** in the paper's details: it opens in its own window, which you can resize or
maximise. Clicking a concept shows what it means, its core idea and what it connects to. Papers
imported earlier get one with **Create mind map** under Manage, with its progress in the bottom
bar like an import.

Finally every line is voiced with [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M), running
on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio), or
on a text-to-speech server of your own (see [Voices on a server](#voices-on-a-server)). The
audio is saved with the paper, so playback afterwards is instant.

Any OpenAI-compatible chat endpoint works for the writing part: LM Studio, llama.cpp, Ollama
behind OpenWebUI, or a hosted API. If that endpoint runs locally, nothing about your papers ever
leaves your Mac.

## Getting started

You need macOS 26 or later (Apple silicon recommended) and Xcode with Swift 6.2. Build and open
the app with:

```bash
../app.sh run
```

`app.sh` lives at the repo root and is run from anywhere (from `client/` use
`../app.sh`). It handles the whole build/run/test/release lifecycle. This puts a debug build in
`client/dist/Papertalk.app`. Use `app.sh release` for an optimized build zipped to
`dist/Papertalk-<version>.zip`, with the committed source next to it as
`dist/Papertalk-<version>-source.tar.gz`. Builds you make yourself, like the development builds
below, show a yellow "DEV" stripe on the app icon; only official releases use the plain icon
(`CHANNEL=stable ./app.sh release`). Ready-made builds are on the
[Releases](https://github.com/marcoSanti/paper2pod/releases) page. The app is only ad-hoc signed, so if macOS refuses to
open a copy you've moved to another Mac, right-click it and choose **Open**.

To see whether there is something newer, choose **Papertalk → Check for Updates…** (stable
releases) or **Papertalk → Check for Dev Builds…** (the latest builds of `main`). Papertalk asks
GitHub, compares with the version you're running and offers the release page if there's a newer
one; it never downloads or installs anything by itself.

On first launch a short setup asks where your library should live (on this Mac, or on a
[storage server](#sharing-a-library-between-macs)) and which LLM should write the episodes:
its base URL, an optional API key and the model. Then it asks where the voices should be
synthesized: on this Mac, or on a [speech server](#voices-on-a-server). **Test connection**
checks that the storage server and the LLM answer.
You can skip the setup and change all of this later in **Settings** (⌘,).

With voices on this Mac, the first episode takes a little longer, because it downloads the voice
models (about 120 MB).

### Linux (preview)

A Linux version is in progress. Each release also has `Papertalk-<version>-x86_64.AppImage`:
make it executable and run it (or open a PDF with it). It needs a desktop with GTK 4 (Ubuntu
22.04+, Fedora 36+ and alike) and brings everything else with it, Python included. The voices
are generated on the CPU with the same Kokoro voices as on the Mac, and the library format is
the same, so a library folder can move between the two. Not everything from the Mac app is
there yet (no authors or transcript views, no metadata editing).

To build it yourself you need Docker; the build runs in a container:

```bash
client/linux-dev/dev.sh build
```

```bash
client/linux-dev/dev.sh appimage
```

That writes `client/dist/Papertalk-<version>-<arch>.AppImage` for your machine's architecture.

## Using it

Import a paper with **File → Import PDF…** (⌘O), the **+** button, or by dropping a PDF onto the
library. Conversion runs in the background and shows its progress at the bottom of the window;
you can keep listening to something else in the meantime. If you switch to another app,
Papertalk sends a notification when an episode is ready, when one fails, or when it needs you to
answer a question (like choosing the voices).

Select a paper to see its details on the right. From there you can play the episode, read the
transcript, open the PDF, favourite it, tag it, or fix its metadata. Space plays and pauses, the
arrow keys move around the grid, and Delete removes a paper (after asking). Episodes remember
where you stopped.

On macOS the playing episode also shows in Control Center's Now Playing, with its title, authors
and cover. The keyboard's media keys and the Control Center buttons play and pause it, skip to the
next or previous turn, jump 15 seconds, or move along it.

The sidebar groups the library by favourites and tags, and **Authors** shows everyone in your
library like a contact book: open an author to see their papers and jump to their co-authors.
Search matches titles, authors and DOIs; start with `#` to search tags.

If an episode doesn't sound right, **Regenerate audio** re-voices the existing script, and
**Rerun episode** writes a new one from scratch. To change how the LLM writes, edit any of the
prompts it's sent in **Settings → Query Prompts** (the reply formats are added automatically).

A conversion can be stopped while it runs, with **Stop conversion** in the paper's details or its
right-click menu. The script and any sections already voiced are kept, and **Try again** carries
on from there. Deleting a paper that's still converting stops it first.

Episodes take disk space, so **Delete audio** (in the details' Manage list or the right-click menu)
removes a paper's voiced audio and keeps its script and PDF. The paper still plays, with voices
made live, and **Regenerate audio** voices it again. When you listen to an episode to the end,
Papertalk asks whether to keep or delete its audio; **Keep, and don't ask again** turns that off,
and **Settings → Clear Data** turns it back on.

## Sharing a library between Macs

Papers normally live in `~/Library/Application Support/papertalk/`. To use one library from
several Macs, run the small storage server that comes with the project on any machine with
Python 3. It only stores files; conversion still happens in the app.

```bash
python3 server/storage_server.py
```

It listens on port 9170 and uses only the standard library, so there's nothing to install. Set
`PAPER2POD_STORAGE_TOKEN` to require a token. Then point the app at it in **Settings → Server
Settings** (`http://<host>:9170`, plus the token). Clearing the URL switches back to the local
library.

<details>
<summary>Server options and API</summary>

The server reads `PAPER2POD_STORAGE_PORT` (default `9170`), `PAPER2POD_STORAGE_ROOT` (default
`~/.paper2pod/storage`) and `PAPER2POD_STORAGE_TOKEN` (optional bearer token).

It's a flat key/value store over HTTP: `GET /` lists the keys, and `GET`, `PUT`, `DELETE` and
`HEAD` on `/<key>` read, write, delete and check a file. Keys look like
`papers/<id>/paper.json`, `papers/<id>/source.pdf` or `papers/<id>/turns/<n>.wav`.

</details>

## Voices on a server

Voicing an episode on the Mac takes about half a gigabyte of memory while it runs, which is a
lot on an 8 GB machine. **Settings → Voices** (also in the first-run setup) can send the speech
to an OpenAI-compatible text-to-speech server instead, such as
[Open WebUI](https://docs.openwebui.com/) or [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI).
Then nothing is loaded on the Mac.

- **Server URL**: Papertalk calls `/audio/speech` under it. For Open WebUI that's its address
  followed by `/api/v1` (e.g. `http://localhost:3000/api/v1`; the `/api` URL from the LLM
  settings works too); for Kokoro-FastAPI, `http://<host>:8880/v1`.
- **API key**: none, typed, or read from an environment variable (`OPENWEBUI_API_KEY`,
  `LLM_API_KEY` or `PAPERTALK_API_KEY`), the same choices as for the LLM. Keys are kept in the
  Keychain. Open WebUI needs one (Settings → Account → API keys).
- **Model**: Papertalk asks the server what it offers (`/audio/models` or `/models`) and fills
  the picker. If it lists nothing, type the model name.
- **Requests at a time**: how many sections are voiced at once (1 to 16, default 4). More is
  faster if the server keeps up. Voices on the Mac are always made one section at a time.

The server should run Kokoro: each paper's cast, chosen when you import it, is sent by voice name
(`af_heart`, `am_michael`, …). Papertalk checks the server's `/audio/voices` and warns if
Kokoro's voices aren't there. It asks for WAV; MP3 and other formats are converted on the Mac. Every synthesis path uses the setting: importing, **Regenerate audio**,
playing a paper that has no audio yet, and the voice samples in the cast sheet.

## Settings, keys and data

Everything is configured inside the app. If you'd rather set defaults from the environment, the
app picks up `OPENWEBUI_BASE_URL` or `LLM_BASE_URL`, `PAPERTALK_MODEL`, and an API key from
`OPENWEBUI_API_KEY`, `LLM_API_KEY` or `PAPERTALK_API_KEY`. `PAPERTALK_SERVER_URL` and
`PAPERTALK_API_TOKEN` set a default storage server.

API keys (the LLM's and the speech server's) are kept in the macOS Keychain, never in the
preferences file. The voice models live in
`~/.cache/fluidaudio/`. **Settings → Clear Data** can erase the library and reset everything, or
separately delete the voice models if you want the disk space back.

## Contributing

As the note at the top says, there are rough edges, and help is very welcome. The app lives in
`client/` (a Swift package), the storage server in `server/`. `client/UI_ISSUES.md` lists known
UI problems and what's already been fixed. If you report a bug, the **Activity** log in the
paper's details panel is the most useful thing to include.

### Running the tests

```bash
../app.sh test        # or: swift test --disable-swift-testing
```

The suite runs in about ten seconds and needs nothing external: no LLM server, no network, no
Keychain, no voice models, and it never touches your real library. LLM replies come from an
in-process mock, the storage server is faked, and each test uses its own temporary folder. A
built-in guard fails any test that tries to reach a real server, so a test can't quietly start
calling one.

The SwiftUI views contain only layout: every rule they display (labels, validation, which
controls are enabled, how authors are grouped, what the player shows) lives in plain Swift types
under `client/Sources/Papertalk/Shared/Presentation/`, so it can be tested without running the UI.

It covers the presentation layer, the library (filtering, search, sorting, authors, tags, edits
and how they're saved, deleting), the storage backends, the LLM steps (metadata, casting, outline, dialogue and
monologue, episode length per depth), voice choice, playback timing, settings and the data
formats on disk. The speech server client is tested against a mocked server, and so are the
audio conversion and which backend each path uses. Kokoro synthesis itself isn't tested, since
it needs the model and the Neural Engine. When you fix a bug, add a test that fails without the fix.

`app.sh coverage` runs the same suite with code coverage, using only the Xcode toolchain, and
writes the results to `coverage/` (a per-file table, `report.txt` and `lcov.info` for editors). Coverage is reported two ways: **logic** (models, controllers, helpers), which is what the
tests are meant to protect, and **all code**, which also counts the SwiftUI views that have no UI
tests yet.

No coverage service is involved: on GitHub, each test run shows the coverage table on its
summary page, with the full report attached to the run.

### Pull requests, versions and releases

Work happens on branches and lands on `main` through pull requests. GitHub Actions builds the app
and runs the tests on every pull request and on every push to `main`
(`.github/workflows/tests.yml`).

Versions follow [semantic versioning](https://semver.org) and live in the `VERSION` file at the
root (starting at `0.0.1`); the build stamps it into the app. To cut a release:

```bash
./app.sh bump-patch     # or bump-minor / bump-major; open a PR with the new VERSION
# and merge it to main
```

Merging the bumped `VERSION` to `main` runs `.github/workflows/release.yml`: it sees the version
changed, builds the optimized app and publishes a GitHub release, marked Latest, tagged
`v<VERSION>`, with `Papertalk-<version>.zip`, the source it was built from
(`Papertalk-<version>-source.tar.gz`) and a SHA-256 checksum for each. Only these releases get the
official app icon.

Every other merge to `main` publishes a **development build** as a pre-release, tagged
`v<VERSION>-dev.<commit>` (for example `v0.0.1-dev.f961491`), so the newest merged code is always
downloadable from [Releases](https://github.com/marcoSanti/paper2pod/releases). Only the ten newest
development builds are kept. Their app icon carries the "DEV" stripe.
