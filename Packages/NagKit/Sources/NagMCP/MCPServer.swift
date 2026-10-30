import Foundation
import NagCore

/// The Model Context Protocol, over JSON-RPC 2.0, for Nag's tools. Transport independent: stdio and HTTP
/// both hand it a message and send back whatever it returns.
///
/// Only tools are offered. Requests are answered synchronously, so there are no progress notifications,
/// cancellation or server-initiated requests.
public struct MCPServer: Sendable {
    /// Newest first. A client asking for one of these gets it; anything else gets the newest.
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let tools: NagTools
    public let version: String

    public init(tools: NagTools, version: String) {
        self.tools = tools
        self.version = version
    }

    public struct Reply: Sendable {
        /// The response to send, or `nil` when there's nothing to send (notifications and responses).
        public var body: Data?
        /// Set when the message was an `initialize`.
        public var initialization: Initialization?
    }

    /// What a client said about itself when it initialized.
    public struct Initialization: Sendable, Hashable {
        public var clientName: String?
    }

    /// Handles one message, or a batch. `clientName` is the name the client gave when it initialized,
    /// used as the source of nags it adds.
    public func handle(_ data: Data, clientName: String?) -> Reply {
        guard let message = JSONValue.decode(data) else {
            return Reply(body: Self.error(id: .null, code: -32700, message: "Parse error").encoded())
        }
        var initialization: Initialization?
        func one(_ message: JSONValue) -> JSONValue? {
            let (response, initialized) = handleMessage(message, clientName: clientName)
            if let initialized { initialization = initialized }
            return response
        }
        switch message {
        case .array(let batch):
            guard !batch.isEmpty else {
                return Reply(body: Self.error(id: .null, code: -32600, message: "Empty batch").encoded())
            }
            let responses = batch.compactMap(one)
            return Reply(body: responses.isEmpty ? nil : JSONValue.array(responses).encoded(), initialization: initialization)
        default:
            return Reply(body: one(message)?.encoded(), initialization: initialization)
        }
    }

    private func handleMessage(_ message: JSONValue, clientName: String?) -> (JSONValue?, Initialization?) {
        guard case .object = message else {
            return (Self.error(id: .null, code: -32600, message: "Invalid request"), nil)
        }
        guard let method = message["method"]?.stringValue else {
            // A response to a request we never sent, or junk without an ID. Nothing to say either way.
            if message["id"] == nil || message["result"] != nil || message["error"] != nil { return (nil, nil) }
            return (Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid request"), nil)
        }
        // Notifications (no ID) never get a response.
        guard let id = message["id"] else { return (nil, nil) }
        let params = message["params"] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            let client = params["clientInfo"]?["name"]?.stringValue
            let result: JSONValue = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "nag", "title": "Nag", "version": .string(self.version)],
                "instructions": .string(tools.instructions()),
            ]
            return (Self.result(id: id, result), Initialization(clientName: client))
        case "ping":
            return (Self.result(id: id, [:]), nil)
        case "tools/list":
            return (Self.result(id: id, ["tools": .array(tools.definitions)]), nil)
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return (Self.error(id: id, code: -32602, message: "Missing tool name"), nil)
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            guard let result = tools.call(name, arguments: arguments, clientName: clientName) else {
                return (Self.error(id: id, code: -32602, message: "Unknown tool: \(name)"), nil)
            }
            return (Self.result(id: id, result), nil)
        default:
            return (Self.error(id: id, code: -32601, message: "Method not found: \(method)"), nil)
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}
