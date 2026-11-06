import Foundation
import Testing
@testable import MarikaCore

struct AgentTaskTests {
    @Test func childrenInheritPermissionsWithoutReceivingAnotherProvidersModel() {
        var parent = SessionMeta(projectID: UUID(), agent: .claude, model: "claude-model", effort: "high", mode: .plan)
        #expect(AgentTaskPolicy.childSettings(agent: .claude, parent: parent) == parent.settings)
        let other = AgentTaskPolicy.childSettings(agent: .codex, parent: parent)
        #expect(other.mode == .plan)
        #expect(other.model == nil)
        #expect(other.effort == nil)
        parent.mode = .ask
        #expect(AgentTaskPolicy.childSettings(agent: .codex, parent: parent, model: "codex-model").model == "codex-model")
        #expect(AgentTaskPolicy.childSettings(agent: .codex, parent: parent).mode == .ask)
    }

    @Test func aChatCanOnlyAccessItsOwnDescendantsInTheSameProject() {
        let project = UUID()
        let parent = SessionMeta(projectID: project, agent: .codex)
        let child = SessionMeta(projectID: project, agent: .claude, agentTask: AgentTask(prompt: "Review", parentSessionID: parent.id))
        let grandchild = SessionMeta(projectID: project, agent: .codex, agentTask: AgentTask(prompt: "Test", parentSessionID: child.id))
        let unrelated = SessionMeta(projectID: project, agent: .codex, agentTask: AgentTask(prompt: "Unrelated"))
        let otherProject = SessionMeta(projectID: UUID(), agent: .codex, agentTask: AgentTask(prompt: "Other", parentSessionID: parent.id))
        let sessions = [parent, child, grandchild, unrelated, otherProject]
        #expect(AgentTaskPolicy.isDescendant(child, of: parent, sessions: sessions))
        #expect(AgentTaskPolicy.isDescendant(grandchild, of: parent, sessions: sessions))
        #expect(!AgentTaskPolicy.isDescendant(parent, of: parent, sessions: sessions))
        #expect(!AgentTaskPolicy.isDescendant(unrelated, of: parent, sessions: sessions))
        #expect(!AgentTaskPolicy.isDescendant(otherProject, of: parent, sessions: sessions))
        #expect(!AgentTaskPolicy.isDescendant(parent, of: child, sessions: sessions))
    }

    @Test func activeLimitsAndDepthPreventUnboundedSpawning() throws {
        let project = UUID()
        var parent = SessionMeta(projectID: project, agent: .codex)
        var sessions = [parent]
        for _ in 0..<AgentTaskPolicy.maxDepth {
            let child = SessionMeta(projectID: project, agent: .codex, agentTask: AgentTask(prompt: "Child", parentSessionID: parent.id))
            sessions.append(child)
            parent = child
        }
        #expect(throws: (any Error).self) {
            try AgentTaskPolicy.validateLaunch(in: project, parent: parent, sessions: sessions, active: [])
        }
        let workers = (0..<AgentTaskPolicy.maxConcurrent).map { _ in
            SessionMeta(projectID: project, agent: .codex, agentTask: AgentTask(prompt: "Work"))
        }
        #expect(throws: (any Error).self) {
            try AgentTaskPolicy.validateLaunch(in: project, parent: nil, sessions: workers, active: Set(workers.map(\.id)))
        }
        try AgentTaskPolicy.validateLaunch(in: project, parent: nil, sessions: workers, active: [workers[0].id])
        try AgentTaskPolicy.validateLaunch(in: UUID(), parent: nil, sessions: workers, active: Set(workers.map(\.id)))
    }

    @Test func taskMetadataRoundTripsAndOlderChatsStillDecode() throws {
        let meta = SessionMeta(projectID: UUID(), agent: .claude,
            agentTask: AgentTask(prompt: "Check the UI", parentSessionID: UUID()))
        let encoded = try JSONEncoder().encode(meta)
        #expect(try JSONDecoder().decode(SessionMeta.self, from: encoded) == meta)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "agentTask")
        let decoded = try JSONDecoder().decode(SessionMeta.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.agentTask == nil)
        #expect(decoded.id == meta.id)
    }
}
