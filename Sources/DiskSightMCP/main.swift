import Foundation
import MCP
import DiskSightCore

// DiskSightMCP — standalone Model Context Protocol stdio server for DiskSight.
//
// Read tools open the shared SQLite index READ-ONLY in-process (no app, no Full
// Disk Access required). Scan tools (added in a later milestone) connect to the
// running app over a Unix socket so the app remains the sole DB writer.

let version = "0.1.0"

// Resolve the database location. Override with DISKSIGHT_DB for tests/dev.
let databaseURL: URL = {
    if let override = ProcessInfo.processInfo.environment["DISKSIGHT_DB"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return DiskSightReader.defaultDatabaseURL
}()

let provider = ReaderProvider(databaseURL: databaseURL)

// The app-mediated scan socket lives next to the database. Override with
// DISKSIGHT_SOCK for tests/dev.
let socketURL: URL = {
    if let override = ProcessInfo.processInfo.environment["DISKSIGHT_SOCK"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return databaseURL.deletingLastPathComponent().appendingPathComponent("mcp.sock")
}()
let socketClient = AppSocketClient(socketURL: socketURL)

let server = Server(
    name: "DiskSight",
    version: version,
    capabilities: .init(
        tools: .init(listChanged: false)
    )
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: ReadTools.definitions() + ScanTools.definitions())
}

await server.withMethodHandler(CallTool.self) { params in
    if let result = await ReadTools.handle(name: params.name, arguments: params.arguments, provider: provider) {
        return result
    }
    if let result = await ScanTools.handle(name: params.name, arguments: params.arguments, client: socketClient) {
        return result
    }
    return textResult("Unknown tool: \(params.name)", isError: true)
}

Log.line("starting (db: \(databaseURL.path))")

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()

Log.line("stopped")
