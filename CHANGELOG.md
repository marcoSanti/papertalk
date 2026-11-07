# Changelog

What each release changes, as the app's "What's new" screen shows it. Every pull request with a
user-visible change adds one line under `## Unreleased`, in this form:

`- <emoji> **Title**: one short sentence on what changed for the user.`

When `VERSION` is bumped to `X.Y.0`, rename `## Unreleased` to `## X.Y.0` and start a new, empty
`## Unreleased` above it. `app.sh` embeds only the build's own section (or `Unreleased` when the
version has none) into the app.

## Unreleased

- 🎉 **What's new**: after an update, Papertalk opens once with a short list of what changed.
