import Foundation
import MarikaCore

extension AppModel {
    var welcomeSuggestedAgent: AgentKind? {
        WelcomeChecklist.suggestedAgent(selected: welcomeAgent, statuses: statuses,
            claudeCredentialConfigured: workspace.preferences.claudeBilling != .apiKey || hasAnthropicAPIKey)
    }
    var welcomeChecklist: WelcomeChecklist {
        WelcomeChecklist(status: statuses[welcomeAgent], hasProject: selectedProject != nil,
            credentialConfigured: welcomeAgent != .claude || workspace.preferences.claudeBilling != .apiKey || hasAnthropicAPIKey)
    }

    func showWelcome() {
        openSpaceSection(.projects)
        welcomeAgent = selectedSession?.agent ?? workspace.preferences.defaultAgent
        showsWelcome = true
    }

    func selectWelcomeAgent(_ agent: AgentKind) {
        welcomeAgent = agent
        setPreferences { $0.defaultAgent = agent }
    }

    @discardableResult
    func finishWelcome(exploreOnly: Bool = false) async -> Bool {
        guard let project = selectedProject, exploreOnly || welcomeChecklist.isReady else { return false }
        if !exploreOnly, let meta = selectedSession {
            await open(meta.id)
            guard let controller = controllers[meta.id] else { return false }
            if controller.meta.agent != welcomeAgent {
                if controller.hasStarted {
                    // Getting Started can be reopened with an existing conversation.
                    // Keep its provider and history; start a separate chat for the new choice.
                    let fresh = newSession(in: project, agent: welcomeAgent)
                    await open(fresh.id)
                    guard let freshController = controllers[fresh.id] else { return false }
                    freshController.requestAgentSwitch(to: welcomeAgent)
                } else { controller.requestAgentSwitch(to: welcomeAgent) }
            }
        }
        setPreferences { $0.welcomeCompleted = true }
        showsWelcome = false
        openProject(project, tab: exploreOnly ? .code : .conversation)
        if exploreOnly { editor(for: project).focusEditor() }
        else { composerFocusRequest = UUID() }
        return true
    }
}
