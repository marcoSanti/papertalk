"""Linux platform services for Papertalk, called from Swift through PythonKit.

Each module stands in for a macOS framework (see docs/LINUX_PORT.md):
pdf (PDFKit), tts (FluidAudio Kokoro), audio (AVAudioPlayer) and
keychain (Security). Functions take and return plain values only
(str, bytes, numbers), so nothing Python-side is held across calls.
"""
