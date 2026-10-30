import Foundation

/// MCP's Streamable HTTP transport, minus streaming: every POST gets a single JSON response, and there's
/// no server-to-client event stream (GET answers 405, which the spec allows).
///
/// Every request needs `Authorization: Bearer <token>`. Requests from web pages (with an `Origin` that
/// isn't localhost) are refused, so a page can't use the browser to reach the server.
public final class MCPHTTPHandler: @unchecked Sendable {
    public static let path = "/mcp"
    static let maxSessions = 64
    static let maxBodySize = 1024 * 1024

    private let server: MCPServer
    private let token: String
    private let lock = NSLock()
    /// Oldest first.
    private var sessions: [Session] = []

    private struct Session {
        let id: String
        let clientName: String?
    }

    public init(server: MCPServer, token: String) {
        self.server = server
        self.token = token
    }

    public func respond(to request: HTTPRequest) -> HTTPResponse {
        guard request.path == Self.path else { return .text(404, "Not found. The MCP endpoint is \(Self.path).") }
        if let origin = request.headers["origin"], !Self.isLocalOrigin(origin) {
            return .text(403, "Requests from web pages aren't allowed.")
        }
        guard Self.isAuthorized(request.headers["authorization"], token: token) else {
            return .text(401, "Missing or wrong bearer token.", headers: ["WWW-Authenticate": "Bearer"])
        }

        let sessionID = request.headers["mcp-session-id"]
        switch request.method {
        case "POST":
            return post(request, sessionID: sessionID)
        case "DELETE":
            guard let sessionID else { return .text(400, "Missing Mcp-Session-Id.") }
            return removeSession(sessionID) ? HTTPResponse(status: 200) : .text(404, "Unknown session.")
        default:
            return .text(405, "Use POST.", headers: ["Allow": "POST, DELETE"])
        }
    }

    private func post(_ request: HTTPRequest, sessionID: String?) -> HTTPResponse {
        var clientName: String?
        if let sessionID {
            // An unknown session (say, from before Nag restarted) tells the client to initialize again.
            guard let session = self.session(sessionID) else { return .text(404, "Unknown session. Initialize again.") }
            clientName = session.clientName
        }
        let reply = server.handle(request.body, clientName: clientName)

        var headers = ["Content-Type": "application/json"]
        if let initialization = reply.initialization {
            headers["Mcp-Session-Id"] = addSession(clientName: initialization.clientName)
        } else if let sessionID {
            headers["Mcp-Session-Id"] = sessionID
        }
        guard let body = reply.body else {
            headers["Content-Type"] = nil
            return HTTPResponse(status: 202, headers: headers)
        }
        return HTTPResponse(status: 200, headers: headers, body: body)
    }

    // MARK: - Sessions

    private func addSession(clientName: String?) -> String {
        let id = UUID().uuidString
        lock.withLock {
            sessions.append(Session(id: id, clientName: clientName))
            if sessions.count > Self.maxSessions { sessions.removeFirst(sessions.count - Self.maxSessions) }
        }
        return id
    }

    private func session(_ id: String) -> Session? {
        lock.withLock { sessions.first { $0.id == id } }
    }

    private func removeSession(_ id: String) -> Bool {
        lock.withLock {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
            sessions.remove(at: index)
            return true
        }
    }

    // MARK: - Checks

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host()?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// Compares in constant time, so response timing doesn't leak how much of the token was right.
    static func isAuthorized(_ header: String?, token: String) -> Bool {
        guard !token.isEmpty, let header else { return false }
        let prefix = "bearer "
        guard header.lowercased().hasPrefix(prefix) else { return false }
        let given = Array(header.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).utf8)
        let expected = Array(token.utf8)
        var difference = UInt8(given.count == expected.count ? 0 : 1)
        for index in expected.indices {
            difference |= expected[index] ^ (index < given.count ? given[index] : 0)
        }
        return difference == 0
    }

    /// A random token for a new server: 32 bytes, base64url.
    public static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
