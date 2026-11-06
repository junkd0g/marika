import Foundation

public struct RemoteMachine: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var host: String
    public var directory: String
    public init(name: String, host: String, directory: String) { self.name = name; self.host = host; self.directory = directory }
    public func arguments(command: String? = nil) throws -> [String] {
        guard !host.isEmpty, !host.hasPrefix("-"), host.range(of: #"^[A-Za-z0-9_.@:-]+$"#, options: .regularExpression) != nil,
              directory.hasPrefix("/"), !directory.contains("\0") else {
            throw AgentError.launchFailed("Use an SSH host or user@host and an absolute remote directory.")
        }
        let quote = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["-t", "--", host, "cd " + quote + " && " + (command ?? "exec ${SHELL:-/bin/sh} -l")]
    }
}

public struct ProjectHook: Codable, Hashable, Identifiable, Sendable {
    public enum Event: String, Codable, CaseIterable, Sendable { case beforeTurn = "Before turn", afterTurn = "After turn" }
    public var id = UUID()
    public var event: Event
    public var command: String
    public var enabled = true
    public init(event: Event, command: String) { self.event = event; self.command = command }
}

public struct DebugRun: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var command: String
    public var directory: String
    public var output: String
    public var exitCode: Int32
    public var timedOut: Bool
    public init(command: String, directory: String, output: String, exitCode: Int32, timedOut: Bool) {
        self.command = command; self.directory = directory; self.output = output; self.exitCode = exitCode; self.timedOut = timedOut
    }
    public var agentPrompt: String {
        """
        Debug this observed runtime failure. Read the relevant code, state hypotheses supported by the evidence, and reproduce the issue before changing code. Add a focused regression check, make the smallest justified fix, then rerun the original command and report the observed result. If reproduction is blocked, report the blocker rather than claiming success.

        Working directory: \(directory)
        Reproduction command: \(command)
        Exit: \(exitCode)\(timedOut ? " (timed out)" : "")
        Captured output (may be truncated):
        ```
        \(output)
        ```
        """
    }
}
