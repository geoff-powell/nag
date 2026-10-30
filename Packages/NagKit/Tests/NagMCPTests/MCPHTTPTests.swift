import Foundation
import Testing
@testable import NagMCP

struct HTTPParseTests {
    @Test func completeRequest() {
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nAuthorization: Bearer t\r\n\r\n{}"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8), maxBodySize: 100) else {
            Issue.record("Expected a request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.headers["authorization"] == "Bearer t")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func waitsForTheRest() {
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Le".utf8), maxBodySize: 100) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".utf8), maxBodySize: 100) == .incomplete)
    }

    @Test func rejectsWhatItCantHandle() {
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 500\r\n\r\n".utf8), maxBodySize: 100) == .invalid(status: 413))
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8), maxBodySize: 100) == .invalid(status: 411))
        #expect(HTTPRequest.parse(Data("garbage\r\n\r\n".utf8), maxBodySize: 100) == .invalid(status: 400))
        #expect(HTTPRequest.parse(Data(repeating: 65, count: 20_000), maxBodySize: 100) == .invalid(status: 431))
    }

    @Test func responseHasLengthAndCloses() {
        let text = String(decoding: HTTPResponse(status: 202).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(text.contains("Content-Length: 0\r\n"))
        #expect(text.contains("Connection: close\r\n"))
    }
}

struct MCPHTTPHandlerTests {
    let fixture = MCPFixture()
    let token = "secret-token"
    var handler: MCPHTTPHandler { MCPHTTPHandler(server: fixture.server, token: token) }

    func post(_ message: JSONValue, session: String? = nil, auth: String? = nil, origin: String? = nil, to handler: MCPHTTPHandler) -> HTTPResponse {
        var headers = ["Authorization": auth ?? "Bearer \(token)", "Content-Type": "application/json"]
        if let session { headers["Mcp-Session-Id"] = session }
        if let origin { headers["Origin"] = origin }
        return handler.respond(to: HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: message.encoded()))
    }

    let initialize: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "Claude Code"]]]

    @Test func needsTheToken() {
        let handler = handler
        #expect(post(initialize, auth: "", to: handler).status == 401)
        #expect(post(initialize, auth: "Bearer wrong", to: handler).status == 401)
        #expect(post(initialize, auth: "Bearer secret-token-and-more", to: handler).status == 401)
        #expect(post(initialize, auth: "Basic secret-token", to: handler).headers["WWW-Authenticate"] == "Bearer")
        #expect(post(initialize, to: handler).status == 200)
    }

    @Test func refusesWebPagesButNotLocalhost() {
        let handler = handler
        #expect(post(initialize, origin: "https://evil.example", to: handler).status == 403)
        #expect(post(initialize, origin: "http://localhost:6274", to: handler).status == 200)
    }

    @Test func onlyTheMCPPathAndMethods() {
        let handler = handler
        let auth = ["Authorization": "Bearer \(token)"]
        #expect(handler.respond(to: HTTPRequest(method: "POST", path: "/other", headers: auth)).status == 404)
        #expect(handler.respond(to: HTTPRequest(method: "GET", path: "/mcp", headers: auth)).status == 405)
    }

    @Test func sessionsCarryTheClientName() throws {
        let handler = handler
        let initialized = post(initialize, to: handler)
        let session = try #require(initialized.headers["Mcp-Session-Id"])

        let notified = post(["jsonrpc": "2.0", "method": "notifications/initialized"], session: session, to: handler)
        #expect(notified.status == 202)
        #expect(notified.body.isEmpty)

        let created = post(
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "create_nag", "arguments": ["title": "From HTTP"]]],
            session: session,
            to: handler
        )
        #expect(created.status == 200)
        #expect(created.headers["Content-Type"] == "application/json")
        #expect(fixture.store.load().tasks.first?.source == "Claude Code")

        #expect(post(["jsonrpc": "2.0", "id": 3, "method": "ping"], session: "unknown", to: handler).status == 404)

        let auth = ["Authorization": "Bearer \(token)", "Mcp-Session-Id": session]
        #expect(handler.respond(to: HTTPRequest(method: "DELETE", path: "/mcp", headers: auth)).status == 200)
        #expect(post(["jsonrpc": "2.0", "id": 4, "method": "ping"], session: session, to: handler).status == 404)
    }

    @Test func tokensAreLongAndURLSafe() {
        let token = MCPHTTPHandler.newToken()
        #expect(token.count == 43)
        #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(token != MCPHTTPHandler.newToken())
    }
}

struct MCPHTTPServerTests {
    @Test func servesOverLoopback() async throws {
        let fixture = MCPFixture()
        let server = MCPHTTPServer(handler: MCPHTTPHandler(server: fixture.server, token: "t"), port: 0, scope: .thisMac)
        defer { server.stop() }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Resumed()
            server.start { state in
                switch state {
                case .ready(let port): if resumed.claim() { continuation.resume(returning: port) }
                case .failed(let message): if resumed.claim() { continuation.resume(throwing: StartFailed(message: message)) }
                default: break
                }
            }
        }
        #expect(port > 0)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let message: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "create_nag", "arguments": ["title": "Over the wire"]]]
        request.httpBody = message.encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(JSONValue.decode(data)?["result"]?["isError"] == false)
        #expect(fixture.store.load().tasks.map(\.title) == ["Over the wire"])

        request.setValue("Bearer nope", forHTTPHeaderField: "Authorization")
        let (_, rejected) = try await URLSession.shared.data(for: request)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 401)
    }

    struct StartFailed: Error {
        let message: String
    }

    /// Resumes a continuation once, whatever states arrive after.
    final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }
}
