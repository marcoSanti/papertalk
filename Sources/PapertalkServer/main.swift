// The storage server's command line: shares one Papertalk library between copies of the app on
// several machines (`StorageServer`). Settings come from the environment, the same variables
// the old server/storage_server.py read, so an existing setup keeps working.

import Foundation
import PapertalkStore

let env = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath: NSString(string: env["PAPER2POD_STORAGE_ROOT"] ?? "~/.paper2pod/storage").expandingTildeInPath,
               isDirectory: true)
let token = env["PAPER2POD_STORAGE_TOKEN"] ?? ""
guard let port = Int(env["PAPER2POD_STORAGE_PORT"] ?? "9170"), (0...65535).contains(port) else {
    FileHandle.standardError.write(Data("PAPER2POD_STORAGE_PORT must be a port number (0-65535).\n".utf8))
    exit(2)
}

do {
    let server = try StorageServer(root: root, host: env["PAPER2POD_STORAGE_HOST"], port: port, token: token)
    print("papertalk storage on http://\(server.host):\(server.port)  (root: \(root.path))")
    if token.isEmpty {
        print(server.host.hasPrefix("127.")
            ? "No token, so only this machine can connect. Set PAPER2POD_STORAGE_TOKEN to share it on the network."
            : "WARNING: no token. Anyone who can reach \(server.host):\(server.port) can read and delete the library.")
    }
    fflush(stdout)
    server.run()
} catch {
    FileHandle.standardError.write(Data("Could not start the storage server: \(error)\n".utf8))
    exit(1)
}
