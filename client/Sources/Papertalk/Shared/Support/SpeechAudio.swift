// Normalizing speech audio: whatever a backend returns (WAV of any layout, or compressed
// audio) becomes the 24 kHz mono 16-bit WAV every stored turn uses.

import Foundation

/// Turns whatever a speech backend returns into the one WAV layout the app
/// stores and plays: 24 kHz mono 16-bit PCM with a plain 44-byte header
/// (`KokoroSpeech.wavDuration` and `joinWAVs` rely on it). Kokoro on this
/// machine already produces it; a remote server may send another rate, stereo,
/// float samples, extra header chunks, or a compressed format.
enum SpeechAudio {
    /// Hz of every stored and played WAV (Kokoro's native rate).
    static let sampleRate = 24_000

    /// Why a server's audio couldn't be used; shown in the paper's error.
    enum Failure: Error, LocalizedError, Equatable {
        case empty, unreadable, compressedUnsupported
        var errorDescription: String? {
            switch self {
            case .empty: return L("The speech server sent no audio.")
            case .unreadable: return L("The speech server sent audio Papertalk can't read. Set it to return WAV.")
            case .compressedUnsupported: return L("The speech server sent compressed audio, which Papertalk can't read here. Set it to return WAV.")
            }
        }
    }

    /// `data` as 24 kHz mono 16-bit WAV.
    static func normalizedWAV(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw Failure.empty }
        if data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data.subdata(in: data.startIndex + 8..<data.startIndex + 12) == Data("WAVE".utf8) {
            let wav = try parseWAV(data)
            if wav.isCanonical { return data }
            return wavFile(pcm16: resample(wav.mono, from: wav.rate))
        }
        let decoded = try CompressedAudio.decode(data)
        return wavFile(pcm16: resample(decoded.samples, from: decoded.sampleRate))
    }

    /// A 44-byte-header WAV around 24 kHz mono 16-bit PCM bytes.
    static func wavFile(pcm16 pcm: Data) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let rate = UInt32(sampleRate)
        var wav = Data("RIFF".utf8) + le32(UInt32(36 + pcm.count)) + Data("WAVEfmt ".utf8)
        wav += le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
        return wav
    }

    // MARK: - WAV parsing

    /// A WAV's format and raw sample bytes, as read by `parseWAV`.
    struct ParsedWAV {
        var format: UInt16          // 1 = integer PCM, 3 = float
        /// Interleaved channels in `samples`.
        var channels: Int
        /// Samples per second.
        var rate: Double
        /// Bits per sample: 8, 16, 24, 32 or 64.
        var bits: Int
        var dataOffset: Int         // from the start of the file
        /// The `data` chunk's bytes.
        var samples: Data

        /// Already the app's layout, so it can be stored untouched.
        var isCanonical: Bool { format == 1 && channels == 1 && Int(rate) == SpeechAudio.sampleRate && bits == 16 && dataOffset == 44 }

        /// Every frame averaged to one channel, in -1…1.
        var mono: [Float] {
            let bytesPerSample = bits / 8
            let frameBytes = bytesPerSample * channels
            guard frameBytes > 0 else { return [] }
            let frames = samples.count / frameBytes
            var out = [Float](repeating: 0, count: frames)
            samples.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels {
                        sum += sample(raw, at: f * frameBytes + c * bytesPerSample)
                    }
                    out[f] = sum / Float(channels)
                }
            }
            return out
        }

        /// One sample at byte offset `i`, as -1…1, whatever the format.
        private func sample(_ raw: UnsafeRawBufferPointer, at i: Int) -> Float {
            switch (format, bits) {
            case (3, 32): return Float(bitPattern: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian)
            case (3, 64): return Float(Double(bitPattern: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian))
            case (_, 8): return (Float(raw[i]) - 128) / 128
            case (_, 16): return Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32768
            case (_, 24):
                let v = Int32(raw[i]) | Int32(raw[i + 1]) << 8 | Int32(Int8(bitPattern: raw[i + 2])) << 16
                return Float(v) / 8_388_608
            case (_, 32): return Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int32.self))) / 2_147_483_648
            default: return 0
            }
        }
    }

    /// Reads the `fmt ` and `data` chunks, skipping any others. A streamed WAV
    /// may leave the data size at 0 or 0xFFFFFFFF; then the rest of the file is the data.
    static func parseWAV(_ data: Data) throws -> ParsedWAV {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
        var format: UInt16?, channels = 0, rate = 0.0, bits = 0
        var i = 12
        while i + 8 <= bytes.count {
            let id = String(decoding: bytes[i..<i + 4], as: UTF8.self)
            let size = Int(u32(i + 4))
            let body = i + 8
            if id == "fmt ", body + 16 <= bytes.count {
                format = u16(body)
                channels = Int(u16(body + 2))
                rate = Double(u32(body + 4))
                bits = Int(u16(body + 14))
                // WAVE_FORMAT_EXTENSIBLE: the real format is the sub-format GUID's first two bytes.
                if format == 0xFFFE, body + 26 <= bytes.count { format = u16(body + 24) }
            } else if id == "data" {
                guard let format, channels > 0, rate > 0, [8, 16, 24, 32, 64].contains(bits),
                      format == 1 || format == 3 else { throw Failure.unreadable }
                let end = (size == 0 || size == 0xFFFF_FFFF || body + size > bytes.count) ? bytes.count : body + size
                return ParsedWAV(format: format, channels: channels, rate: rate, bits: bits, dataOffset: body,
                                 samples: Data(bytes[body..<end]))
            }
            i = body + size + (size & 1)   // chunks are padded to an even size
        }
        throw Failure.unreadable
    }

    /// Linear resampling to 24 kHz, then 16-bit PCM bytes. Speech needs nothing finer.
    static func resample(_ samples: [Float], from rate: Double) -> Data {
        let target = Double(sampleRate)
        let out: [Float]
        if samples.isEmpty || abs(rate - target) < 0.5 {
            out = samples
        } else {
            let count = Int((Double(samples.count) * target / rate).rounded())
            let step = rate / target
            out = (0..<count).map { n in
                let pos = Double(n) * step
                let k = Int(pos)
                guard k + 1 < samples.count else { return samples[min(k, samples.count - 1)] }
                let t = Float(pos - Double(k))
                return samples[k] * (1 - t) + samples[k + 1] * t
            }
        }
        var pcm = Data(capacity: out.count * 2)
        for s in out {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }
}
