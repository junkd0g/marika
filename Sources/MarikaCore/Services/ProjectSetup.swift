import Foundation

public enum ProjectSetup {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var status: Int32?
        func append(_ chunk: Data) { lock.withLock { data.append(chunk); data = data.suffix(64_000) } }
        func finish(_ code: Int32) { lock.withLock { status = code } }
        var result: (Int32?, Data) { lock.withLock { (status, data) } }
    }
    public static func run(command: String, directory: URL, environment: [String: String], timeout: TimeInterval = 600) async throws {
        let output = Output()
        let process = ProcessGroup(output: { output.append($0) }, completion: { output.finish($0) })
        try process.start(command: command, directory: directory, environment: environment)
        defer { process.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while output.result.0 == nil {
            try Task.checkCancellation()
            guard Date() < deadline else { throw AgentError.launchFailed("Worktree setup timed out.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let (status, data) = output.result
        guard status == 0 else { throw AgentError.launchFailed("Worktree setup failed (exit \(status ?? -1)).\n" + String(decoding: data, as: UTF8.self)) }
    }
}
