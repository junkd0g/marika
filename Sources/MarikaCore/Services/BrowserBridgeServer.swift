import Foundation
import Network

/// A loopback-only, authenticated transport between agent MCP child processes and the app.
/// Each project gets its own random token and handler; no credentials appear in URLs or argv.
public final class BrowserBridgeServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.marika.browser-bridge")
    private let token: String
    private let handler: @Sendable (JSONValue) async -> JSONValue

    private final class StartWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
        func finish(_ result: Result<String, Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    public init(token: String, handler: @escaping @Sendable (JSONValue) async -> JSONValue) throws {
        self.token = token
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    public func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = StartWaiter(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = self?.listener.port { waiter.finish(.success("http://127.0.0.1:\(port.rawValue)/browser")) }
                    else { waiter.finish(.failure(BrowserError.message("Browser bridge has no port."))) }
                case .failed(let error): waiter.finish(.failure(error))
                case .cancelled: waiter.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }
    deinit { listener.cancel() }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = data
            if let chunk { buffer.append(chunk) }
            guard buffer.count <= 1_048_576 else { self.respond(connection, status: 413, body: [:]); return }
            if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var fields: [String: String] = [:]
                for header in headers.dropFirst() {
                    let parts = header.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { fields[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                guard headers.first == "POST /browser HTTP/1.1", fields["authorization"] == "Bearer \(self.token)",
                    let length = fields["content-length"].flatMap(Int.init), length >= 0, length <= 1_000_000
                else { self.respond(connection, status: 401, body: [:]); return }
                if buffer.count - boundary.upperBound >= length {
                    let body = buffer.subdata(in: boundary.upperBound..<(boundary.upperBound + length))
                    guard let request = try? JSONValue(parsing: body) else { self.respond(connection, status: 400, body: [:]); return }
                    Task {
                        let response = await self.handler(request)
                        self.respond(connection, status: 200, body: response)
                    }
                    return
                }
            }
            if complete || error != nil { connection.cancel() }
            else { self.receive(connection, data: buffer) }
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: JSONValue) {
        let body = (try? body.serialized()) ?? Data("{}".utf8)
        let header = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
