import Foundation
import PythonKit

let args = CommandLine.arguments
let py = PythonRuntime.shared

func bytes(_ data: Data) -> PythonObject {
    Python.bytes(data.map { Int($0) })
}
func data(_ obj: PythonObject) -> Data {
    Data(Array<UInt8>(Python.list(Python.bytearray(obj)))!)
}

let pdfData = try Data(contentsOf: URL(fileURLWithPath: args[1]))

// Many concurrent callers: all funnel onto the one Python thread.
let text = try await py.run { String(Python.import("papertalk_platform.pdf").text(bytes(pdfData)))! }
print("text:", text.prefix(60).replacingOccurrences(of: "\n", with: " "))

let png = try await py.run { data(Python.import("papertalk_platform.pdf").cover_png(bytes(pdfData), 280)) }
print("cover png bytes:", png.count, png.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "(PNG)" : "(not PNG)")

let start = Date()
let wavs = try await withThrowingTaskGroup(of: Data.self) { group in
    for voice in ["af_heart", "am_michael", "bf_emma"] {
        group.addTask {
            try await py.run {
                data(Python.import("papertalk_platform.tts").synthesize("Hello from \(voice) on Linux.", voice, 1.0))
            }
        }
    }
    return try await group.reduce(into: [Data]()) { $0.append($1) }
}
print("wav sizes:", wavs.map(\.count), String(format: "in %.1fs", Date().timeIntervalSince(start)))

let player = try await py.run { Python.import("papertalk_platform.audio").Player(bytes(wavs[0])) }
let info = try await py.run { () -> String in
    player.seek(0.5)
    return "duration \(player.duration) current \(player.current_time) device \(player.play())"
}
print("player:", info)
