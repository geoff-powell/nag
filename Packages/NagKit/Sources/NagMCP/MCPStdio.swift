import Foundation

/// MCP over stdio: one JSON-RPC message per line on stdin, one response per line on stdout. This is how
/// desktop clients like Claude Desktop, Claude Code, Cursor and VS Code run local servers.
public enum MCPStdio {
    /// Serves until stdin closes. Logs go to stderr, since stdout carries only protocol messages.
    public static func run(server: MCPServer) async {
        var clientName: String?
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.allSatisfy(\.isWhitespace) else { continue }
                let reply = server.handle(Data(line.utf8), clientName: clientName)
                if let initialization = reply.initialization {
                    clientName = initialization.clientName
                    log("Connected to \(clientName ?? "an MCP client").")
                }
                if let body = reply.body {
                    FileHandle.standardOutput.write(body + Data("\n".utf8))
                }
            }
        } catch {
            log("Stopped reading: \(error.localizedDescription)")
        }
    }

    public static func log(_ message: String) {
        FileHandle.standardError.write(Data("nag-mcp: \(message)\n".utf8))
    }
}
