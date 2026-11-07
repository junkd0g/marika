import AppKit
import MarikaCore

extension AppModel {
    func chatUnreadCount(_ id: UUID) -> Int {
        guard let controller = controllers[id], let project = project(for: controller.meta) else { return 0 }
        return ProjectChat.unreadCount(in: controller.items, since: project.chatReadDates?[id.uuidString])
    }

    func markChatRead(_ id: UUID) {
        guard let controller = controllers[id], let project = project(for: controller.meta) else { return }
        guard project.chatReadDates?[id.uuidString] == nil || chatUnreadCount(id) > 0 else { return }
        updateProject(project.id) { project in
            if project.chatReadDates == nil { project.chatReadDates = [:] }
            project.chatReadDates?[id.uuidString] = Date()
        }
    }

    func canMessage(_ agent: AgentKind) -> Bool {
        #if DEBUG
            if agentFactoryOverride != nil { return true }
        #endif
        switch statuses[agent]?.readiness {
        case .notInstalled, .signedOut, .unavailable: return false
        default: return true
        }
    }

    /// Route a leading mention without consuming the recipient's own saved draft.
    func sendChatMention(_ input: UserInput, from sourceID: UUID) async throws {
        guard let source = controllers[sourceID],
              workspace.sessions.contains(where: { $0.id == sourceID }),
              let routed = try ProjectChat.route(input.text, in: source.meta.projectID, sessions: workspace.sessions)
        else { throw AgentError.launchFailed("Choose an agent with @ before sending.") }
        await open(routed.sessionID)
        guard let target = controllers[routed.sessionID],
              workspace.sessions.contains(where: { $0.id == routed.sessionID && $0.projectID == source.meta.projectID })
        else { throw AgentError.launchFailed("Couldn't open this agent's saved chat. Your draft has been kept.") }
        guard target.meta.agentTask?.workspace?.status != .discarded else { throw ProjectChat.RoutingError.discardedAgent }
        guard canMessage(target.meta.agent) else {
            throw AgentError.launchFailed("Set up \(target.meta.agent.shortName) in Settings before messaging this agent.")
        }
        guard target.pendingApproval == nil else {
            throw AgentError.launchFailed("This agent is waiting for approval. Open its chat to respond first.")
        }
        target.send(UserInput(text: routed.text, images: input.images))
        if source.draft.trimmingCharacters(in: .whitespacesAndNewlines) == input.text,
            source.draftImages == input.images {
            source.draft = ""
            source.draftImages = []
        }
        openAgentChat(target.id)
    }
}
