import Foundation

/// A JSON-RPC connection to `codex app-server` over stdio. The wire format is JSON-RPC 2.0 with the
/// `"jsonrpc"` member omitted.
///
/// Frames are delivered to `inbound` one at a time, in order. A handler must never wait for a reply
/// to its own request from inside `inbound`: the reply can't be read until the handler returns.
public actor CodexConnection {
    typealias Inbound = @Sendable (Message) async -> Void

    enum Message: Sendable {
        case notification(method: String, params: JSONValue)
        case request(id: JSONValue, method: String, params: JSONValue)
        case exited(status: Int32, stderrTail: String)
    }

    /// Long enough for MCP servers to start, short enough that a wedged server can't hang the app.
    public static let defaultTimeout: Duration = .seconds(60)

    private let process: LineProcess
    private var nextID: Int64 = 1
    private var waiters: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var hasExited = false
    private var exitReason: String?
    private let inbound: Inbound

    init(
        executable: URL, environment: [String: String], workingDirectory: URL, arguments: [String] = [], appendServerArgument: Bool = true, inbound: @escaping Inbound
    ) {
        process = LineProcess(
            executable: executable, arguments: arguments + (appendServerArgument ? ["app-server"] : []), environment: environment,
            workingDirectory: workingDirectory)
        self.inbound = inbound
    }

    func start() throws {
        try process.start()
        let process = process
        readTask = Task { [weak self] in
            for await output in process.output {
                await self?.ingest(output)
            }
        }
    }

    /// The handshake every connection needs. Returns the CLI's version.
    @discardableResult
    func initialize(timeout: Duration = .seconds(20)) async throws -> String? {
        let result = try await request(
            "initialize",
            [
                "clientInfo": ["name": "marika", "title": "Marika", "version": .string(marikaCoreVersion)],
                "capabilities": ["experimentalApi": false, "requestAttestation": false],
            ],
            timeout: timeout)
        notify("initialized", [:])
        // The user agent looks like `marika/0.166.0 (Mac OS …)`.
        return result["userAgent"]?.string?.split(separator: " ").first?.split(separator: "/").last.map(String.init)
    }

    func request(
        _ method: String, _ params: JSONValue = [:], timeout: Duration = CodexConnection.defaultTimeout
    ) async throws -> JSONValue {
        guard !hasExited else {
            throw AgentError.protocolError(exitReason ?? "Codex is not running.")
        }
        let id = nextID
        nextID += 1
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.expire(id, method: method)
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            write(["method": .string(method), "id": .int(id), "params": params])
        }
    }

    private func expire(_ id: Int64, method: String) {
        waiters.removeValue(forKey: id)?.resume(throwing: AgentError.timedOut("Codex didn't answer \(method) in time."))
    }

    func notify(_ method: String, _ params: JSONValue) {
        write(["method": .string(method), "params": params])
    }

    func respond(to id: JSONValue, result: JSONValue) {
        write(["id": id, "result": result])
    }

    func respondWithError(to id: JSONValue, code: Int64, message: String) {
        write(["id": id, "error": ["code": .int(code), "message": .string(message)]])
    }

    func close() async {
        process.closeInput()
        let process = process
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            process.terminate()
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { process.forceKill() }
        }
        await readTask?.value
        watchdog.cancel()
    }

    private func write(_ message: JSONValue) {
        guard let data = try? message.serialized() else { return }
        process.write(data)
    }

    private func ingest(_ output: LineProcess.Output) async {
        switch output {
        case .line(let data):
            guard let message = try? JSONValue(parsing: data) else { return }
            await route(message)
        case .exited(let status, let stderrTail):
            hasExited = true
            let detail = stderrTail.split(separator: "\n").last.map(String.init)
            exitReason = detail.map { "Codex exited: \($0)" } ?? "Codex exited (status \(status))."
            for waiter in waiters.values {
                waiter.resume(throwing: AgentError.protocolError(exitReason ?? "Codex exited."))
            }
            waiters.removeAll()
            await inbound(.exited(status: status, stderrTail: stderrTail))
        }
    }

    private func route(_ message: JSONValue) async {
        if let method = message["method"]?.string {
            let params = message["params"] ?? .object([:])
            if let id = message["id"] {
                await inbound(.request(id: id, method: method, params: params))
            } else {
                await inbound(.notification(method: method, params: params))
            }
        } else if let id = message["id"]?.int.map(Int64.init), let waiter = waiters.removeValue(forKey: id) {
            if let error = message["error"] {
                waiter.resume(throwing: AgentError.protocolError(error["message"]?.string ?? "Codex rejected the request."))
            } else {
                waiter.resume(returning: message["result"] ?? .null)
            }
        }
    }
}
