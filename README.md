# Papertalk

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![Voices: Kokoro](https://img.shields.io/badge/voices-Kokoro%20(on--device)-D07040)
[![Release](https://github.com/marcoSanti/papertalk/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/marcoSanti/papertalk/actions/workflows/release.yml)

Papertalk turns a scientific paper into a podcast episode, right on your Mac. You give it a
PDF; it writes a conversation between an interviewer and one of the paper's authors, reads it
aloud with neural voices that run on your own machine, and draws a mind map of the paper's key
ideas. It's a native macOS app written in SwiftUI.

> [!WARNING]
> This app is vibecoded. I had the need not the time. Bugs are expected and help is appreciated

## Features

- **A real conversation, not a read-out.** An LLM plans the episode and writes it section by
  section: an interviewer asks, one of the paper's actual authors explains. Pick the depth:
  - *In-depth* walks through the method faithfully, as long as the paper needs.
  - *Summary* stays high-level and fits the length you set, from 5 to 60 minutes.
  - *Custom* follows your own instructions, which you can save as presets.
  - *Direct read* skips the LLM and reads the paper out as it is.
- **Choose who speaks.** Before writing, Papertalk proposes the cast. Rename them, pick which
  author is interviewed, give each a voice and hear a sample first, and set the speaking pace.
  **Skip audio** writes the script now and leaves the voicing for later.
- **Voices on your Mac, or on a server.** Every line is voiced with
  [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) on the Neural Engine (through
  [FluidAudio](https://github.com/FluidInference/FluidAudio)), or by a text-to-speech server of
  your own. The audio is saved with the paper, so playback is instant.
- **A mind map of every paper.** The key concepts as a graph around three branches: the problem,
  the approach and the demonstration, each broken into its parts, with links between them. It
  opens on a plain-language summary of the paper; click a concept for its core idea and
  description, or a connection to see the two concepts it joins.
- **Metadata and citations done for you.** Title, authors, affiliations, DOI and tags come from
  the paper itself, and a DOI fetches a BibTeX citation. Everything can be edited.
- **A library you can find things in.** Covers in a grid or a list, favourites and tags in the
  sidebar, and **Authors**: everyone in your library like a contact book, with their papers and
  co-authors. Search titles, authors and DOIs, or start with `#` to search tags.
- **Made for listening.** Episodes remember where you stopped, show in Control Center's Now
  Playing with their cover, and answer the media keys. Read along in the transcript.
- **Works in the background.** Imports run while you listen to something else, with progress at
  the bottom of the window and a notification when an episode is ready or needs you. Stop a
  conversion and **Try again** carries on from where it was.
- **Your setup, your data.** Any OpenAI-compatible LLM writes the episodes: LM Studio,
  llama.cpp, Ollama behind Open WebUI, or a hosted API. With a local one, nothing about your
  papers leaves your Mac. Every prompt it's sent can be edited. Keep the library on your Mac or
  share it between Macs with a small storage server.
- **In your language.** The app speaks English, Italian, Spanish, German and French: it follows
  your Mac's language, or pick one in **Settings → Language**. Episodes are written in English
  unless you turn on **Write the episode in this language** when importing (experimental: the
  Kokoro voices are English, so they read other languages with an English accent).

## Getting started

Ready-made builds are on the [Releases](https://github.com/marcoSanti/papertalk/releases) page.
Unzip `Papertalk-<version>.zip` and move **Papertalk.app** to Applications. The app is only
ad-hoc signed, so the first time macOS may refuse to open it: right-click it and choose **Open**.

To build it yourself you need macOS 26 or later (Apple silicon recommended) and Xcode with
Swift 6.2:

```bash
./app.sh run
```

That builds `client/dist/Papertalk.app` (a debug build) and opens it. `app.sh` lives at the repo
root and runs from anywhere; `./app.sh release` makes an optimized build zipped to
`client/dist/Papertalk-<version>.zip`, with the committed source beside it. Builds you make
yourself show a yellow "DEV" stripe on the icon; only official releases use the plain one.

On first launch a short setup asks:

1. where your library lives: on this Mac, or on a [storage server](#sharing-a-library-between-macs);
2. which LLM writes the episodes: its base URL, an optional API key and the model;
3. where the voices are made: on this Mac, or on a [speech server](#voices-on-a-server).

**Test connection** checks that the storage server and the LLM answer. You can skip the setup
and change all of it later in **Settings** (⌘,). With voices on this Mac, the first episode
takes a little longer because it downloads the voice models (about 120 MB).

**Papertalk → Check for Updates…** (stable releases) and **Check for Dev Builds…** (the latest
builds of `main`) ask GitHub whether there's something newer and offer its release page. Nothing
is ever downloaded or installed by itself.

## Using it

Import a paper with **File → Import PDF…** (⌘O), the **+** button, or by dropping a PDF onto the
library. Choose the depth (and, for a summary, its length), then the voices when Papertalk asks.

Select a paper to see its details on the right: play it, read the transcript, open the PDF or the
mind map, favourite it, tag it, or fix its metadata.

| Key | In the library |
| --- | --- |
| Space or Return | Play or pause the selected paper |
| Arrow keys | Move around the grid |
| Delete | Delete the selected paper (after asking) |
| ⌘O | Import a PDF |
| ⌘, | Settings |

The **Manage** list in a paper's details has the rest:

- **Regenerate audio** re-voices the existing script; **Rerun episode** writes a new one.
- **Create mind map** draws one for papers imported before mind maps existed, and **Redraw mind
  map** draws it again.
- **Delete audio** frees the disk space and keeps the script and PDF. The paper still plays, with
  voices made live; the app says so, since that audio isn't saved and each listen voices it again. When you listen to an episode to the end, Papertalk offers to delete its audio;
  **Keep, and don't ask again** turns that off, and **Settings → Clear Data** turns it back on.
- **Stop conversion** stops an import; the script and any sections already voiced are kept.

To change how the LLM writes, edit any of the prompts in **Settings → Query Prompts**. The reply
formats are added automatically, so an edit can't break an import.

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
  `LLM_API_KEY` or `PAPERTALK_API_KEY`), the same choices as for the LLM. Open WebUI needs one
  (Settings → Account → API keys).
- **Model**: Papertalk asks the server what it offers (`/audio/models` or `/models`) and fills
  the picker. If it lists nothing, type the model name.
- **Requests at a time**: how many sections are voiced at once (1 to 16, default 4). More is
  faster if the server keeps up. Voices on the Mac are always made one section at a time.

The server should run Kokoro: each paper's cast is sent by voice name (`af_heart`,
`am_michael`, …), and Papertalk warns if the server's `/audio/voices` doesn't list them. It asks
for WAV; MP3 and other formats are converted on the Mac. Every synthesis path uses the setting:
importing, **Regenerate audio**, playing a paper that has no audio yet, and the voice samples.

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

The server reads `PAPER2POD_STORAGE_PORT` (default `9170`), `PAPER2POD_STORAGE_HOST` (default
`0.0.0.0`), `PAPER2POD_STORAGE_ROOT` (default `~/.paper2pod/storage`) and
`PAPER2POD_STORAGE_TOKEN` (optional bearer token).

It's a flat key/value store over HTTP: `GET /` lists the keys, and `GET`, `PUT`, `DELETE` and
`HEAD` on `/<key>` read, write, delete and check a file. Keys look like
`papers/<id>/paper.json`, `papers/<id>/source.pdf` or `papers/<id>/turns/<n>.wav`.

</details>

## Settings, keys and data

Everything is configured inside the app. If you'd rather set defaults from the environment, the
app picks up `OPENWEBUI_BASE_URL` or `LLM_BASE_URL`, `PAPERTALK_MODEL`, and an API key from
`OPENWEBUI_API_KEY`, `LLM_API_KEY` or `PAPERTALK_API_KEY`. `PAPERTALK_SERVER_URL` and
`PAPERTALK_API_TOKEN` set a default storage server.

API keys (the LLM's and the speech server's) are kept in the macOS Keychain, never in the
preferences file. Each paper is a folder with its PDF, script, mind map and audio. The voice
models live in `~/.cache/fluidaudio/`. **Settings → Clear Data** can erase the library and reset
everything, or separately delete the voice models to get the disk space back.

## Linux (preview)

A Linux version is in progress, on the same library format, so a library folder can move between
the two. It has the library, the player, importing, the cast and settings; the authors and
transcript views, metadata editing and the mind map aren't there yet. Its builds are paused in
CI for now, so build it yourself with Docker (the build runs in a container):

```bash
client/linux-dev/dev.sh build
client/linux-dev/dev.sh appimage
```

That writes `client/dist/Papertalk-<version>-<arch>.AppImage`. It needs a desktop with GTK 4
(Ubuntu 22.04+, Fedora 36+ and alike) and brings everything else, Python included. Voices are
made on the CPU with the same Kokoro voices as on the Mac.

## Contributing

As the note at the top says, there are rough edges, and help is very welcome. The app is the
Swift package in `client/`, the storage server is in `server/`, and
[AGENTS.md](AGENTS.md) explains how the code is laid out and the rules it follows. If you report
a bug, the **Activity** log in the paper's details is the most useful thing to include.

### Tests

```bash
./app.sh test        # about ten seconds
./app.sh coverage    # the same with code coverage, written to coverage/
```

The suite needs nothing external: no LLM, no network, no Keychain, no voice models, and it never
touches your real library. LLM replies come from an in-process mock, the storage and speech
servers are faked, and a guard fails any test that tries to reach a real server. The SwiftUI views
contain only layout; every rule they show lives in plain Swift types under
`client/Sources/Papertalk/Shared/Presentation/`, so it's tested without running the UI. When you
fix a bug, add a test that fails without the fix.

### Pull requests, versions and releases

Work lands on `main` through pull requests. Each pull request runs the tests with coverage
(`.github/workflows/tests.yml`); the coverage table is on the run's summary page. Changes to
Markdown files alone skip it.

The version follows [semantic versioning](https://semver.org) and lives only in the `VERSION`
file; to release, change it by hand in a pull request. Every merge to `main` (except
Markdown-only ones) runs `.github/workflows/release.yml`, which tests `main` again and then:

- if `VERSION` has no release yet, publishes it as a **stable release** tagged `v<VERSION>`,
  marked Latest, with the official icon;
- otherwise publishes a **development build**, a pre-release tagged `v<VERSION>-dev.<commit>`
  with the "DEV" icon. Only the ten newest are kept.

Each release has `Papertalk-<version>.zip`, the source it was built from
(`Papertalk-<version>-source.tar.gz`) and a SHA-256 checksum for each.
