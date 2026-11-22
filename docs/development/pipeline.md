# Pipeline

Part of the [development guide](../../AGENTS.md): imports, the LLM, speech, Kokoro and mind maps.

- **Audio is baked at import** and saved per turn; playback uses the baked audio. Live synthesis
  in `PlayerController.prepare(transcript:)` is only a fallback for papers without complete
  audio, and it plays progressively. Don't move the normal path to live synthesis.
- Memory on 8 GB Macs: papers are voiced one at a time (`AppStore.audioGate`), and every turn
  goes to Kokoro in pieces of at most 200 characters (`KokoroSpeech.pieces`, joined with
  `joinWAVs`). One call holds all its samples and Core ML buffers until it returns, so a long
  monologue in one call peaked at ~1.2 GB and got the app killed; pieces keep it near 0.45 GB.
- `bakeAudio` reuses turns already on disk, so re-running it resumes. On failure it returns a
  message and the paper goes to an error state via `failAudio`, never to "done" without audio.
- **Synthesis goes through `SpeechBackend`** (`Shared/Controllers/SpeechBackend.swift`), picked
  only by `SpeechSettings.makeBackend()` via `AppStore.speechBackend` (the player gets the same
  one). `LocalSpeechBackend` wraps `KokoroEngine.shared`; `RemoteSpeechBackend` calls an
  OpenAI-compatible `/audio/speech` and never touches Core ML. Whatever a backend returns goes
  through `SpeechAudio.normalizedWAV`, so stored turns are always 24 kHz mono 16-bit WAV with a
  44-byte header (`wavDuration` and `joinWAVs` assume it). `bakeAudio` voices up to
  `backend.parallelRequests` turns at once (always 1 for local Kokoro; the user's setting on a
  server) and writes each turn as it finishes, so resuming still works. Remote voices are the
  cast's Kokoro ids, sent as they are. Tests pass a fake backend to `AppStore(storage:speech:)`.
- **Known upstream bug, re-check on every FluidAudio update** (seen on 0.17.7, Oct 2026): after
  ~100 calls, one `KokoroEngine` call can run away inside Core ML's CPU path
  (`E5RT::Ops::BnnsCpuInferenceOperation` → `BNNSGraphContextExecute`) and grow to ~50 GB in
  ~90 s, until macOS kills the app (launchd reason `(1, 13, 9)`: jetsam, low swap). It isn't
  our buffers: footprint stays at ~380 MB for 96 turns, and the text alone voices fine.
  Repro: voice the 172 turns of a long summary (VerifyIO's did it at turn 97 every run) through
  `KokoroEngine.shared` piece by piece in a throwaway test, logging `phys_footprint` per turn to
  a file (stdout is lost when the process is killed), and `sample` the process once it
  passes a few GB. Upstream: FluidAudio #817, #844. It's tied to the loaded model, not the input:
  in Nov 2026 a probe of 200 short pieces (8–36 words, two voices) died on the 81st call every
  run (11 GB after 8 s), and the same call on a freshly loaded model voiced fine. So
  `KokoroEngine` reloads the model every `callsPerModel` (25) calls, about 1 s each; with that,
  200 calls ran with footprint flat at 250–440 MB. Never let one model serve more calls. If it
  still happens, the next fix is running Kokoro in a helper process so a runaway kills only the
  helper. When it's gone upstream, remove the reload, this note and the README's "Known issues" entry.
- **Use `KokoroEngine.shared` for all local synthesis.** Never create another `KokoroAneManager`: two
  model copies on the Neural Engine, or overlapping calls into one (actors are re-entrant across
  `await`), fail with "unable to compute the asynchronous prediction".
- `LLMReply.json` takes text from the first `{` to the last `}`. **Ask the LLM for a
  JSON object, never a top-level array**: an array gets mangled and the parse silently falls
  back to defaults (this broke the cast step for a long time).
- Replies and files are untrusted: check any number from them before indexing or converting to
  `Int`, and never force-unwrap a URL made from typed text (`URL.web`). `MindMap`'s decoder
  refuses maps that can't be laid out.
- Depth: only `.inDepth` may have full-length method monologues; `generateTranscript` forces
  every other depth to dialogue. Summary's ceiling is the import sheet's length
  (`SummaryLength`, 5–60 min, default 35, saved as `Paper.targetMinutes` for reruns); it aims
  for 6/7 of it, and the ceiling is enforced segment by segment on what was *written*: each
  segment is told its limit (`lengthLimit`), and one that runs >15% over is condensed by the LLM
  once, then cut (`LocalPipeline.trimTurns`). Models overshoot short targets 2×, so never trust
  the request alone. In-depth has no cap and scales with the paper. Lengths
  assume about 145 spoken words per minute at the default pace.
- Cast: the interviewer keeps the signature voice for their gender (Heart / Michael); the guest
  gets `KokoroSpeech.guestVoice` (same gender, different voice, stable per name). Gender comes
  from the LLM (per speaker and per author); `KokoroSpeech.guessGender(fromName:)` is only a
  fallback. The sheet shows the gender so the user can correct it. Never let an unknown gender
  quietly become a female voice.
- The cast prompt can answer **Skip audio** (`resolveCast(_:voiceAudio: false)`): the script
  is written and the paper finishes "done" with `hasAudio == false`; Regenerate audio voices it.
- Mind map (`MindMap`, `LocalPipeline.mindMap`): drawn after the script, before voicing, and
  best-effort (a failure logs and toasts, never fails the import; Create mind map retries).
  `MindMap.parse` repairs the reply (short labels, orphans under their branch root, cycles,
  stray links) and returns nil unless all three pillars exist; the pipeline asks once more when a
  pillar has fewer than two parts. Layout is `MindMapLayout` (pure, tested); `Paper.hasMindMap`
  is optional so older records decode.
- Connections between maps (`MindMapConnections`, `AppStore.connectMindMap`): after a map is
  drawn, a local TF-IDF pass shortlists concept pairs with other maps (bounded: `maxPairs`,
  `maxPapers`), and only that shortlist goes to the LLM, so the prompt doesn't grow with the
  library. Never send whole maps. Results go on `MindMap.external` (optional). Connections are
  two-way: save maps only through `AppStore.saveMindMap`, which writes the other side of every
  connection involved (from a fresh read) and bumps `mindMapRevision` so open windows reload.
  Writing `K.mindMap` directly leaves a connection one-sided. `mindMap(for:)` hides links to
  papers no longer in the library. A link whose other side couldn't be read is kept, not dropped:
  it goes only when the paper or concept is surely gone.
- The duplicate and cast prompts pause the pipeline on a `CheckedContinuation`. Prompts queue,
  one at a time. Only *new* imports (`existing == nil`) may be discarded by the duplicate
  prompt, because declining deletes the paper.
