import Foundation
import Testing
@testable import MarikaCore

struct ProjectChatTests {
    @Test func chatSelectionPersistsWithoutChangingTheMainConversation() throws {
        var project = Project(path: "/tmp/studio")
        let main = SessionMeta(projectID: project.id, agent: .codex)
        let agent = SessionMeta(projectID: project.id, agent: .claude, agentTask: AgentTask(prompt: "Review"))
        project.conversationSessionID = main.id
        project.chatSessionID = agent.id
        project.chatReadDates = [agent.id.uuidString: Date(timeIntervalSince1970: 42)]
        let workspace = Workspace(projects: [project], sessions: [main, agent])
        let saved = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(saved.chat(for: project.id)?.id == agent.id)
        #expect(saved.conversation(for: project.id)?.id == main.id)
        #expect(saved.projects[0].chatReadDates?[agent.id.uuidString] == Date(timeIntervalSince1970: 42))
    }

    @Test func chatSelectionRejectsOtherProjectsAndDeletedSessions() {
        var project = Project(path: "/tmp/a")
        let other = Project(path: "/tmp/b")
        let main = SessionMeta(projectID: project.id, agent: .codex)
        let foreign = SessionMeta(projectID: other.id, agent: .codex, agentTask: AgentTask(prompt: "Other task"))
        project.chatSessionID = foreign.id
        var workspace = Workspace(projects: [project, other], sessions: [main, foreign])
        #expect(workspace.chat(for: project.id)?.id == main.id)
        workspace.projects[0].chatSessionID = UUID()
        #expect(workspace.chat(for: project.id)?.id == main.id)
    }

    @Test func mentionsAreProjectScopedAndStripOnlyTheAddress() throws {
        let project = UUID()
        var agent = SessionMeta(projectID: project, agent: .codex, agentTask: AgentTask(prompt: "Review"))
        let other = SessionMeta(projectID: UUID(), agent: .codex, agentTask: AgentTask(prompt: "Other"))
        let address = ProjectChat.handle(for: agent)
        agent.title = "A new title"
        #expect(ProjectChat.handle(for: agent) == address)
        let sessions = [agent, other]
        let result = try ProjectChat.route("  @\(address.uppercased()) Please review\nthis diff @claude  ", in: project, sessions: sessions)
        #expect(result?.sessionID == agent.id)
        #expect(result?.text == "Please review\nthis diff @claude")
        #expect(try ProjectChat.route("Ask @codex for a review", in: project, sessions: sessions) == nil)
        #expect(try ProjectChat.route("@codex hi", in: project, sessions: sessions)?.sessionID == agent.id)
        #expect(throws: ProjectChat.RoutingError.self) { try ProjectChat.route("@\(ProjectChat.handle(for: other)) hi", in: project, sessions: sessions) }
    }

    @Test func ambiguousOrInvalidRecipientsDoNotSilentlySend() throws {
        let project = UUID()
        var first = SessionMeta(projectID: project, agent: .codex, agentTask: AgentTask(prompt: "First"))
        let second = SessionMeta(projectID: project, agent: .codex, agentTask: AgentTask(prompt: "Second"))
        #expect(throws: ProjectChat.RoutingError.ambiguousAgent("codex")) { try ProjectChat.route("@codex hi", in: project, sessions: [first, second]) }
        #expect(throws: ProjectChat.RoutingError.emptyMessage) { try ProjectChat.route("@codex", in: project, sessions: [first]) }
        first.agentTask?.workspace = AgentWorkspace(rootPath: "/tmp", workingPath: "/tmp/task", branch: "task", baseCommit: "abc")
        first.agentTask?.workspace?.status = .discarded
        #expect(throws: ProjectChat.RoutingError.discardedAgent) { try ProjectChat.route("@codex hi", in: project, sessions: [first]) }
        #expect(ProjectChat.agents(in: project, sessions: [first, second]).map(\.id) == [second.id])
    }

    @Test func unreadCountsOnlyNewRootReplies() {
        let before = Date(timeIntervalSince1970: 1), after = Date(timeIntervalSince1970: 3)
        let items = [
            TranscriptItem(id: "old", date: before, content: .assistant(text: "Old reply")),
            TranscriptItem(id: "user", date: after, content: .user(text: "Question", images: [])),
            TranscriptItem(id: "new", date: after, content: .assistant(text: "New reply")),
            TranscriptItem(id: "child", date: after, parentToolID: "tool", content: .assistant(text: "Internal")),
            TranscriptItem(id: "empty", date: after, content: .assistant(text: "  "))
        ]
        #expect(ProjectChat.unreadCount(in: items, since: Date(timeIntervalSince1970: 2)) == 1)
        #expect(ProjectChat.unreadCount(in: items, since: after) == 0)
        #expect(ProjectChat.unreadCount(in: items, since: nil) == 0)
    }

    @Test func aReplyThatFinishesStreamingAfterLeavingTheChatIsUnread() {
        let items = [
            TranscriptItem(id: "reply", date: Date(timeIntervalSince1970: 1), content: .assistant(text: "Finished reply")),
            TranscriptItem(id: "end", date: Date(timeIntervalSince1970: 3), content: .turnEnd(TurnSummary(outcome: .completed)))
        ]
        #expect(ProjectChat.unreadCount(in: items, since: Date(timeIntervalSince1970: 2)) == 1)
        #expect(ProjectChat.unreadCount(in: items, since: Date(timeIntervalSince1970: 3)) == 0)
        #expect(ProjectChat.unreadCount(in: items, since: Date(timeIntervalSince1970: 0)) == 1)
    }
}
