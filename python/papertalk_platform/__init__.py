"""Linux platform services for Papertalk, called from Swift through PythonKit.

Each module stands in for a macOS framework (see AGENTS.md, "Linux port"):
pdf (PDFKit), tts (FluidAudio Kokoro) and keychain (Security).
Playback stays in Swift (Platform/Linux/AVFoundationCompat.swift). Functions take and return plain values only
(str, bytes, numbers), so nothing Python-side is held across calls.
"""
