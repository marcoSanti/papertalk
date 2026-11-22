// Installs a stable release over the running app on macOS: download the zip and its checksum,
// verify, unpack beside the app, then quit and let a small script swap the bundles and reopen.

#if os(macOS)
import AppKit
import CryptoKit

/// Downloads, checks and stages a release, then hands the swap to `UpdateInstall.swapScript`.
/// Nothing in the installed app changes until every check has passed and the app has quit.
struct UpdateInstaller {
    /// Stage `c` beside `app` and start the swap script, which waits for this process to exit.
    /// The caller quits the app afterwards.
    func install(_ c: UpdateCheck.Candidate, over app: URL) async throws(UpdateInstall.Failure) {
        guard let files = UpdateInstall.files(for: c) else { throw .download }
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw .notWritable(folder.path) }

        guard let (sumData, _) = try? await URLSession.shared.data(from: files.checksum),
              let expected = UpdateInstall.checksum(in: String(decoding: sumData, as: UTF8.self)),
              let (zip, _) = try? await URLSession.shared.download(from: files.zip) else { throw .download }
        defer { try? FileManager.default.removeItem(at: zip) }
        guard (try? sha256(of: zip)) == expected else { throw .checksum }

        // Unpack on the app's own volume, so the swap is a rename.
        guard let staging = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                         appropriateFor: app, create: true) else { throw .notWritable(folder.path) }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path]) == 0 else { throw .unzip }
        let fresh = staging.appendingPathComponent("Papertalk.app")
        let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard UpdateInstall.isExpectedApp(info: info, bundleId: Bundle.main.bundleIdentifier, version: c.version) else {
            try? FileManager.default.removeItem(at: staging)
            throw .notPapertalk
        }

        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", UpdateInstall.swapScript, "sh",
                          String(ProcessInfo.processInfo.processIdentifier), app.path, staging.path, "1"]
        do { try swap.run() } catch { try? FileManager.default.removeItem(at: staging); throw .unzip }
    }

    /// Quit, so the swap script can replace the app and reopen it.
    func quit() { NSApp.terminate(nil) }

    /// The file's SHA-256 as lowercase hex, read in pieces (the zip is tens of MB).
    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Run a tool to completion; its exit status.
    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
#endif
