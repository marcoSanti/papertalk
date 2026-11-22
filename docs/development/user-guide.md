# User guide

Part of the [development guide](../../AGENTS.md): the Help Book.

- `shared/Papertalk.help/` is a macOS Help Book: plain HTML pages in `Contents/Resources/en.lproj/`
  with `help.css`, opened from the Help menu (the app's `Info.plist` names it with
  `CFBundleHelpBookFolder` / `CFBundleHelpBookName`). `app.sh` copies it into the bundle and indexes it
  with `hiutil` for the Help menu's search, and makes the home page's `icon.png` from the official
  icon; both are build output, never committed.
- **Every PR that adds or changes a user-visible feature updates the guide in the same PR**: the
  page for that area (new menu items, buttons, shortcuts, settings, behaviour), or a new page linked
  from `index.html`. Removing a feature removes it from the guide. Keep it in step with `README.md`.
- Same copy rules as the interface: plain, specific, named exactly as the UI names things.
  `HelpBookTests` fails on a page not linked from `index.html` or a broken link. The guide is
  English only for now.
- macOS copies the guide into its own cache the first time it's opened, keyed by the **app's**
  version (`…/group.com.apple.helpviewer.content/Library/Caches/dev.papertalk.desktop.*<VERSION>.help`),
  and shows that copy until the version changes. Releases always change it. To see guide edits in a
  local build, build with a plain numeric version macOS hasn't seen yet (`VERSION=0.4.99 app.sh app`,
  then 0.4.100 for the next edit: a suffix like `0.4.2-x` is read as 0.4.2) and reopen. Deleting the cache instead needs Full Disk Access, and
  deleting only part of it leaves Tips showing "content unavailable". To check a page without the
  cache, render the built bundle's `en.lproj/index.html` with `qlmanage -t`. Dev pre-releases
  (`<VERSION>-dev.<commit>`) count as `<VERSION>`, so their users see the guide of the first dev
  build they opened until the next stable release.
