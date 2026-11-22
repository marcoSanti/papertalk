// The storage server's command line: shares one Papertalk library between copies of the app on
// several machines (`StorageServer`). Settings come from the environment, the same variables
// the old server/storage_server.py read, so an existing setup keeps working.

import Foundation
import PapertalkStore

let env = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath: NSString(string: env["PAPER2POD_STORAGE_ROOT"] ?? "~/.paper2pod/storage").expandingTildeInPath,
               isDirectory: true)
let host = env["PAPER2POD_STORAGE_HOST"] ?? "0.0.0.0"
guard let port = Int(env["PAPER2POD_STORAGE_PORT"] ?? "9170"), (0...65535).contains(port) else {
    FileHandle.standardError.write(Data("PAPER2POD_STORAGE_PORT must be a port number (0-65535).\n".utf8))
    exit(2)
}

do {
    let server = try StorageServer(root: root, host: host, port: port, token: env["PAPER2POD_STORAGE_TOKEN"] ?? "")
    print("papertalk storage on http://\(host):\(server.port)  (root: \(root.path))")
    fflush(stdout)
    server.run()
} catch {
    FileHandle.standardError.write(Data("Could not start the storage server: \(error)\n".utf8))
    exit(1)
}
