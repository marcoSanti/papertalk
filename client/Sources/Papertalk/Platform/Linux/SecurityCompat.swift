#if os(Linux)
import Foundation
import PythonKit

/// The LLM API key store on Linux: the desktop keyring (Secret Service, i.e.
/// GNOME Keyring or KWallet) through python/papertalk_platform/keychain.py,
/// under the same service name as the macOS Keychain entry.
enum KeychainStore {
    static func set(_ value: String, account: String) {
        _ = try? PythonRuntime.shared.runSync { PythonRuntime.shared.module("keychain").write(account, value) }
    }

    static func get(_ account: String) -> String? {
        let value = try? PythonRuntime.shared.runSync {
            String(PythonRuntime.shared.module("keychain").read(account)) ?? ""
        }
        return value?.isEmpty == false ? value : nil
    }

    static func delete(_ account: String) {
        _ = try? PythonRuntime.shared.runSync { PythonRuntime.shared.module("keychain").delete(account) }
    }
}
#endif
