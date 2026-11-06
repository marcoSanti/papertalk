// Linux stand-in for the macOS update installer: installing in place isn't supported yet
// (the AppImage would need its own swap), so the alert falls back to the release page.

#if os(Linux)
import Foundation

/// Same shape as the macOS installer; always fails with `.unsupported`.
struct UpdateInstaller {
    func install(_ c: UpdateCheck.Candidate, over app: URL) async throws(UpdateInstall.Failure) {
        throw .unsupported
    }
    /// Never reached: `install` always fails.
    func quit() {}
}
#endif
