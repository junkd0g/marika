import Foundation
import Network

/// One-use loopback callback. Invalid paths, hosts and OAuth states never complete sign-in.
public final class OAuthCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.marika.oauth-callback")
    private let lock = NSLock()
    private let state: String
    private let path: String
    private var result: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    public init(state: String, redirect: URL? = nil) throws {
        self.state = state
        if let redirect {
            guard redirect.scheme == "http", redirect.host == "127.0.0.1", let port = redirect.port, port >= 1024, port <= 65535,
                  redirect.path.hasPrefix("/oauth/"), redirect.user == nil, redirect.password == nil, redirect.query == nil, redirect.fragment == nil else {
                throw AgentError.launchFailed("Use a loopback redirect such as http://127.0.0.1:8765/oauth/slack, with an unprivileged port and no query or credentials.")
            }
        }
        path = redirect?.path ?? "/oauth/" + UUID().uuidString.lowercased()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: redirect?.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) } ?? .any)
        listener = try NWListener(using: parameters)
    }
    private final class Start: @unchecked Sendable {
        let lock = NSLock()
        var waiter: CheckedContinuation<URL, Error>?
        init(_ waiter: CheckedContinuation<URL, Error>) { self.waiter = waiter }
        func finish(_ result: Result<URL, Error>) {
            lock.lock(); let waiter = self.waiter; self.waiter = nil; lock.unlock()
            waiter?.resume(with: result)
        }
    }
    public func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let start = Start(continuation)
                listener.stateUpdateHandler = { [weak self] status in
                    switch status {
                    case .ready:
                        guard let self, let port = self.listener.port,
                              let url = URL(string: "http://127.0.0.1:\(port.rawValue)" + self.path) else { start.finish(.failure(CancellationError())); return }
                        start.finish(.success(url))
                    case .failed(let error): start.finish(.failure(error))
                    case .cancelled: start.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    connection.start(queue: self.queue); self.receive(connection, Data())
                }
                listener.start(queue: queue)
            }
        } onCancel: { self.stop() }
    }
    public func code(timeout: Double = 180) async throws -> String {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { self?.finish(.failure(AgentError.timedOut("MCP sign-in timed out. Try signing in again."))) }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result) }
                else { waiter = continuation; lock.unlock() }
            }
        } onCancel: { self.stop() }
    }
    private func finish(_ value: Result<String, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let waiter = self.waiter; self.waiter = nil
        lock.unlock(); waiter?.resume(with: value)
    }
    public func stop() { finish(.failure(CancellationError())); listener.cancel() }
    deinit { listener.cancel() }
    private func receive(_ connection: NWConnection, _ data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            let buffer = data + (chunk ?? Data())
            guard buffer.count <= 8192 else { connection.cancel(); return }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer) }; return
            }
            let lines = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            guard first.count == 3, first[0] == "GET", let components = URLComponents(string: String(first[1])), components.path == self.path,
                  lines.contains(where: { $0.lowercased() == "host: 127.0.0.1:\(self.listener.port?.rawValue ?? 0)" }),
                  components.queryItems?.filter({ $0.name == "state" }).count == 1,
                  components.queryItems?.first(where: { $0.name == "state" })?.value == self.state else {
                self.respond(connection, code: 400, text: "Invalid sign-in callback."); return
            }
            if components.queryItems?.contains(where: { $0.name == "error" }) == true {
                self.finish(.failure(AgentError.launchFailed("MCP sign-in was declined. You can try again from Project Settings.")))
                self.respond(connection, code: 200, text: "Sign-in cancelled. You can close this tab.")
            } else if let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty,
                      components.queryItems?.filter({ $0.name == "code" }).count == 1 {
                self.finish(.success(code)); self.respond(connection, code: 200, text: "Sign-in received. Return to Marika to finish connecting.")
            } else { self.respond(connection, code: 400, text: "The sign-in callback is missing its code.") }
        }
    }
    private func respond(_ connection: NWConnection, code: Int, text: String) {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(code) Response\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
