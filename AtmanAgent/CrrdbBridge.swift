import Foundation

/// The embedded crrdb-mcp instance (see submodules/crrdb-mcp): the same Rust
/// code desktop agents run as an MCP server, linked here as a static library.
/// One process-wide handle; the Rust side serializes DB access internally.
enum Crrdb {
    /// Documents so the file is visible in the Files app (UIFileSharingEnabled).
    static let databaseURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("atman.sqlite")

    static let shared: CrrdbMcp = {
        do {
            return try CrrdbMcp(dbPath: databaseURL.path)
        } catch {
            fatalError("cannot open crrdb-mcp database: \(error)")
        }
    }()
}
