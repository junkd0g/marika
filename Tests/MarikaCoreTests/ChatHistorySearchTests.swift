import Foundation
import Testing
@testable import MarikaCore

private func historyTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-history-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

struct ChatHistorySearchTests {
    @Test func searchesAcrossProjectsAndProvidersAndReturnsStableMessageDestinations() async throws {
        let root = try historyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let alpha = Project(path: "/tmp/alpha"), beta = Project(path: "/tmp/beta")
        let codex = SessionMeta(projectID: alpha.id, agent: .codex, title: "Investigate login")
        let claude = SessionMeta(projectID: beta.id, agent: .claude, title: "Review routing")
        try await store.saveTranscript([
            TranscriptItem(id: "same-id", date: Date(timeIntervalSince1970: 10), content: .user(text: "Fix the login redirect", images: []))
        ], for: codex.id)
        try await store.saveTranscript([
            TranscriptItem(id: "same-id", date: Date(timeIntervalSince1970: 20), content: .assistant(text: "The login redirect is fixed."))
        ], for: claude.id)
        let workspace = Workspace(projects: [alpha, beta], sessions: [codex, claude])
        let found = try await store.searchChatHistory(in: workspace, query: "LOGIN redirect")
        #expect(found.matches.map(\.sessionID) == [claude.id, codex.id])
        #expect(found.matches.map(\.projectID) == [beta.id, alpha.id])
        #expect(Set(found.matches.map(\.id)).count == 2)
        #expect(found.matches.map(\.itemID) == ["same-id", "same-id"])
        #expect(found.matches.map(\.speaker) == [.assistant, .user])
        #expect(found.totalMatches == 2 && found.unreadableConversations == 0)
        let scoped = try await store.searchChatHistory(in: workspace, query: "login", projectID: alpha.id)
        #expect(scoped.matches.map(\.sessionID) == [codex.id])
    }

    @Test func liveTranscriptsReplaceSavedContentsIncludingAnEmptyLiveConversation() async throws {
        let root = try historyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root), project = Project(path: "/tmp/project")
        let session = SessionMeta(projectID: project.id, agent: .codex)
        let workspace = Workspace(projects: [project], sessions: [session])
        try await store.saveTranscript([TranscriptItem(id: "old", content: .assistant(text: "needle old"))], for: session.id)
        let live = [TranscriptItem(id: "new", content: .assistant(text: "needle unsaved"))]
        let found = try await store.searchChatHistory(in: workspace, query: "needle", liveTranscripts: [session.id: live])
        #expect(found.matches.map(\.itemID) == ["new"])
        let empty = try await store.searchChatHistory(in: workspace, query: "needle", liveTranscripts: [session.id: []])
        #expect(empty.matches.isEmpty)
        #expect(try await store.loadTranscript(session.id).map(\.id) == ["old"])
    }

    @Test func onlyVisibleMessagesMatchAndSnippetsHandleUnicodeAndDiacritics() throws {
        let project = Project(path: "/tmp/project"), session = SessionMeta(projectID: UUID(), agent: .claude)
        let text = String(repeating: "👩🏽‍💻 ", count: 150) + "RéSUMÉ compiler\nfound a bug " + String(repeating: "x", count: 400)
        let items = [
            TranscriptItem(id: "visible", content: .assistant(text: text)),
            TranscriptItem(id: "child", parentToolID: "agent", content: .assistant(text: "resume compiler")),
            TranscriptItem(id: "thinking", content: .thinking(text: "resume compiler", durationMs: nil)),
            TranscriptItem(id: "notice", content: .notice(Notice(level: .info, text: "resume compiler"))),
            TranscriptItem(id: "tool", content: .tool(ToolCall(id: "t", name: "shell", kind: .shell, title: "resume compiler", detail: "", output: "resume compiler")))
        ]
        let found = try ChatHistorySearch.matches(in: items, session: session, project: project, query: "  resume  COMPILER ")
        #expect(found.matches.map(\.itemID) == ["visible"])
        let snippet = try #require(found.matches.first?.snippet)
        #expect(snippet.contains("RéSUMÉ compiler found"))
        #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…") && snippet.count < 250)
        #expect(try ChatHistorySearch.matches(in: items, session: session, project: project, query: "compiler missing").matches.isEmpty)
    }

    @Test func resultsAreBoundedAndCountAllMatchesEvenWithUnorderedDates() async throws {
        let root = try historyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root), project = Project(path: "/tmp/project")
        let one = SessionMeta(projectID: project.id, agent: .codex), two = SessionMeta(projectID: project.id, agent: .claude)
        for session in [one, two] {
            let items = (0..<1000).reversed().map {
                TranscriptItem(id: String($0), date: Date(timeIntervalSince1970: Double($0)), content: .assistant(text: "needle \($0)"))
            }
            try await store.saveTranscript(items, for: session.id)
        }
        let found = try await store.searchChatHistory(in: Workspace(projects: [project], sessions: [one, two]), query: "needle", limit: 7)
        #expect(found.matches.count == 7 && found.totalMatches == 2000)
        #expect(found.matches.map { Int($0.date.timeIntervalSince1970) } == [999, 999, 998, 998, 997, 997, 996])
    }

    @Test func unreadableConversationsDoNotHideOtherResultsAndBackupsAreReadWithoutRepair() async throws {
        let root = try historyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root), project = Project(path: "/tmp/project")
        let saved = SessionMeta(projectID: project.id, agent: .codex), broken = SessionMeta(projectID: project.id, agent: .claude)
        try await store.saveTranscript([TranscriptItem(id: "backup", content: .assistant(text: "needle"))], for: saved.id)
        let original = root.appendingPathComponent("transcripts/\(saved.id.uuidString).json")
        try Data("broken".utf8).write(to: original)
        try Data("broken".utf8).write(to: root.appendingPathComponent("transcripts/\(broken.id.uuidString).json"))
        let before = try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path).sorted()
        let found = try await store.searchChatHistory(in: Workspace(projects: [project], sessions: [saved, broken]), query: "needle")
        #expect(found.matches.map(\.itemID) == ["backup"] && found.unreadableConversations == 1)
        #expect(try String(contentsOf: original, encoding: .utf8) == "broken")
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path).sorted() == before)
    }

    @Test func blankQueriesUnknownProjectsAndOrphanedSessionsReturnNoMessages() async throws {
        let root = try historyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root), session = SessionMeta(projectID: UUID(), agent: .codex)
        let workspace = Workspace(sessions: [session])
        let live = [session.id: [TranscriptItem(id: "orphan", content: .assistant(text: "needle"))]]
        let orphan = try await store.searchChatHistory(in: workspace, query: "needle", liveTranscripts: live)
        let blank = try await store.searchChatHistory(in: workspace, query: " \n\t ", liveTranscripts: live)
        #expect(orphan.matches.isEmpty && blank.matches.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("transcripts").path))
    }

    @Test func cancelledSearchDoesNotReturnPartialOrMisleadingResults() async throws {
        let root = try historyTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root), project = Project(path: "/tmp/project")
        let session = SessionMeta(projectID: project.id, agent: .codex)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.searchChatHistory(in: Workspace(projects: [project], sessions: [session]), query: "needle")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
