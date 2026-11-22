// Reading the PDF the user chose to import.

import Foundation

/// Reading a PDF the user picked or dropped (sandbox-scoped URLs included).
enum PDFFile {
    /// Shown when the file can't be read, naming it.
    struct ReadError: LocalizedError {
        let name: String
        var errorDescription: String? { L("Could not read {0}", name) }
    }

    /// The file's bytes, entering its security scope first (a file picked in a sandboxed panel).
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { return try Data(contentsOf: url) } catch { throw ReadError(name: url.lastPathComponent) }
    }
}
