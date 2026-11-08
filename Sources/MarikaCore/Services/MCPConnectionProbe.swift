import Foundation

public struct MCPToolSummary: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var readOnly: Bool? = nil
    public var destructive: Bool? = nil
    public var openWorld: Bool? = nil
    public var permissionsSummary: String {
        if destructive == true { return "May delete or replace data" }
        if readOnly == true { return "Read only" }
        if readOnly == false { return "Can change data" }
        return "Access not specified"
    }
}

public struct MCPConnectionReport: Sendable, Equatable {
    public var server: String
    public var version: String
    public var protocolVersion: String
    public var tools: [MCPToolSummary]
    public var resources: Int
    public var prompts: Int
    public var checkedAt: Date
}

private protocol MCPProbeTransport: Sendable {
    func start() async throws
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue
    func notify(_ method: String, _ params: JSONValue) async throws
    func setVersion(_ version: String) async
    func close() async
}

/// A bounded discovery connection. It never calls a server tool or asks a model for output.
public enum MCPConnectionProbe {
    public static func check(name: String, configuration: JSONValue, root: URL, environment: [String: String], timeout: Double = 15) async throws -> MCPConnectionReport {
        let raw = try JSONValue.object(["mcpServers": .object([name: configuration])]).serialized()
        _ = try ProjectMCP.servers(String(decoding: raw, as: UTF8.self))
        let resolved = try ProjectMCP.resolved([name: configuration], environment: environment)
        guard let config = try ProjectMCP.claudeServers(resolved, environment: environment)[name] else { throw AgentError.launchFailed("Enable this server before testing it.") }
        let transport: any MCPProbeTransport
        if let command = config["command"]?.string {
            var env = environment
            for (key, value) in config["env"]?.object ?? [:] { if let text = value.string { env[key] = text } }
            guard let executable = command.hasPrefix("/") ? URL(fileURLWithPath: command) : ShellEnvironment.locate(command, in: env) else {
                throw AgentError.launchFailed("Couldn't find \(command). Install it or provide its full path.")
            }
            transport = MCPStdioProbe(executable: executable, arguments: config["args"]?.array?.compactMap(\.string) ?? [], root: root, environment: env)
        } else if let address = config["url"]?.string, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            transport = MCPHTTPProbe(url: url, headers: (config["headers"]?.object ?? [:]).compactMapValues(\.string), root: root, legacy: config["type"]?.string == "sse")
        } else { throw AgentError.launchFailed("Provide an MCP server command or an HTTP URL.") }
        do {
            let report = try await withThrowingTaskGroup(of: MCPConnectionReport.self) { group in
                group.addTask { try await discover(transport) }
                group.addTask {
                    try await Task.sleep(for: .seconds(max(1, min(timeout, 60))))
                    throw AgentError.launchFailed("The MCP connection check timed out.")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
            await transport.close()
            return report
        } catch { await transport.close(); throw error }
    }
    private static func discover(_ transport: any MCPProbeTransport) async throws -> MCPConnectionReport {
        try await transport.start()
        let response = try await transport.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": ["roots": ["listChanged": false]], "clientInfo": ["name": "Marika connection check", "version": "1"]])
        guard let version = response["protocolVersion"]?.string, ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(version) else {
            throw AgentError.protocolError("The server selected an unsupported MCP protocol version.")
        }
        await transport.setVersion(version)
        try await transport.notify("notifications/initialized", [:])
        var tools: [MCPToolSummary] = []
        var resources = 0, prompts = 0
        if response["capabilities"]?["tools"] != nil {
            let entries = try await list("tools", transport)
            tools = entries.compactMap { item in
                guard let name = item["name"]?.string else { return nil }
                return MCPToolSummary(name: name, description: String((item["description"]?.string ?? "").prefix(2_000)),
                    readOnly: item["annotations"]?["readOnlyHint"]?.bool, destructive: item["annotations"]?["destructiveHint"]?.bool,
                    openWorld: item["annotations"]?["openWorldHint"]?.bool)
            }
        }
        if response["capabilities"]?["resources"] != nil { resources = try await list("resources", transport).count }
        if response["capabilities"]?["prompts"] != nil { prompts = try await list("prompts", transport).count }
        return MCPConnectionReport(server: response["serverInfo"]?["name"]?.string ?? "MCP server",
            version: response["serverInfo"]?["version"]?.string ?? "", protocolVersion: version,
            tools: tools, resources: resources, prompts: prompts, checkedAt: Date())
    }
    private static func list(_ kind: String, _ transport: any MCPProbeTransport) async throws -> [JSONValue] {
        var result: [JSONValue] = [], cursor: String?
        for _ in 0..<10 {
            let page = try await transport.request(kind + "/list", cursor.map { ["cursor": .string($0)] } ?? [:])
            result += page[kind]?.array ?? []
            if result.count >= 500 { return Array(result.prefix(500)) }
            cursor = page["nextCursor"]?.string
            if cursor == nil { break }
        }
        return result
    }
}

private func mcpClientReply(_ request: JSONValue, root: URL) -> JSONValue? {
    guard let id = request["id"], let method = request["method"]?.string else { return nil }
    switch method {
    case "ping": return ["jsonrpc": "2.0", "id": id, "result": [:]]
    case "roots/list": return ["jsonrpc": "2.0", "id": id, "result": ["roots": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]]]]
    default: return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "This connection check does not perform sampling, elicitation or tool calls."]]
    }
}

private func mcpResult(_ message: JSONValue) throws -> JSONValue {
    if let error = message["error"], !error.isNull { throw AgentError.protocolError(error["message"]?.string ?? "MCP request failed.") }
    return message["result"] ?? .null
}

private actor MCPStdioProbe: MCPProbeTransport {
    private let process: LineProcess
    private let root: URL
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var listener: Task<Void, Never>?
    init(executable: URL, arguments: [String], root: URL, environment: [String: String]) {
        self.root = root
        process = LineProcess(executable: executable, arguments: arguments, environment: environment, workingDirectory: root)
    }
    func start() throws {
        try process.start()
        listener = Task { [weak self, process] in
            for await output in process.output {
                guard let self else { break }
                switch output {
                case .line(let data): await receive(data)
                case .exited(let status, _): await fail(AgentError.launchFailed("MCP server exited (\(status))."))
                }
            }
        }
    }
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        nextID += 1; let id = nextID
        let message: JSONValue = ["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": params]
        let data = try message.serialized()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation; process.write(data)
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func notify(_ method: String, _ params: JSONValue) throws { process.write(try JSONValue.object(["jsonrpc": "2.0", "method": .string(method), "params": params]).serialized()) }
    func setVersion(_ version: String) {}
    private func receive(_ data: Data) {
        do {
            guard data.count < 4_000_000 else { throw AgentError.protocolError("MCP response exceeded the size limit.") }
            let value = try JSONValue(parsing: data)
            if let reply = mcpClientReply(value, root: root) { process.write(try reply.serialized()) }
            else if let id = value["id"]?.int, let continuation = pending.removeValue(forKey: id) {
                do { continuation.resume(returning: try mcpResult(value)) } catch { continuation.resume(throwing: error) }
            }
        } catch { fail(AgentError.protocolError("The MCP server returned an invalid response.")) }
    }
    private func cancel(_ id: Int) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    private func fail(_ error: any Error) {
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
    }
    func close() {
        fail(CancellationError()); listener?.cancel(); listener = nil
        process.closeInput(); process.terminate()
        let process = process
        Task { try? await Task.sleep(for: .milliseconds(350)); process.forceKill() }
    }
}

private final class MCPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let before = response.url, after = request.url
        completionHandler(before?.scheme == after?.scheme && before?.host == after?.host && before?.port == after?.port ? request : nil)
    }
}

/// AsyncBytes.lines omits the blank lines that delimit SSE events. Parse bytes so that
/// multiple data fields, CRLF, comments and the terminating blank line remain intact.
private struct MCPSSEParser {
    private var line = Data()
    private var event = ""
    private var data: String?
    private var previousCR = false

    mutating func consume(_ byte: UInt8) throws -> (event: String, data: String)? {
        if byte == 10, previousCR { previousCR = false; return nil }
        previousCR = byte == 13
        if byte != 10 && byte != 13 {
            line.append(byte)
            guard line.count < 4_000_000 else { throw AgentError.protocolError("MCP response exceeded the size limit.") }
            return nil
        }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            let message = data.map { (event: event, data: $0) }
            event = ""; data = nil
            return message
        }
        guard !text.hasPrefix(":"), let colon = text.firstIndex(of: ":") else { return nil }
        let field = text[..<colon]
        var value = String(text[text.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "event" { event = value }
        if field == "data" {
            data = data.map { $0 + "\n" + value } ?? value
            guard (data?.utf8.count ?? 0) < 4_000_000 else { throw AgentError.protocolError("MCP response exceeded the size limit.") }
        }
        return nil
    }
}

private actor MCPHTTPProbe: MCPProbeTransport {
    private let url: URL
    private let headers: [String: String]
    private let root: URL
    private let legacy: Bool
    private let session: URLSession
    private var protocolVersion: String?
    private var sessionID: String?
    private var nextID = 0
    private var endpoint: URL?
    private var endpointWaiter: CheckedContinuation<Void, Error>?
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var listener: Task<Void, Never>?

    init(url: URL, headers: [String: String], root: URL, legacy: Bool) {
        self.url = url; self.headers = headers; self.root = root; self.legacy = legacy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: MCPRedirectPolicy(), delegateQueue: nil)
    }
    func start() async throws {
        guard legacy else { return }
        var request = makeRequest(url, method: "GET")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        try check(response)
        listener = Task { [weak self] in
            do {
                var parser = MCPSSEParser()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard let self else { return }
                    if let message = try parser.consume(byte) { await receiveLegacy(event: message.event, data: message.data) }
                }
                await self?.fail(AgentError.protocolError("The MCP event stream closed."))
            } catch { await self?.fail(error) }
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if endpoint != nil { return }
            try await withCheckedThrowingContinuation { endpointWaiter = $0 }
        } onCancel: { Task { await self.fail(CancellationError()) } }
    }
    func setVersion(_ version: String) { protocolVersion = version }
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        nextID += 1; let id = nextID
        let value: JSONValue = ["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": params]
        if !legacy { return try await post(value, expecting: id) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { do { _ = try await post(value, expecting: nil) } catch { cancel(id, error: error) } }
            }
        } onCancel: { Task { await self.cancel(id, error: CancellationError()) } }
    }
    func notify(_ method: String, _ params: JSONValue) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": .string(method), "params": params], expecting: nil)
    }
    private func makeRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        return request
    }
    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw AgentError.protocolError("The MCP server did not return HTTP.") }
        if response.statusCode == 401 || response.statusCode == 403 { throw AgentError.launchFailed("Authentication is required. Check this server's authorization headers or sign-in configuration.") }
        guard (200..<300).contains(response.statusCode) else { throw AgentError.launchFailed("MCP server returned HTTP \(response.statusCode). Check the endpoint URL.") }
        if let id = response.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
    }
    private func post(_ value: JSONValue, expecting id: Int?) async throws -> JSONValue {
        var request = makeRequest(endpoint ?? url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try value.serialized()
        let (bytes, response) = try await session.bytes(for: request)
        try check(response)
        guard let id else { return .null }
        if (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            var parser = MCPSSEParser()
            for try await byte in bytes {
                try Task.checkCancellation()
                if let event = try parser.consume(byte) {
                    let message = try JSONValue(parsing: Data(event.data.utf8))
                    if message["id"]?.int == id, message["method"] == nil { return try mcpResult(message) }
                    if let reply = mcpClientReply(message, root: root) { _ = try await post(reply, expecting: nil) }
                }
            }
        } else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count < 4_000_000 else { throw AgentError.protocolError("MCP response exceeded the size limit.") }
            }
            let message = try JSONValue(parsing: data)
            guard message["id"]?.int == id else { throw AgentError.protocolError("The MCP response did not match the request.") }
            return try mcpResult(message)
        }
        throw AgentError.protocolError("The MCP stream ended before returning a response.")
    }
    private func receiveLegacy(event: String, data: String) async {
        do {
            if event == "endpoint" {
                guard let address = URL(string: data, relativeTo: url)?.absoluteURL,
                      address.scheme == url.scheme, address.host == url.host, address.port == url.port else { throw AgentError.protocolError("The MCP message endpoint changed origin.") }
                endpoint = address; endpointWaiter?.resume(); endpointWaiter = nil
            } else if let value = try? JSONValue(parsing: Data(data.utf8)) {
                if let reply = mcpClientReply(value, root: root) { _ = try await post(reply, expecting: nil) }
                else if let id = value["id"]?.int, let continuation = pending.removeValue(forKey: id) {
                    do { continuation.resume(returning: try mcpResult(value)) } catch { continuation.resume(throwing: error) }
                }
            }
        } catch { fail(error) }
    }
    private func cancel(_ id: Int, error: any Error) { pending.removeValue(forKey: id)?.resume(throwing: error) }
    private func fail(_ error: any Error) {
        endpointWaiter?.resume(throwing: error); endpointWaiter = nil
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
    }
    func close() async {
        fail(CancellationError()); listener?.cancel(); listener = nil
        if sessionID != nil, !legacy {
            var request = makeRequest(url, method: "DELETE"); request.timeoutInterval = 2
            _ = try? await session.data(for: request)
        }
        session.invalidateAndCancel()
    }
}
