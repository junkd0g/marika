import Foundation
import Testing
@testable import MarikaCore

struct IDEWorkflowTests {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func remoteFilesUseTheRemoteRootAndRejectStaleSaves() async throws {
        let root = try temporary(), remote = try temporary(), cache = try temporary()
        defer { for url in [root, remote, cache] { try? FileManager.default.removeItem(at: url) } }
        let docker = root.appendingPathComponent("docker")
        try "#!/bin/sh\nfor argument do last=\"$argument\"; done\nexec /bin/sh -c \"$last\"\n".write(to: docker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docker.path)
        try "before".write(to: remote.appendingPathComponent("code.txt"), atomically: true, encoding: .utf8)
        let environment = ["PATH": root.path + ":/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let files = RemoteFiles(runtime: WorkspaceRuntime(kind: .container, target: "test-container", directory: remote.path), cache: cache, environment: environment)
        #expect(try await files.entries().first?.name == "code.txt")
        let snapshot = try await files.read("code.txt")
        _ = try await files.write("after", replacing: snapshot)
        #expect(try String(contentsOf: remote.appendingPathComponent("code.txt"), encoding: .utf8) == "after")
        await #expect(throws: AgentError.self) { try await files.write("stale", replacing: snapshot) }
        await #expect(throws: (any Error).self) { try await files.read("../escape") }
    }
    @Test func regexReplacementBuildsReviewableChanges() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        try "old_12 old_34".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let files = ProjectFiles(root: root)
        let matches = try await ProjectSearch.search("old_([0-9]+)", root: root, regularExpression: true)
        #expect(matches.count == 2)
        let edits = try await ProjectSearch.replacements("old_([0-9]+)", replacement: "new_$1", caseSensitive: true, regularExpression: true, files: files)
        #expect(edits.first?.updated == "new_12 new_34")
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "old_12 old_34")
    }
    @Test func gitHistoryAndThreeWayConflictResolution() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String], succeeds: Bool = true) async throws {
            let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path] + arguments)
            #expect(result.succeeded == succeeds)
        }
        try await git(["init", "-b", "main"])
        try await git(["config", "user.name", "Test"]); try await git(["config", "user.email", "test@example.invalid"])
        let file = root.appendingPathComponent("code.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["add", "."]); try await git(["commit", "-m", "Base"])
        try await git(["switch", "-c", "feature"])
        try "incoming\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["commit", "-am", "Incoming"]); try await git(["switch", "main"])
        try "current\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["commit", "-am", "Current"]); try await git(["merge", "feature"], succeeds: false)
        let repository = RepositoryActions(root: root, environment: ProcessInfo.processInfo.environment)
        let conflict = try await repository.conflict("code.txt")
        #expect(conflict.base == "base\n" && conflict.current == "current\n" && conflict.incoming == "incoming\n")
        try await repository.resolve(conflict, text: "combined\n")
        #expect(try await repository.conflictPaths().isEmpty)
        #expect(try await repository.history().count == 2)
        #expect(try await repository.graph().contains("Current"))
    }
    @Test func extensionManifestsKeepStructuredConfiguration() throws {
        let item = IDEExtension(id: "custom", name: "Custom", languages: ["graphql"], command: "graphql-lsp", arguments: ["server", "--stdio"])
        try item.validate()
        let decoded = try JSONDecoder().decode(IDEExtension.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
        #expect(throws: AgentError.self) { try IDEExtension(id: "bad", name: "", languages: [], command: "").validate() }
    }
}
