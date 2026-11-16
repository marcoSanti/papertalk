// The desktop's light or dark preference on Linux, which SwiftCrossUI 0.9's GTK backend
// doesn't detect itself (it always draws its light scheme).

#if os(Linux)
import Foundation

/// Whether the desktop wants dark windows, read once at launch.
enum DesktopTheme {
    /// GTK_THEME first (`Adwaita:dark`, `Yaru-dark`), else GNOME's `color-scheme` setting,
    /// else a `-dark` theme name; light when nothing says otherwise.
    static func prefersDark(gtkThemeEnv: String?, colorScheme: String?, gtkTheme: String?) -> Bool {
        if let env = gtkThemeEnv?.lowercased(), !env.isEmpty {
            return env.hasSuffix(":dark") || env.contains("-dark")
        }
        if let scheme = colorScheme?.lowercased(), scheme.contains("prefer-dark") { return true }
        if let scheme = colorScheme?.lowercased(), scheme.contains("prefer-light") { return false }
        return gtkTheme?.lowercased().contains("dark") ?? false
    }

    /// This desktop's preference (asks `gsettings`; light where it's missing).
    static var systemPrefersDark: Bool {
        prefersDark(gtkThemeEnv: ProcessInfo.processInfo.environment["GTK_THEME"],
                    colorScheme: gsetting("color-scheme"),
                    gtkTheme: gsetting("gtk-theme"))
    }

    /// A key of `org.gnome.desktop.interface`, nil when gsettings or the key is missing.
    private static func gsetting(_ key: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gsettings", "get", "org.gnome.desktop.interface", key]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
