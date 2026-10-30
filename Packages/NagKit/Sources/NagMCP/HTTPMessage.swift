import Foundation

/// Just enough HTTP/1.1 for MCP's Streamable HTTP transport: one request per connection, bodies sized by
/// Content-Length, responses closed after sending.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    /// The path without its query string.
    public var path: String
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public enum Parse: Sendable, Hashable {
        /// Keep reading.
        case incomplete
        case complete(HTTPRequest)
        /// Respond with this status and close.
        case invalid(status: Int)
    }

    static let maxHeaderSize = 16 * 1024

    /// Parses a request from everything received so far.
    public static func parse(_ buffer: Data, maxBodySize: Int) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHeaderSize ? .invalid(status: 431) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(status: 411) }

        let length: Int
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { return .invalid(status: 400) }
            length = value
        } else {
            length = 0
        }
        guard length <= maxBodySize else { return .invalid(status: 413) }

        let bodyStart = end.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        var request = HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, body: body)
        request.headers = headers
        return .complete(request)
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(_ status: Int, _ message: String, headers: [String: String] = [:]) -> HTTPResponse {
        var headers = headers
        headers["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: headers, body: Data((message + "\n").utf8))
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var headers = headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        for name in headers.keys.sorted() {
            head += "\(name): \(headers[name]!)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}
