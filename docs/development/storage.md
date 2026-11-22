# Data and storage

Part of the [development guide](../../AGENTS.md): what is saved, where, and how not to lose it.

- Local library: `~/Library/Application Support/papertalk/papers/<id>.papertalk/` (or the folder
  picked in Settings, `LocalStorage.folderDefaultsKey`), containing
  `paper.json`, `source.pdf`, `transcript.json`, `mindmap.json`, `slides.json` (decks only), `audio.json` (manifest) and
  `turns/<n>.wav`.
  Kokoro models: `~/.cache/fluidaudio/Models/kokoro*`.
- Keys stay `papers/<id>/…` on every backend; only `LocalStorage.path(_:)` adds the `.papertalk`
  extension (a package declared in Info.plist, so Finder shows one item), and its `list()` renames
  older plain folders. Exports are the same layout (`PaperBundle`); imports read only its known
  files, validate them, and never use the file's id unless it's a free UUID.
- **A failed read is not an empty one.** `storage.exists` is nil for both, so never save back
  something read with it as a whole. `libraries.json` and `suggestions.json` are read with
  `loadIfPresent` (nil only when surely absent) and saved only once loaded; a switch of server or
  folder, and Erase, go through `forgetIndexes()`. The server answers 404 only for what isn't there.
- The library folder moves only through `LocalStorage.moveLibrary` (`Shared/Models/LibraryMove.swift`):
  papers and both index files. A new root-level key must be added there and to `clearAll`.
  A new setting or Keychain account must be added to `clearAll` too (Erase).
- Everything for a paper lives under `K.folder(id)`. Delete a paper with
  `storage.deleteFolder(K.folder(id))`, never with a hand-written list of keys (that left
  orphaned folders before).
- **`Paper` is decoded from disk with synthesized `Codable`.** A new non-optional property added
  to `CodingKeys` makes every existing `paper.json` fail to decode, and those papers silently
  vanish from the library. Add new fields as optionals (see `storedSpeakers` and its computed
  `speakers` wrapper), or write a tolerant `init(from:)`. A property left *out* of `CodingKeys`
  is silently never saved.
- API keys and the mail password live in the Keychain only (`KeychainStore`). `LLMSettings.save()` and
  `SpeechSettings.save()` strip the key before writing user defaults; keep it that way.
