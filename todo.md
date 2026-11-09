# TODOS

## Linux

- **The Linux app is extremely laggy overall** (reported 2026-11-09 on the user's laptop: Ryzen 9
  8940HX + RTX 5070 Laptop, NVIDIA + AMD hybrid graphics, GNOME, Wayland). Every click and redraw
  feels slow. Done so far: `StoreBridge` coalesces bursts of store/player changes into one
  re-render, and `GtkStyles` restores hover/press feedback. Not yet measured on the real desktop
  (headless Xvfb runs show no CPU load). Next steps:
  - Measure on the desktop: launch with `GSK_RENDERER=gl` (and `cairo`) to rule out GTK 4's
    renderer on hybrid graphics; time a re-render (SwiftCrossUI redraws the whole window on every
    `revision` bump).
  - Narrow re-renders: split `StoreBridge.revision` per pane, or observe only what a view reads,
    so a player tick doesn't rebuild the library list and covers.
  - Profile with `perf` / `sysprof` while scrolling the library and playing an episode.
- **GPU voices (decision pending):** Kokoro runs on the CPU (~7× real time). sherpa-onnx has a
  CUDA 13 build (onnxruntime 1.28.2) that could use an NVIDIA GPU: ~280 MB provider plus the
  system's CUDA runtime and cuDNN 9 (~2 GB). Idea: an optional download, used only when an NVIDIA
  GPU and CUDA are found.
- **Split macOS and Linux code (decision pending):** proposal is three targets (shared core,
  macOS app, Linux app), platform services behind small protocols each app supplies instead of
  Linux imitating Apple class names, and both CIs required on every PR. Needs macOS CI to verify,
  since the macOS sources move.
