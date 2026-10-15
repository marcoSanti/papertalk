#if os(Linux)
import Foundation

/// Linux entry point. Until the GTK UI lands (docs/LINUX_PORT.md, Phase 4) it
/// only runs headless imports.
@main
enum PapertalkLinux {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.contains("--import") {
            exit(await HeadlessImport.run(arguments))
        }
        print("Papertalk for Linux: the window isn't ported yet. Try --import paper.pdf.")
    }
}
#endif
