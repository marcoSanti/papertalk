# Papertalk

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![Voices: Kokoro](https://img.shields.io/badge/voices-Kokoro%20(on--device)-D07040)

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
voice. You can play a short sample of any voice before you decide.

Then the LLM plans the episode and writes the dialogue section by section, following the depth
you picked. *In-depth* walks through the method faithfully, *Summary* stays high-level, *Custom*
follows your own instructions (which you can save as presets), and *Direct read* skips the LLM
entirely and reads the paper out as-is.

Finally every line is voiced with [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M), running
on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio). The
audio is saved with the paper, so playback afterwards is instant.

Any OpenAI-compatible chat endpoint works for the writing part: LM Studio, llama.cpp, Ollama
behind OpenWebUI, or a hosted API. If that endpoint runs locally, nothing about your papers ever
leaves your Mac.

## Getting started

You need macOS 26 or later (Apple silicon recommended) and Xcode with Swift 6.2. Build and open
the app with:

```bash
cd client
make run
```

This puts a debug build in `client/dist/Papertalk.app`. Use `make release` for an optimized
build zipped to `dist/Papertalk.app.zip`. The app is only ad-hoc signed, so if macOS refuses to
open a copy you've moved to another Mac, right-click it and choose **Open**.

On first launch a short setup asks where your library should live (on this Mac, or on a
[storage server](#sharing-a-library-between-macs)) and which LLM should write the episodes:
its base URL, an optional API key and the model. **Test connection** checks that both work.
You can skip the setup and change all of this later in **Settings** (⌘,).

The first episode takes a little longer, because it downloads the voice models (about 120 MB).

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

The sidebar groups the library by favourites and tags, and **Authors** shows everyone in your
library like a contact book: open an author to see their papers and jump to their co-authors.
Search matches titles, authors and DOIs; start with `#` to search tags.

If an episode doesn't sound right, **Regenerate audio** re-voices the existing script, and
**Rerun episode** writes a new one from scratch. To change how the LLM writes, edit the prompts
in **Settings → Query Prompts**.

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

## Settings, keys and data

Everything is configured inside the app. If you'd rather set defaults from the environment, the
app picks up `OPENWEBUI_BASE_URL` or `LLM_BASE_URL`, `PAPERTALK_MODEL`, and an API key from
`OPENWEBUI_API_KEY`, `LLM_API_KEY` or `PAPERTALK_API_KEY`. `PAPERTALK_SERVER_URL` and
`PAPERTALK_API_TOKEN` set a default storage server.

API keys are kept in the macOS Keychain, never in the preferences file. The voice models live in
`~/.cache/fluidaudio/`. **Settings → Clear Data** can erase the library and reset everything, or
separately delete the voice models if you want the disk space back.

## Contributing

As the note at the top says, there are rough edges, and help is very welcome. The app lives in
`client/` (a Swift package), the storage server in `server/`. `client/UI_ISSUES.md` lists known
UI problems and what's already been fixed. If you report a bug, the **Activity** log in the
paper's details panel is the most useful thing to include.
