// Settings as JSON in user defaults. Two formats are on users' disks, so both stay: a string
// (`SavedJSON`) for the older settings, data (`UserDefaults.decoded`) for the newer.

import Foundation

/// A value saved as a JSON string.
enum SavedJSON {
    /// The value under `key`; nil when there's none or it doesn't decode.
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let raw = UserDefaults.standard.string(forKey: key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Save `value` under `key`.
    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: key)
        }
    }
}

extension UserDefaults {
    /// The value saved as JSON data under `key`.
    func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Save `value` as JSON data under `key`.
    func setEncoded<T: Encodable>(_ value: T, forKey key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
    }
}
