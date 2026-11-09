// Linux stand-in for the macOS Keychain store: API keys in the desktop keyring (libsecret).

#if os(Linux)
import CSecret
import Foundation

/// The LLM API key store on Linux: the desktop keyring (Secret Service, i.e. GNOME Keyring
/// or KWallet) through libsecret, under the same service name as the macOS Keychain entry.
/// Without a keyring (a bare session, a container) reads find nothing and writes are
/// dropped, as when the Keychain refuses on macOS.
enum KeychainStore {
    /// The Keychain's service name on macOS, kept as an attribute so entries are easy to find.
    static let service = "com.papertalk.key"

    /// Store `value` under `account`, replacing what was there.
    static func set(_ value: String, account: String) {
        _ = withAttributes(account) { schema, attributes -> Bool? in
            var error: UnsafeMutablePointer<GError>?
            _ = secret_password_storev_sync(schema, attributes, nil, "Papertalk: \(account)", value, nil, &error)
            if let error { g_error_free(error) }
            return true
        }
    }

    /// The string saved under `account`, if any.
    static func get(_ account: String) -> String? {
        withAttributes(account) { schema, attributes -> String? in
            var error: UnsafeMutablePointer<GError>?
            let secret = secret_password_lookupv_sync(schema, attributes, nil, &error)
            if let error { g_error_free(error) }
            guard let secret else { return nil }
            defer { secret_password_free(secret) }
            let value = String(cString: secret)
            return value.isEmpty ? nil : value
        }
    }

    /// Remove `account`'s entry.
    static func delete(_ account: String) {
        _ = withAttributes(account) { schema, attributes -> Bool? in
            var error: UnsafeMutablePointer<GError>?
            _ = secret_password_clearv_sync(schema, attributes, nil, &error)
            if let error { g_error_free(error) }
            return true
        }
    }

    /// The schema ("service" and "account" string attributes) and the attribute table for
    /// `account`, for the duration of `body`.
    private static func withAttributes<T>(_ account: String,
                                          _ body: (UnsafePointer<SecretSchema>, OpaquePointer) -> T?) -> T? {
        // No session bus, no keyring: don't let libsecret try to autolaunch one.
        guard ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"]?.isEmpty == false else { return nil }
        let types = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, nil)!
        defer { g_hash_table_unref(types) }
        for name in ["service", "account"] {
            g_hash_table_insert(types, g_strdup(name), UnsafeMutableRawPointer(bitPattern: Int(SECRET_SCHEMA_ATTRIBUTE_STRING.rawValue)))
        }
        // GLib casts the enum to a pointer, so STRING (0) is a null value: that's expected.
        let schema = secret_schema_newv("dev.papertalk.desktop.Key", SECRET_SCHEMA_NONE, types)!
        defer { secret_schema_unref(schema) }

        let attributes = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free)!
        defer { g_hash_table_unref(attributes) }
        g_hash_table_insert(attributes, g_strdup("service"), g_strdup(service))
        g_hash_table_insert(attributes, g_strdup("account"), g_strdup(account))
        return body(schema, attributes)
    }
}
#endif
