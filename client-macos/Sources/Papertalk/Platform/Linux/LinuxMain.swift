#if os(Linux)
import Foundation

/// Linux entry point. Until the GTK UI lands (AGENTS.md, "Linux port") it
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
