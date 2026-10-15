"""WAV playback with pause and seek (AVAudioPlayer on macOS).

One Player per sound, mirroring how PlayerController holds one
AVAudioPlayer per turn. The whole sound is decoded into memory; the
output callback just copies frames from the current position, so pause,
seek and the clock are plain arithmetic on that position.
"""
import io
import threading

import numpy as np
import soundfile as sf


class Player:
    def __init__(self, wav: bytes):
        data, self.rate = sf.read(io.BytesIO(bytes(wav)), dtype="float32", always_2d=True)
        self._frames = data
        self._pos = 0
        self._lock = threading.Lock()
        self._stream = None
        self.finished = False

    @property
    def duration(self) -> float:
        return len(self._frames) / self.rate

    @property
    def current_time(self) -> float:
        with self._lock:
            return self._pos / self.rate

    def seek(self, seconds: float) -> None:
        with self._lock:
            self._pos = int(max(0.0, min(seconds, self.duration)) * self.rate)
            self.finished = self._pos >= len(self._frames)

    def is_playing(self) -> bool:
        return self._stream is not None and self._stream.active

    def play(self) -> bool:
        """Start or resume. False when there's no audio device."""
        if self.is_playing():
            return True
        import sounddevice as sd

        try:
            self._stream = sd.OutputStream(samplerate=self.rate, channels=self._frames.shape[1],
                                           dtype="float32", callback=self._fill,
                                           finished_callback=self._done)
            self._stream.start()
            return True
        except Exception:
            self._stream = None
            return False

    def pause(self) -> None:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

    stop = pause

    def read(self, frames: int) -> np.ndarray:
        """Next `frames` frames from the position (zero-padded at the end); advances it."""
        with self._lock:
            chunk = self._frames[self._pos:self._pos + frames]
            self._pos += len(chunk)
            if self._pos >= len(self._frames):
                self.finished = True
        if len(chunk) < frames:
            chunk = np.concatenate([chunk, np.zeros((frames - len(chunk), self._frames.shape[1]), np.float32)])
        return chunk

    def _fill(self, outdata, frames, _time, _status):
        import sounddevice as sd

        outdata[:] = self.read(frames)
        if self.finished:
            raise sd.CallbackStop

    def _done(self):
        self._stream = None
