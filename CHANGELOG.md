# Changelog

What each release changes, as the app's "What's new" screen shows it. Every pull request with a
user-visible change adds one line under `## Unreleased`, in this form:

`- <emoji> **Title**: one short sentence on what changed for the user.`

When `VERSION` is bumped to `X.Y.0`, rename `## Unreleased` to `## X.Y.0` and start a new, empty
`## Unreleased` above it. `app.sh` embeds only the build's own section (or `Unreleased` when the
version has none) into the app.

## Unreleased

- 📬 **Suggested Papers**: a new sidebar section lists papers like yours from Semantic Scholar, ranked by your LLM; read each abstract in the details panel and import the ones you want.
- ✉️ **Google Scholar alerts**: Suggested Papers can also read your Google Scholar alert emails (Settings → Suggested Papers), as far back as you choose.
- 📽️ **Slide decks**: import a presentation as a PDF into its own Slides library; slides that are mostly pictures are described by your LLM.
- 🔗 **Link a deck to its paper**: a deck's Paper card links it to the paper it presents, and the paper lists its decks.
- 🐛 **Voicing crashes**: making audio for several papers in a row, or playing one while another is voiced, no longer runs the Mac out of memory.
- 🔎 **Ask cites the paper**: answers link each fact to its page, and the paper beside the chat jumps there with the quote highlighted.
- 📚 **Cited papers**: Details lists the papers a paper cites; open, copy or jump to each one in your library.
- 🎉 **What's new**: after an update, Papertalk opens once with a short list of what changed.
