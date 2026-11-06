import Foundation
import Observation

@MainActor @Observable public final class DebuggerSession {
    public private(set) var status = "Stopped"
    public private(set) var output = ""
    public private(set) var frames: [JSONValue] = []
    public private(set) var variables: [JSONValue] = []
    public private(set) var watches: [String: String] = [:]
    public private(set) var error: String?
    public private(set) var isPaused = false
    public private(set) var isActive = false
    public var selectedFrame: Int?
    @ObservationIgnored private var rpc: FramedRPC?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var adapterProcess: Process?
    private var threadID = 1
    private var initialized = false
    public init() {}
    public func start(executable: URL, arguments: [String], root: URL, environment: [String: String], configuration: JSONValue, breakpoints: [String: [Int]], go: Bool = false, sourceRoot: String? = nil) async {
        await stop()
        error = nil; output = ""; frames = []; variables = []; selectedFrame = nil; initialized = false; status = "Starting"; isActive = true
        do {
            let connection: FramedRPC
            if go {
                let port = UInt16.random(in: 40000...59000)
                let process = Process(); process.executableURL = executable; process.arguments = ["dap", "--listen=127.0.0.1:\(port)"]
                process.environment = environment; process.currentDirectoryURL = root
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); adapterProcess = process
                connection = FramedRPC(port: port)
                var connected = false
                for _ in 0..<50 {
                    do { try await connection.start(); connected = true; break }
                    catch { try await Task.sleep(for: .milliseconds(100)) }
                }
                guard connected else { throw AgentError.launchFailed("Could not connect to the Go debugger.") }
            } else {
                connection = FramedRPC(executable: executable, arguments: arguments, directory: root, environment: environment, wire: .dap)
                try await connection.start()
            }
            rpc = connection
            events = Task { [weak self] in
                for await event in connection.events { await self?.handle(event) }
            }
            _ = try await connection.request("initialize", ["clientID": "marika", "adapterID": go ? "go" : "native", "pathFormat": "path", "linesStartAt1": true, "columnsStartAt1": true, "supportsRunInTerminalRequest": false])
            var launchConfiguration = configuration.object ?? [:]
            if go {
                launchConfiguration["cwd"] = .string(root.path)
                if configuration["program"]?.string == root.path { launchConfiguration["program"] = "." }
            }
            if sourceRoot == nil, let program = launchConfiguration["program"]?.string, program.hasPrefix("/") {
                launchConfiguration["program"] = .string(FilePath.resolved(program))
            }
            if sourceRoot == nil, let cwd = launchConfiguration["cwd"]?.string { launchConfiguration["cwd"] = .string(FilePath.resolved(cwd)) }
            var launchError: Error?
            let launchTask = Task {
                do { return try await connection.request("launch", .object(launchConfiguration), timeout: 180) }
                catch { launchError = error; throw error }
            }
            defer { launchTask.cancel() }
            for _ in 0..<1800 {
                if initialized { break }
                if let launchError { throw launchError }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard initialized else { throw AgentError.timedOut("Debugger did not initialize.") }
            for (path, lines) in breakpoints {
                let filePath = sourceRoot.map { URL(fileURLWithPath: $0).appendingPathComponent(path).path } ?? FilePath.resolved(root.appendingPathComponent(path).path)
                let result = try await connection.request("setBreakpoints", ["source": ["path": .string(filePath)], "breakpoints": .array(lines.map { ["line": .int(Int64($0))] })])
                for point in result["breakpoints"]?.array ?? [] where point["verified"]?.bool == false { output += "Unverified breakpoint: \(path) \(point["message"]?.string ?? "")\n" }
            }
            _ = try await connection.request("configurationDone")
            _ = try await launchTask.value
            if !isPaused { status = "Running" }
        } catch { self.error = error.localizedDescription; await stop() }
    }
    public func action(_ command: String) async {
        do { _ = try await rpc?.request(command, ["threadId": .int(Int64(threadID))]); if command != "pause" { isPaused = false; status = "Running"; frames = []; variables = [] } }
        catch { self.error = error.localizedDescription }
    }
    public func inspect(_ frame: JSONValue) async {
        guard let id = frame["id"]?.int else { return }
        selectedFrame = id
        do {
            let scopes = try await rpc?.request("scopes", ["frameId": .int(Int64(id))])
            var values: [JSONValue] = []
            for scope in scopes?["scopes"]?.array ?? [] {
                if let reference = scope["variablesReference"]?.int, reference > 0 {
                    let result = try await rpc?.request("variables", ["variablesReference": .int(Int64(reference)), "count": 100])
                    values += result?["variables"]?.array ?? []
                }
            }
            variables = Array(values.prefix(200))
            for key in watches.keys { await evaluate(key) }
        } catch { self.error = error.localizedDescription }
    }
    public func expand(_ variable: JSONValue) async -> [JSONValue] {
        guard let ref = variable["variablesReference"]?.int, ref > 0 else { return [] }
        return (try? await rpc?.request("variables", ["variablesReference": .int(Int64(ref)), "count": 100]))?["variables"]?.array ?? []
    }
    public func evaluate(_ expression: String) async {
        do {
            var arguments: [String: JSONValue] = ["expression": .string(expression), "context": "watch"]
            if let selectedFrame { arguments["frameId"] = .int(Int64(selectedFrame)) }
            let result = try await rpc?.request("evaluate", .object(arguments))
            watches[expression] = result?["result"]?.string ?? "Unavailable"
        } catch { watches[expression] = error.localizedDescription }
    }
    public func stop() async {
        let current = rpc; rpc = nil
        if let current { _ = try? await current.request("disconnect", ["terminateDebuggee": true], timeout: 2); await current.close() }
        events?.cancel(); events = nil
        if let adapterProcess, adapterProcess.isRunning { adapterProcess.terminate() }
        adapterProcess = nil; isActive = false; isPaused = false; status = "Stopped"
    }
    private func handle(_ event: JSONValue) async {
        if event["method"]?.string == "marika/disconnected", rpc != nil {
            error = event["params"]?["message"]?.string ?? "Debugger disconnected."
            isActive = false; isPaused = false; status = "Disconnected"; return
        }
        let body = event["body"] ?? [:]
        switch event["event"]?.string {
        case "initialized": initialized = true
        case "output": output = String((output + (body["output"]?.string ?? "")).suffix(64_000))
        case "stopped":
            threadID = body["threadId"]?.int ?? 1; status = "Loading stack"
            do {
                if threadID <= 0 {
                    let threads = try await rpc?.request("threads")
                    threadID = threads?["threads"]?[0]?["id"]?.int ?? threadID
                }
                let result = try await rpc?.request("stackTrace", ["threadId": .int(Int64(threadID)), "levels": 30])
                frames = result?["stackFrames"]?.array ?? []
                if let first = frames.first { await inspect(first) }
                isPaused = true; status = "Paused"
            } catch { self.error = error.localizedDescription }
        case "continued": isPaused = false; status = "Running"
        case "terminated", "exited": isActive = false; isPaused = false; status = "Finished"
        default: break
        }
    }
}
