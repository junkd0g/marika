import Foundation
import Testing
@testable import MarikaCore

struct ProjectExperienceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func rewindHandlesAddsDeletesAndPreservesTheGitIndex() async throws {
        let root = try fixture(), storage = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: storage) }
        _ = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["init", root.path])
        let file = root.appendingPathComponent("file.swift"), deleted = root.appendingPathComponent("deleted.txt")
        try "baseline".write(to: file, atomically: true, encoding: .utf8)
        try "deleted".write(to: deleted, atomically: true, encoding: .utf8)
        _ = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path, "add", "."])
        try "user edit".write(to: file, atomically: true, encoding: .utf8)
        let service = Checkpoints(directory: storage)
        let project = UUID()
        let checkpoint = try await service.begin(projectID: project, sessionID: UUID(), title: "Fix", roots: [root])
        try "agent edit".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: deleted)
        let added = root.appendingPathComponent("added.txt")
        try "new".write(to: added, atomically: true, encoding: .utf8)
        let finished = try await service.finish(checkpoint.id)
        #expect(finished.changedPaths.count == 3)
        _ = try await service.restore(checkpoint.id)
        #expect(try String(contentsOf: file, encoding: .utf8) == "user edit")
        #expect(try String(contentsOf: deleted, encoding: .utf8) == "deleted")
        #expect(!FileManager.default.fileExists(atPath: added.path))
        let indexed = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path, "show", ":file.swift"])
        #expect(indexed.output == "baseline")
        #expect(try await service.list(projectID: project).first?.restoredAt != nil)
    }
    @Test func staleCheckpointAndSymlinksCannotOverwriteNewerWork() async throws {
        let root = try fixture(), storage = try fixture(), outside = try fixture()
        defer { for url in [root, storage, outside] { try? FileManager.default.removeItem(at: url) } }
        let file = root.appendingPathComponent("main.txt")
        let other = root.appendingPathComponent("other.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        try "before".write(to: other, atomically: true, encoding: .utf8)
        let service = Checkpoints(directory: storage)
        let checkpoint = try await service.begin(projectID: UUID(), sessionID: UUID(), title: "Fix", roots: [root])
        for url in [file, other] { try "agent".write(to: url, atomically: true, encoding: .utf8) }
        _ = try await service.finish(checkpoint.id)
        try "newer user work".write(to: other, atomically: true, encoding: .utf8)
        await #expect(throws: AgentError.self) { try await service.restore(checkpoint.id) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "agent")
        try FileManager.default.removeItem(at: other)
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: outside.appendingPathComponent("escape.txt"))
        await #expect(throws: AgentError.self) { try await service.restore(checkpoint.id) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
    }
    @Test func multipleRootsAndIgnoredFilesHaveExplicitCoverage() async throws {
        let first = try fixture(), second = try fixture(), storage = try fixture()
        defer { for url in [first, second, storage] { try? FileManager.default.removeItem(at: url) } }
        _ = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["init", first.path])
        try "cache/".write(to: first.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: first.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try "ignored".write(to: first.appendingPathComponent("cache/file"), atomically: true, encoding: .utf8)
        try "api".write(to: first.appendingPathComponent("api.go"), atomically: true, encoding: .utf8)
        try "web".write(to: second.appendingPathComponent("web.ts"), atomically: true, encoding: .utf8)
        let service = Checkpoints(directory: storage)
        let record = try await service.begin(projectID: UUID(), sessionID: UUID(), title: "Across repos", roots: [first, second])
        #expect(record.before.count == 3)
        #expect(!record.before.keys.contains { $0.contains("cache/file") })
        #expect(record.roots.count == 2)
    }
    @Test func workspaceSettingsRemainBackwardsCompatibleAndRemoteCommandsAreQuoted() throws {
        let old = #"{"setupCommand":"","actions":[],"skills":[],"mcpConfig":"{\"mcpServers\":{}}","schedules":[]}"#
        #expect(try JSONDecoder().decode(ProjectTools.self, from: Data(old.utf8)).memory == nil)
        let remote = RemoteMachine(name: "Build", host: "dev@builder", directory: "/srv/some project's code")
        let args = try remote.arguments()
        #expect(args.contains("dev@builder"))
        #expect(args.last?.contains("'\\''") == true)
        #expect(throws: AgentError.self) { try RemoteMachine(name: "Bad", host: "-oProxyCommand=bad", directory: "/src").arguments() }
        #expect(throws: AgentError.self) { try RemoteMachine(name: "Bad", host: "host;bad", directory: "/src").arguments() }
        var project = Project(path: "/one")
        project.repositoryPaths = ["/two"]; project.selectedRepositoryPath = "/two"
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(restored.editorURL.path == "/two")
        #expect(restored.url.path == "/one")
    }
    @Test func completionRejectsProseAndBoundsInsertion() throws {
        #expect(try CodeCompletion.insertion(from: #"{"insert":"return value\n"}"#) == "return value\n")
        #expect(throws: (any Error).self) { try CodeCompletion.insertion(from: "Here is your code") }
        #expect(throws: AgentError.self) { try CodeCompletion.insertion(from: "{\"insert\":\"" + String(repeating: "x", count: 4001) + "\"}") }
        let prompt = CodeCompletion.prompt(path: "x.swift", text: "🦊return", offset: 2)
        #expect(prompt.contains("🦊\n<CURSOR>\nCode after cursor:\nreturn"))
    }
    @Test func completionReadsTheAgentsFinishedResponse() async throws {
        let result = try await CodeCompletion.request(agent: CompletionAgent(), prompt: "complete")
        #expect(result == "return value")
    }
    @Test func typescriptOpensAsSourceInsteadOfVideo() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "export const value = 42;".write(to: root.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)
        switch try await ProjectFiles(root: root).open("index.ts") {
        case .text(let file): #expect(file.text.contains("value = 42"))
        case .preview: Issue.record("TypeScript was mistaken for a video transport stream")
        }
    }
    @Test func artifactsValidateContentAndKeepReviewAnchors() throws {
        var artifact = try ProjectArtifact.validated(sessionID: UUID(), title: "Plan", kind: "Plan", body: "First line\nSecond line")
        artifact.comments = [ArtifactComment(line: 2, text: "Add a regression check")]
        let restored = try JSONDecoder().decode(ProjectArtifact.self, from: JSONEncoder().encode(artifact))
        #expect(restored.feedback.contains("Line 2: Second line"))
        #expect(restored.feedback.contains("Add a regression check"))
        #expect(throws: AgentError.self) { try ProjectArtifact.validated(sessionID: UUID(), title: "Fake screenshot", kind: "Browser evidence", body: "test") }
        #expect(throws: AgentError.self) { try ProjectArtifact.validated(sessionID: UUID(), title: " ", kind: "Plan", body: "test") }
    }
}

private actor CompletionAgent: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>
    private let sink: AsyncStream<AgentEvent>.Continuation
    init() { (events, sink) = AsyncStream.makeStream() }
    func send(_ input: UserInput) async throws {
        sink.yield(.textFinished(id: "completion", text: #"{"insert":"return value"}"#, parentToolID: nil))
        sink.yield(.turnFinished(TurnSummary(outcome: .completed)))
    }
    func hasActiveTurn() async -> Bool { false }
    func interrupt() async {}
    func answer(requestID: String, decision: ApprovalDecision) async {}
    func update(settings: AgentSettings) async {}
    func shutdown() async { sink.finish() }
}
