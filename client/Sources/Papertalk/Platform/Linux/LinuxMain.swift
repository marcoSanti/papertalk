#if os(Linux)
import Foundation

/// Linux entry point until the GTK UI lands (docs/LINUX_PORT.md, Phase 4).
@main
enum PapertalkLinux {
    static func main() {
        print("Papertalk for Linux: the UI isn't ported yet.")
    }
}
#endif
