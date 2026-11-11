import Foundation
import Testing
@testable import MarikaCore

private final class FixtureCredentials: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writes = 0
    private var shouldRejectWrites = false
    var rejectsWrites: Bool {
        get { lock.withLock { shouldRejectWrites } }
        set { lock.withLock { shouldRejectWrites = newValue } }
    }
    func read(_ key: String) -> String? { lock.withLock { values[key] } }
    func write(_ value: String?, _ key: String) -> Bool {
        lock.withLock {
            writes += 1
            guard !shouldRejectWrites else { return false }
            values[key] = value
            return true
        }
    }
    var writeCount: Int { lock.withLock { writes } }
    var access: ContainerCredentialAccess { ContainerCredentialAccess(read: { self.read($0) }, write: { self.write($0, $1) }) }
}

struct ContainerStructureTests {
    @Test func invalidConnectionDoesNotTouchCredentials() throws {
        let credentials = FixtureCredentials(), project = UUID()
        let settings = ContainerConnectionSettings(credentials: credentials.access)
        let invalid = ContainerLogConnection(endpoint: "not a URL", grafanaURL: "https://grafana.example")
        #expect(throws: ContainerHubError.self) { try settings.save(invalid, projectID: project, token: "new-token", removingToken: false) }
        #expect(credentials.writeCount == 0)
        let invalidGrafana = ContainerLogConnection(endpoint: "https://loki.example", grafanaURL: "https://name:password@grafana.example")
        #expect(throws: ContainerHubError.self) { try settings.save(invalidGrafana, projectID: project, token: "new-token", removingToken: false) }
        #expect(credentials.writeCount == 0)
    }

    @Test func connectionSavePreservesTokensUnlessExplicitlyChanged() throws {
        let credentials = FixtureCredentials(), project = UUID()
        let settings = ContainerConnectionSettings(credentials: credentials.access)
        let draft = ContainerLogConnection(endpoint: "  https://loki.example  ", grafanaURL: " https://grafana.example ")
        let saved = try settings.save(draft, projectID: project, token: "first-token", removingToken: false)
        #expect(saved.endpoint == "https://loki.example" && saved.grafanaURL == "https://grafana.example")
        _ = try settings.save(saved, projectID: project, token: "", removingToken: false)
        #expect(settings.token(for: saved, projectID: project) == "first-token")
        #expect(credentials.writeCount == 1)
        #expect(settings.token(for: saved, projectID: UUID()) == nil)
        #expect(settings.token(for: saved, projectID: project, replacement: "preview-token") == "preview-token")
        #expect(settings.token(for: saved, projectID: project, replacement: "preview-token", removing: true) == nil)
        _ = try settings.save(saved, projectID: project, token: "ignored", removingToken: true)
        #expect(settings.token(for: saved, projectID: project) == nil)
    }

    @Test func rejectedCredentialWriteLeavesTheExistingTokenAvailable() throws {
        let credentials = FixtureCredentials(), project = UUID()
        let settings = ContainerConnectionSettings(credentials: credentials.access)
        let connection = ContainerLogConnection(endpoint: "https://loki.example")
        _ = try settings.save(connection, projectID: project, token: "original", removingToken: false)
        credentials.rejectsWrites = true
        #expect(throws: ContainerHubError.self) { try settings.save(connection, projectID: project, token: "replacement", removingToken: false) }
        #expect(settings.token(for: connection, projectID: project) == "original")
    }

    @Test func logFilterCombinesTimeSourceTextAndSeverityWithoutMutatingInput() {
        let start = Date(timeIntervalSince1970: 100), end = start.addingTimeInterval(30)
        let entries = [
            ContainerLogEntry(id: "info", timestamp: start, source: "api", message: "INFO ready"),
            ContainerLogEntry(id: "warn", timestamp: end, source: "queue", message: "WARN delayed"),
            ContainerLogEntry(id: "error", timestamp: end.addingTimeInterval(0.0002), source: "api", message: "ERROR rejected"),
            ContainerLogEntry(id: "old", timestamp: start.addingTimeInterval(-1), source: "api", message: "ERROR old")]
        let warnings = ContainerLogFilter(text: "", severity: .warningsAndErrors, start: start, end: end)
        #expect(warnings.apply(to: entries).map(\.id) == ["warn", "error"])
        let source = ContainerLogFilter(text: "API", severity: .errors, start: start, end: end)
        #expect(source.apply(to: entries).map(\.id) == ["error"])
        #expect(entries.count == 4)
    }

    @Test func processLaunchKeepsArgumentsLiteralAndMergesCommandEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika launch " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake tool")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$MODE\" \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let arguments = ["space in arg", "$(touch should-not-run)", "quote'and\"text"]
        let command = ContainerCommand("fake tool", arguments, environment: ["MODE": "command"])
        let launch = try ContainerProcessLaunch(command: command, directory: root, environment: ["PATH": root.path, "MODE": "base"])
        #expect(launch.shellCommand == "exec " + ([executable.path] + arguments).map(WorkspaceRuntime.quote).joined(separator: " "))
        #expect(launch.directory == root && launch.environment["MODE"] == "command")
        let result = try await Command.run(URL(fileURLWithPath: "/bin/zsh"), ["-c", launch.shellCommand], workingDirectory: launch.directory, environment: launch.environment)
        #expect(result.succeeded)
        #expect(result.output.split(separator: "\n").map(String.init) == ["command"] + arguments)
        #expect(throws: ContainerHubError.self) { try ContainerProcessLaunch(command: ContainerCommand("missing", []), directory: root, environment: ["PATH": root.path]) }
    }

    @Test func grafanaDiscoveryUsesTheSelectedContextAndOnlyReturnsTheLink() async throws {
        let cli = ContainerCLI(root: URL(fileURLWithPath: "/tmp"), environment: [:], runner: { command in
            #expect(command.arguments == ["--context", "chosen", "--request-timeout=20s", "--namespace", "monitoring", "get", "configmap", "grafana", "-o", "json"])
            return ContainerCommandResult(output: #"{"data":{"datasources.yaml":"url: https://team.grafana.net/explore\npassword: private-fixture"}}"#)
        })
        #expect(try await cli.grafanaCloudURL(ContainerTarget(name: "chosen")) == "https://team.grafana.net/explore")
    }
}
