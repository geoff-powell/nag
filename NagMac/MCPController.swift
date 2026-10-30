import Foundation
import NagCore
import NagMCP
import Observation
import SystemConfiguration

/// Nag's MCP server over HTTP, for AI assistants that can't launch Nag themselves: other machines, or
/// clients that only speak HTTP. Off until switched on in Settings. The settings and token live in this
/// Mac's user defaults; they don't sync.
@MainActor
@Observable
final class MCPController {
    enum Status: Equatable {
        case off
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    static let defaultPort = 4747
    static let portRange = 1024...65535

    private(set) var isEnabled: Bool
    private(set) var allowsNetwork: Bool
    private(set) var port: Int
    private(set) var token: String
    private(set) var status: Status = .off

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var server: MCPHTTPServer?

    private enum Key {
        static let enabled = "mcp.http.enabled"
        static let allowsNetwork = "mcp.http.allowsNetwork"
        static let port = "mcp.http.port"
        static let token = "mcp.http.token"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        allowsNetwork = defaults.bool(forKey: Key.allowsNetwork)
        let savedPort = defaults.integer(forKey: Key.port)
        port = Self.portRange.contains(savedPort) ? savedPort : Self.defaultPort
        if let saved = defaults.string(forKey: Key.token), !saved.isEmpty {
            token = saved
        } else {
            token = MCPHTTPHandler.newToken()
            defaults.set(token, forKey: Key.token)
        }
    }

    func start() {
        restart()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        restart()
    }

    func setAllowsNetwork(_ allows: Bool) {
        allowsNetwork = allows
        defaults.set(allows, forKey: Key.allowsNetwork)
        restart()
    }

    func setPort(_ port: Int) {
        let port = min(max(port, Self.portRange.lowerBound), Self.portRange.upperBound)
        guard port != self.port else { return }
        self.port = port
        defaults.set(port, forKey: Key.port)
        restart()
    }

    /// Replaces the token. Clients using the old one stop working.
    func regenerateToken() {
        token = MCPHTTPHandler.newToken()
        defaults.set(token, forKey: Key.token)
        restart()
    }

    private func restart() {
        server?.stop()
        server = nil
        guard isEnabled else {
            status = .off
            return
        }
        let tools = NagTools(store: .shared)
        let handler = MCPHTTPHandler(server: MCPServer(tools: tools, version: MCPCommand.version), token: token)
        let server = MCPHTTPServer(handler: handler, port: UInt16(port), scope: allowsNetwork ? .network : .thisMac)
        self.server = server
        status = .starting
        server.start { [weak self, weak server] state in
            Task { @MainActor in
                // Ignore a server that's since been replaced.
                guard let self, let server, self.server === server else { return }
                switch state {
                case .starting: self.status = .starting
                case .ready(let port): self.status = .running(port: port)
                case .failed(let message): self.status = .failed(message)
                case .stopped: self.status = .off
                }
            }
        }
    }

    // MARK: - Connection details

    /// Where clients connect.
    var endpoint: String {
        let host = allowsNetwork ? Self.localHostName ?? "127.0.0.1" : "127.0.0.1"
        return "http://\(host):\(port)\(MCPHTTPHandler.path)"
    }

    /// This Mac's Bonjour name, such as `Jane-MacBook.local`, for other devices to reach it by.
    static var localHostName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    /// The command that runs Nag as a stdio MCP server.
    var executablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Nag.app/Contents/MacOS/Nag"
    }

    /// For `claude_desktop_config.json`, Cursor's `mcp.json` and the like.
    var stdioConfig: String {
        let server: JSONValue = ["command": .string(executablePath), "args": [.string(MCPCommand.flag)]]
        let config: JSONValue = ["mcpServers": ["nag": server]]
        return config.prettyString()
    }

    var claudeCodeStdioCommand: String {
        "claude mcp add --scope user nag -- \"\(executablePath)\" \(MCPCommand.flag)"
    }

    var claudeCodeHTTPCommand: String {
        "claude mcp add --scope user --transport http nag \(endpoint) --header \"Authorization: Bearer \(token)\""
    }
}
