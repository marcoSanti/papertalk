# Changelog

What each release changes, as the app's "What's new" screen shows it. Every pull request with a
user-visible change adds one line under `## Unreleased`, in this form:

`- <emoji> **Title**: one short sentence on what changed for the user.`

When `VERSION` is bumped to `X.Y.0`, rename `## Unreleased` to `## X.Y.0` and start a new, empty
`## Unreleased` above it. `app.sh` embeds only the build's own section (or `Unreleased` when the
version has none) into the app.

## Unreleased

- 🔎 **Ask cites the paper**: answers link each fact to its page, and the paper beside the chat jumps there with the quote highlighted.
- 📚 **Cited papers**: Details lists the papers a paper cites; open, copy or jump to each one in your library.
- 🎉 **What's new**: after an update, Papertalk opens once with a short list of what changed.
