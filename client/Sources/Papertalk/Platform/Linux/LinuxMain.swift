#if os(Linux)
import Foundation

/// Linux entry point until the GTK UI lands (AGENTS.md, "Linux port").
@main
enum PapertalkLinux {
    static func main() {
        print("Papertalk for Linux: the window isn't ported yet.")
    }
}
#endif
