import Foundation
import Testing
@testable import MarikaCore

@Suite struct AgentPartialReviewTests {
    private func git(_ args: [String], root: URL) async throws -> String {
        let result = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path] + args,
            environment: ProcessInfo.processInfo.environment)
        guard result.succeeded else { throw AgentWorktreeError(message: result.errorOutput) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func setup() async throws -> (URL, URL, AgentWorktrees, AgentWorkspace, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-project-\(UUID())")
        let managed = FileManager.default.temporaryDirectory.appendingPathComponent("review-worktrees-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await git(["init", "-b", "main"], root: root)
        _ = try await git(["config", "user.name", "Test"], root: root)
        _ = try await git(["config", "user.email", "test@example.test"], root: root)
        let original = (1...30).map { "line \($0)\n" }.joined()
        try Data(original.utf8).write(to: root.appendingPathComponent("sample file.txt"))
        _ = try await git(["add", "."], root: root)
        _ = try await git(["commit", "-m", "Initial"], root: root)
        let service = AgentWorktrees(directory: managed, environment: ProcessInfo.processInfo.environment)
        let workspace = try #require(await service.create(for: root, id: UUID()))
        return (root, managed, service, workspace, original)
    }
    private func change(_ text: String, workspace: AgentWorkspace, path: String = "sample file.txt") throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: workspace.rootPath).appendingPathComponent(path))
    }
    private func cleanup(_ root: URL, _ managed: URL) { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: managed) }

    @Test func acceptAndRejectAreIndependentAndSurviveReload() async throws {
        let (root, managed, service, workspace, original) = try await setup()
        defer { cleanup(root, managed) }
        let updated = original.replacingOccurrences(of: "line 3\n", with: "accepted\n").replacingOccurrences(of: "line 25\n", with: "rejected\n")
        try change(updated, workspace: workspace)
        try Data("keep this note".utf8).write(to: root.appendingPathComponent("user.txt"))
        let review = try await service.review(workspace, project: root)
        #expect(review.hunks.count == 2)
        let first = try #require(review.hunks.first)
        let remaining = try await service.decide(.accept, hunkID: first.id, review: review, workspace: workspace, project: root)
        #expect(remaining.hunks.count == 1)
        #expect(try String(contentsOf: root.appendingPathComponent("sample file.txt"), encoding: .utf8) == original.replacingOccurrences(of: "line 3\n", with: "accepted\n"))
        #expect(try String(contentsOf: root.appendingPathComponent("user.txt"), encoding: .utf8) == "keep this note")
        #expect(try await git(["diff", "--cached", "--name-only"], root: root).isEmpty)
        let restarted = AgentWorktrees(directory: managed, environment: ProcessInfo.processInfo.environment)
        // The persisted review ref is authoritative even before workspace metadata is saved.
        let restored = try await restarted.review(workspace, project: root)
        #expect(restored.hunks.count == 1)
        let last = try #require(restored.hunks.first)
        let done = try await restarted.decide(.reject, hunkID: last.id, review: restored, workspace: workspace, project: root)
        #expect(done.isEmpty)
        #expect(try String(contentsOf: URL(fileURLWithPath: workspace.rootPath).appendingPathComponent("sample file.txt"), encoding: .utf8) == original.replacingOccurrences(of: "line 3\n", with: "accepted\n"))
        #expect(try await restarted.review(workspace, project: root).isEmpty)
        #expect(try await git(["branch", "--show-current"], root: root) == "main")
    }

    @Test func applyingTheFullSourceBackedReviewUsesCanonicalRepositoryPaths() async throws {
        let (root, managed, service, workspace, original) = try await setup()
        defer { cleanup(root, managed) }
        let updated = original.replacingOccurrences(of: "line 3\n", with: "accepted\n")
        try change(updated, workspace: workspace)
        let review = try await service.review(workspace, project: root)
        #expect(!review.projectFiles.isEmpty)
        let base = try await service.apply(review, workspace: workspace, to: root)
        #expect(!base.isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("sample file.txt"), encoding: .utf8) == updated)
        #expect(try await git(["diff", "--cached", "--name-only"], root: root).isEmpty)
    }

    @Test func pathCanonicalizationStillRejectsEscapesThroughParentSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-boundary-\(UUID())")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("review-outside-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { cleanup(root, outside) }
        try Data("private".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(throws: AgentWorktreeError.self) { try AgentReviewFileState.capture("escape/secret.txt", root: root) }
        #expect(throws: AgentWorktreeError.self) { try AgentReviewFileState.capture("../outside.txt", root: root) }
    }

    @Test func newerProjectEditsBlockAnOldReviewWithoutLosingData() async throws {
        let (root, managed, service, workspace, original) = try await setup()
        defer { cleanup(root, managed) }
        try change(original.replacingOccurrences(of: "line 3\n", with: "agent\n"), workspace: workspace)
        let review = try await service.review(workspace, project: root)
        let hunk = try #require(review.hunks.first)
        let userText = original.replacingOccurrences(of: "line 25\n", with: "new user edit\n")
        try Data(userText.utf8).write(to: root.appendingPathComponent("sample file.txt"))
        await #expect(throws: AgentWorktreeError.self) { try await service.decide(.accept, hunkID: hunk.id, review: review, workspace: workspace, project: root) }
        #expect(try String(contentsOf: root.appendingPathComponent("sample file.txt"), encoding: .utf8) == userText)
        let refreshed = try await service.review(workspace, project: root)
        _ = try await service.decide(.accept, hunkID: try #require(refreshed.hunks.first).id, review: refreshed, workspace: workspace, project: root)
        #expect(try String(contentsOf: root.appendingPathComponent("sample file.txt"), encoding: .utf8) == userText.replacingOccurrences(of: "line 3\n", with: "agent\n"))
    }

    @Test func changingTheAgentProposalInvalidatesEarlierDecisions() async throws {
        let (root, managed, service, workspace, original) = try await setup()
        defer { cleanup(root, managed) }
        try change(original.replacingOccurrences(of: "line 3\n", with: "agent\n"), workspace: workspace)
        let review = try await service.review(workspace, project: root)
        let hunk = try #require(review.hunks.first)
        let newer = original.replacingOccurrences(of: "line 3\n", with: "new agent edit\n")
        try change(newer, workspace: workspace)
        await #expect(throws: AgentWorktreeError.self) { try await service.decide(.reject, hunkID: hunk.id, review: review, workspace: workspace, project: root) }
        #expect(try String(contentsOf: URL(fileURLWithPath: workspace.rootPath).appendingPathComponent("sample file.txt"), encoding: .utf8) == newer)
        #expect(try String(contentsOf: root.appendingPathComponent("sample file.txt"), encoding: .utf8) == original)
    }

    @Test func wholeFilesAndMissingFinalNewlinesArePreserved() async throws {
        let (root, managed, service, workspace, _) = try await setup()
        defer { cleanup(root, managed) }
        try change("new file without newline", workspace: workspace, path: "new file.txt")
        let review = try await service.review(workspace, project: root)
        let hunk = try #require(review.hunks.first { $0.path == "new file.txt" })
        #expect(hunk.wholeFile)
        let done = try await service.decide(.accept, hunkID: hunk.id, review: review, workspace: workspace, project: root)
        #expect(done.isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent("new file.txt")) == Data("new file without newline".utf8))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: workspace.rootPath).appendingPathComponent("new file.txt"))
        let deletion = try await service.review(workspace, project: root)
        let deleted = try #require(deletion.hunks.first)
        #expect(deleted.wholeFile)
        _ = try await service.decide(.reject, hunkID: deleted.id, review: deletion, workspace: workspace, project: root)
        #expect(try Data(contentsOf: URL(fileURLWithPath: workspace.rootPath).appendingPathComponent("new file.txt")) == Data("new file without newline".utf8))
    }

    @Test func binaryFilesUseOneWholeFileDecision() async throws {
        let (root, managed, service, workspace, _) = try await setup()
        defer { cleanup(root, managed) }
        let bytes = Data([0, 1, 2, 255, 0, 15])
        try bytes.write(to: URL(fileURLWithPath: workspace.rootPath).appendingPathComponent("asset.bin"))
        let review = try await service.review(workspace, project: root)
        let hunk = try #require(review.hunks.first)
        #expect(hunk.wholeFile && hunk.display.isBinary)
        _ = try await service.decide(.accept, hunkID: hunk.id, review: review, workspace: workspace, project: root)
        #expect(try Data(contentsOf: root.appendingPathComponent("asset.bin")) == bytes)
    }

    @Test func relatedGoTestsTargetPackagesNotIndividualSourceFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("go.mod"))
        #expect(ReviewTestScope.resolve(paths: ["api/handler.go", "api/handler_test.go"], root: root).targets == ["./api"])
        #expect(ReviewTestScope.resolve(paths: ["go.mod"], root: root).targets == ["./..."])
    }

    @Test func reviewTestsUseTheProjectPackageManagerAndRustRunner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"scripts":{"test":"vitest run"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        #expect(ReviewTestScope.resolve(paths: ["src/app.ts"], root: root).command == ["npm", "run", "test"])
        try Data().write(to: root.appendingPathComponent("pnpm-lock.yaml"))
        #expect(ReviewTestScope.resolve(paths: ["src/app.ts"], root: root).command == ["pnpm", "run", "test"])
        try Data().write(to: root.appendingPathComponent("Cargo.toml"))
        #expect(ReviewTestScope.resolve(paths: ["src/lib.rs"], root: root).command == ["cargo", "test"])
    }
}
