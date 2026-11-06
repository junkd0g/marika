import Foundation
import Testing

@testable import MarikaCore

struct ProjectConversationTests {
    @Test func oldProjectsDecodeWithoutAConversationSelection() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"name\":\"Studio\",\"path\":\"/tmp/studio\"}".utf8)
        let project = try JSONDecoder().decode(Project.self, from: data)
        #expect(project.id == id)
        #expect(project.conversationSessionID == nil)
    }

    @Test func projectConversationExcludesTaskAgentsAndOtherProjects() {
        let first = Project(path: "/tmp/first")
        let second = Project(path: "/tmp/second")
        let conversation = SessionMeta(projectID: first.id, agent: .codex, updatedAt: Date(timeIntervalSince1970: 1))
        let task = SessionMeta(projectID: first.id, agent: .claude, updatedAt: Date(timeIntervalSince1970: 3),
                               agentTask: AgentTask(prompt: "Review code"))
        let other = SessionMeta(projectID: second.id, agent: .codex, updatedAt: Date(timeIntervalSince1970: 4))
        var workspace = Workspace(projects: [first, second], sessions: [conversation, task, other])
        #expect(workspace.conversation(for: first.id)?.id == conversation.id)
        workspace.projects[0].conversationSessionID = other.id
        #expect(workspace.conversation(for: first.id)?.id == conversation.id)
        workspace.projects[0].conversationSessionID = task.id
        #expect(workspace.conversation(for: first.id)?.id == conversation.id)
    }

    @Test func selectedConversationSurvivesSavingAndNewerHistory() throws {
        var project = Project(path: "/tmp/studio")
        let selected = SessionMeta(projectID: project.id, agent: .codex, updatedAt: Date(timeIntervalSince1970: 1))
        let newer = SessionMeta(projectID: project.id, agent: .claude, updatedAt: Date(timeIntervalSince1970: 2))
        project.conversationSessionID = selected.id
        let workspace = Workspace(projects: [project], sessions: [selected, newer])
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(restored.conversation(for: project.id)?.id == selected.id)
        #expect(restored.sessions.count == 2)
    }
}
