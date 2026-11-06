import Foundation
import Testing
@testable import MarikaCore

struct ProjectWorkflowTests {
    private func git(_ args: [String], root: URL) async throws -> String {
        let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path] + args)
        #expect(result.succeeded, Comment(rawValue: result.errorOutput))
        return result.output
    }
    @Test func partialStagingUnstagingAndRevertPreserveOtherEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await git(["init", "-b", "main"], root: root)
        _ = try await git(["config", "user.name", "Test"], root: root)
        _ = try await git(["config", "user.email", "test@example.test"], root: root)
        let original = (1...35).map { "Line \($0)" }.joined(separator: "\n") + "\n"
        let file = root.appendingPathComponent("a file.txt")
        try original.write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(["add", "."], root: root)
        _ = try await git(["commit", "-m", "base"], root: root)
        let changed = original.replacingOccurrences(of: "Line 2\n", with: "First edit\n").replacingOccurrences(of: "Line 30\n", with: "Second edit\n")
        try changed.write(to: file, atomically: true, encoding: .utf8)
        let repository = RepositoryActions(root: root, environment: ProcessInfo.processInfo.environment)
        var patch = try await repository.patch(try #require(await repository.changes().first))
        #expect(patch.hunks.count == 2)
        try await repository.edit(.stage, patch: patch, hunk: 0)
        let indexed = try await git(["show", ":a file.txt"], root: root)
        #expect(indexed.contains("First edit") && !indexed.contains("Second edit"))
        patch = try await repository.patch(try #require(await repository.changes().first(where: \.staged)))
        try await repository.edit(.unstage, patch: patch, hunk: 0)
        #expect(try await git(["diff", "--cached"], root: root).isEmpty)
        patch = try await repository.patch(try #require(await repository.changes().first))
        try await repository.edit(.revert, patch: patch, hunk: 0)
        let remaining = try String(contentsOf: file, encoding: .utf8)
        #expect(remaining.contains("Line 2\n") && remaining.contains("Second edit"))
        await #expect(throws: AgentError.self) { try await repository.edit(.stage, patch: patch) }
        patch = try await repository.patch(try #require(await repository.changes().first))
        try await repository.edit(.stage, patch: patch)
        _ = try await repository.commit("Keep second edit")
        #expect(try await repository.changes().isEmpty)
        let remote = root.appendingPathComponent("remote.git")
        _ = try await git(["init", "--bare", remote.path], root: root)
        _ = try await git(["remote", "add", "origin", remote.path], root: root)
        _ = try await repository.push()
        #expect(try await git(["log", "main", "-1", "--format=%s"], root: remote).contains("Keep second edit"))
    }
    @Test func newBinaryFilesCanBeStagedFromNestedProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subdirectory = root.appendingPathComponent("service")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await git(["init", "-b", "main"], root: root)
        try Data([0, 255, 1]).write(to: subdirectory.appendingPathComponent("image.bin"))
        let repository = RepositoryActions(root: subdirectory, environment: ProcessInfo.processInfo.environment)
        let change = try #require(await repository.changes().first)
        let patch = try await repository.patch(change)
        #expect(patch.display.isBinary)
        try await repository.edit(.stage, patch: patch)
        #expect(try await git(["diff", "--cached", "--name-only"], root: root).contains("service/image.bin"))
    }
    @Test func playbooksAndConnectionsRoundTripAndResolveEnvironment() throws {
        var tools = ProjectTools()
        tools.skills = [ProjectSkill(name: "Review", instructions: "Inspect error paths.")]
        tools.mcpConfig = #"{"mcpServers":{"test":{"command":"echo","args":["hello"],"env":{"TOKEN":"${TEST_TOKEN}"}}}}"#
        let decoded = try JSONDecoder().decode(ProjectTools.self, from: JSONEncoder().encode(tools))
        #expect(decoded.instructions.contains("Inspect error paths."))
        let servers = try ProjectMCP.servers(decoded.mcpConfig)
        #expect(throws: AgentError.self) { try ProjectMCP.resolved(servers, environment: [:]) }
        let resolved = try ProjectMCP.resolved(servers, environment: ["TEST_TOKEN": "test-only"])
        #expect(resolved["test"]?["env"]?["TOKEN"]?.string == "test-only")
        #expect(try ProjectMCP.codexArguments(resolved).contains(where: { $0.contains("mcp_servers.test.env=") }))
    }
    @Test func setupRunsInsideItsWorktreeAndReportsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectSetup.run(command: "printf ready > setup.txt", directory: root, environment: ProcessInfo.processInfo.environment)
        #expect(try String(contentsOf: root.appendingPathComponent("setup.txt"), encoding: .utf8) == "ready")
        await #expect(throws: AgentError.self) { try await ProjectSetup.run(command: "exit 7", directory: root, environment: ProcessInfo.processInfo.environment) }
    }
}
