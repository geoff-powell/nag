import Foundation
import Network

/// Serves an `MCPHTTPHandler` over TCP with Network.framework. Plain HTTP: put it behind an HTTPS tunnel
/// to reach it over the internet.
public final class MCPHTTPServer: @unchecked Sendable {
    public enum Scope: Sendable {
        /// Only clients on this Mac.
        case thisMac
        /// Any device that can reach this Mac.
        case network
    }

    public enum State: Sendable, Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
        case stopped
    }

    private let handler: MCPHTTPHandler
    private let port: UInt16
    private let scope: Scope
    private let queue = DispatchQueue(label: "nag.mcp.http")
    private var listener: NWListener?

    /// - Parameter port: 0 picks a free port; `State.ready` says which.
    public init(handler: MCPHTTPHandler, port: UInt16, scope: Scope) {
        self.handler = handler
        self.port = port
        self.scope = scope
    }

    /// Starts listening. `onState` is called on a private queue.
    public func start(onState: @escaping @Sendable (State) -> Void) {
        queue.async { [self] in
            onState(.starting)
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if scope == .thisMac { parameters.requiredInterfaceType = .loopback }
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any)
            } catch {
                onState(.failed(error.localizedDescription))
                return
            }
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready: onState(.ready(port: listener?.port?.rawValue ?? 0))
                case .failed(let error): onState(.failed(Self.describe(error)))
                case .cancelled: onState(.stopped)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        if scope == .thisMac, !Self.isLoopback(connection.endpoint) {
            connection.cancel()
            return
        }
        HTTPConnection(connection: connection, handler: handler, queue: queue).start()
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address == IPv6Address("::ffff:127.0.0.1")
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    static func describe(_ error: NWError) -> String {
        if case .posix(.EADDRINUSE) = error { return "That port is already in use." }
        return error.localizedDescription
    }
}

/// One request and its response, then the connection closes.
private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: MCPHTTPHandler
    private let queue: DispatchQueue
    private var buffer = Data()
    private var finished = false

    static let timeout: DispatchTimeInterval = .seconds(30)

    init(connection: NWConnection, handler: MCPHTTPHandler, queue: DispatchQueue) {
        self.connection = connection
        self.handler = handler
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: finished = true
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.timeout) { [self] in
            guard !finished else { return }
            send(.text(408, "Timed out."))
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            guard !finished else { return }
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer, maxBodySize: MCPHTTPHandler.maxBodySize) {
            case .complete(let request):
                send(handler.respond(to: request))
            case .invalid(let status):
                send(.text(status, "Bad request."))
            case .incomplete:
                if isComplete || error != nil {
                    finished = true
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }
    }

    private func send(_ response: HTTPResponse) {
        finished = true
        connection.send(content: response.serialized(), completion: .contentProcessed { [self] _ in
            connection.cancel()
            // Break the cycle between the connection and this object's handlers.
            connection.stateUpdateHandler = nil
        })
    }
}
