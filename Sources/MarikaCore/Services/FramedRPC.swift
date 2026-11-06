import Foundation
import Darwin

/// The byte framing shared by LSP and DAP. Lengths are UTF-8 bytes, never character counts.
public struct RPCFrames: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [JSONValue] {
        buffer.append(data)
        guard buffer.count <= 32_000_000 else { throw AgentError.protocolError("Language tool exceeded the message limit.") }
        var result: [JSONValue] = []
        while let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
            guard let field = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(field.dropFirst(15).trimmingCharacters(in: .whitespaces)), (0...16_000_000).contains(length) else {
                throw AgentError.protocolError("Invalid language-tool message header.")
            }
            let start = separator.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= length else { break }
            let end = buffer.index(start, offsetBy: length)
            result.append(try JSONValue(parsing: Data(buffer[start..<end])))
            buffer.removeSubrange(buffer.startIndex..<end)
        }
        return result
    }
    public static func encode(_ value: JSONValue) throws -> Data {
        let body = try value.serialized()
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}

public actor FramedRPC {
    public enum Wire: Sendable { case lsp, dap }
    public nonisolated let events: AsyncStream<JSONValue>
    private let sink: AsyncStream<JSONValue>.Continuation
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var frames = RPCFrames()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var ended = false
    private let wire: Wire
    private var socketDescriptor: Int32?
    private var port: UInt16?
    public init(port: UInt16, wire: Wire = .dap) {
        (events, sink) = AsyncStream.makeStream()
        self.wire = wire; self.port = port
    }
    public init(executable: URL, arguments: [String], directory: URL, environment: [String: String], wire: Wire = .lsp) {
        (events, sink) = AsyncStream.makeStream()
        self.wire = wire
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = directory; process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
    }
    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        if let port {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.ECONNREFUSED) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let code = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard code == 0 else { Darwin.close(descriptor); throw POSIXError(.ECONNREFUSED) }
            socketDescriptor = descriptor
            Task.detached { [weak self] in
                while let data = Self.readChunk(descriptor) { await self?.consume(data) }
                await self?.socketEnded(descriptor)
                Darwin.close(descriptor)
            }
            return
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { [weak self] process in
            Task { try? await Task.sleep(for: .seconds(1)); await self?.finish("Tool exited (\(process.terminationStatus)).") }
        }
        do {
            try process.run()
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
            let handle = output.fileHandleForReading
            Task.detached { [weak self] in
                while let data = Self.readChunk(handle.fileDescriptor) { await self?.consume(data) }
                await self?.finish("Language tool disconnected.")
            }
        }
        catch { finish(error.localizedDescription); throw error }
    }
    public func request(_ method: String, _ params: JSONValue = [:], timeout: Double = 15) async throws -> JSONValue {
        guard !ended else { throw AgentError.launchFailed("The language tool is disconnected.") }
        nextID += 1
        let id = nextID
        let message: JSONValue = wire == .lsp
            ? ["jsonrpc": "2.0", "id": .int(Int64(id)), "method": .string(method), "params": params]
            : ["seq": .int(Int64(id)), "type": "request", "command": .string(method), "arguments": params]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    await self?.fail(id, "\(method) timed out.")
                }
                do { try write(message) } catch { fail(id, error.localizedDescription) }
            }
        } onCancel: { Task { await self.fail(id, "Request cancelled.") } }
    }
    public func notify(_ method: String, _ params: JSONValue = [:]) throws {
        try write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }
    public func respond(id: JSONValue, result: JSONValue) throws {
        try write(["jsonrpc": "2.0", "id": id, "result": result])
    }
    public func close() {
        if let descriptor = socketDescriptor {
            socketDescriptor = nil
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        if !ended { try? input.fileHandleForWriting.close() }
        if process.isRunning { process.terminate() }
        let child = process
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        finish("Tool disconnected.")
    }
    private func write(_ message: JSONValue) throws {
        guard !ended else { throw AgentError.launchFailed("Tool disconnected.") }
        let data = try RPCFrames.encode(message)
        if let descriptor = socketDescriptor {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(.EPIPE) }
                    offset += count
                }
            }
        } else { try input.fileHandleForWriting.write(contentsOf: data) }
    }
    private func consume(_ data: Data) {
        do {
            for message in try frames.append(data) {
                let id = wire == .lsp ? message["id"]?.int : message["request_seq"]?.int
                let isReply = wire == .lsp ? message["method"] == nil : message["type"]?.string == "response"
                if isReply, let id, let continuation = pending.removeValue(forKey: id) {
                    timers.removeValue(forKey: id)?.cancel()
                    if let error = message["error"], !error.isNull {
                        continuation.resume(throwing: AgentError.protocolError(error["message"]?.string ?? "Language request failed."))
                    } else if wire == .dap, message["success"]?.bool == false {
                        continuation.resume(throwing: AgentError.protocolError(message["message"]?.string ?? "Debugger request failed."))
                    } else { continuation.resume(returning: message[wire == .lsp ? "result" : "body"] ?? .null) }
                } else if !isReply { sink.yield(message) }
            }
        } catch { finish(error.localizedDescription) }
    }
    private func fail(_ id: Int, _ message: String) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: AgentError.protocolError(message))
    }
    private func finish(_ message: String) {
        guard !ended else { return }
        ended = true
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        for id in Array(pending.keys) { fail(id, message) }
        sink.yield(["method": "marika/disconnected", "params": ["message": .string(message)]])
        sink.finish()
    }
    private nonisolated static func readChunk(_ descriptor: Int32) -> Data? {
        var data = Data(count: 64_000)
        let count = data.withUnsafeMutableBytes { buffer in Darwin.read(descriptor, buffer.baseAddress, buffer.count) }
        if count < 0, errno == EINTR { return readChunk(descriptor) }
        guard count > 0 else { return nil }
        data.count = count
        return data
    }
    private func socketEnded(_ descriptor: Int32) {
        if socketDescriptor == descriptor { socketDescriptor = nil }
        finish("Debugger disconnected.")
    }
}
