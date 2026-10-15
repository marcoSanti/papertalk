#if os(Linux)
import Foundation
import PythonKit

/// The embedded Python interpreter behind the Linux compat shims (AGENTS.md, "Linux port").
///
/// Every Python call runs on one dedicated thread: CPython's thread state and the
/// GIL then never see two Swift threads, and calls into one module (Kokoro) are
/// naturally serialised. Shims exchange only plain values with Python (str,
/// bytes, numbers), never Python objects held across calls, except `Handle`s.
final class PythonRuntime: @unchecked Sendable {
    static let shared = PythonRuntime()

    private let lock = NSCondition()
    private var jobs: [() -> Void] = []

    private init() {
        let worker = Thread { [unowned self] in self.loop() }
        worker.name = "papertalk.python"
        worker.stackSize = 8 << 20
        worker.start()
    }

    /// Run `work` on the Python thread and return its result.
    func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            enqueue { cont.resume(with: Result { try work() }) }
        }
    }

    /// Blocking variant for synchronous call sites (PDF text, keychain). Never
    /// call it from the Python thread itself.
    func runSync<T>(_ work: @escaping () throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        enqueue { result = Result { try work() }; done.signal() }
        done.wait()
        return try result.get()
    }

    /// A module of python/papertalk_platform, e.g. `module("pdf")`. Python thread only.
    func module(_ name: String) -> PythonObject {
        Python.import("papertalk_platform.\(name)")
    }

    private func enqueue(_ job: @escaping () -> Void) {
        lock.lock()
        jobs.append(job)
        lock.signal()
        lock.unlock()
    }

    private func loop() {
        Self.configure()
        while true {
            lock.lock()
            while jobs.isEmpty { lock.wait() }
            let job = jobs.removeFirst()
            lock.unlock()
            job()
        }
    }

    // MARK: - Locating Python

    private static let env = ProcessInfo.processInfo.environment

    /// The venv holding the Python packages: PAPERTALK_VENV, else ~/.local/share/papertalk/venv.
    static var venv: URL {
        if let path = env["PAPERTALK_VENV"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/papertalk/venv", isDirectory: true)
    }

    /// The folder containing `papertalk_platform`: PAPERTALK_PYTHON_PATH, else `python/`
    /// next to the executable or up to four levels above it (a checkout's build folder).
    static var platformPackageDir: URL? {
        if let path = env["PAPERTALK_PYTHON_PATH"] { return URL(fileURLWithPath: path) }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("python", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("papertalk_platform").path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// libpython for PythonKit: PYTHON_LIBRARY, else the newest libpython3.x in the system lib folders.
    static var libraryPath: String? {
        if let path = env["PYTHON_LIBRARY"] { return path }
        let fm = FileManager.default
        let dirs = ["/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu", "/usr/lib64", "/usr/lib"]
        let found = dirs.flatMap { dir in
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasPrefix("libpython3.") && $0.contains(".so") }
                .map { "\(dir)/\($0)" }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.last
    }

    private static func configure() {
        if let lib = libraryPath { PythonLibrary.useLibrary(at: lib) }
        let sys = Python.import("sys")
        let site = Python.import("site")
        let version = "python\(sys.version_info.major).\(sys.version_info.minor)"
        site.addsitedir(venv.appendingPathComponent("lib/\(version)/site-packages").path)
        if let dir = platformPackageDir { sys.path.insert(0, dir.path) }
    }
}

// MARK: - Value conversion

extension Data {
    /// Python `bytes` with this data's contents (one buffer copy).
    var python: PythonObject { PythonBytes(self).pythonObject }

    /// The contents of a Python bytes-like object (bytes, bytearray, memoryview).
    init(python object: PythonObject) {
        let bytes = PythonBytes(Python.bytes(object)) ?? PythonBytes([UInt8]())
        self = bytes.withUnsafeBytes { Data($0) }
    }
}
#endif
