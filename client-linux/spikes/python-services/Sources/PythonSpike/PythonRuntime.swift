import Foundation
import PythonKit

/// Owns the embedded interpreter. Every Python call runs on one dedicated
/// thread, so the GIL and CPython's thread state never see two Swift threads.
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

    private func loop() {
        // Make the venv's packages and python/ importable, once, on this thread.
        let sys = Python.import("sys")
        let site = Python.import("site")
        if let venv = ProcessInfo.processInfo.environment["PAPERTALK_VENV"] {
            let ver = "python\(sys.version_info.major).\(sys.version_info.minor)"
            site.addsitedir("\(venv)/lib/\(ver)/site-packages")
        }
        if let path = ProcessInfo.processInfo.environment["PAPERTALK_PYTHON_PATH"] {
            sys.path.insert(0, path)
        }
        while true {
            lock.lock()
            while jobs.isEmpty { lock.wait() }
            let job = jobs.removeFirst()
            lock.unlock()
            job()
        }
    }

    /// Run `work` on the Python thread and return its result.
    func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            jobs.append { cont.resume(with: Result { try work() }) }
            lock.signal()
            lock.unlock()
        }
    }
}
