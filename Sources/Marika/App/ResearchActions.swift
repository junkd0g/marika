import Foundation
import MarikaCore

extension AppModel {
    func launchResearch(question: String, focus: ResearchFocus, agent: AgentKind, project: Project) async throws -> ResearchRun {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 6000 else { throw AgentError.launchFailed("Write a research question under 6,000 characters.") }
        let id = UUID()
        let controller = try await launchAgent(in: project, agent: agent, settings: AgentSettings(mode: .plan),
            prompt: ResearchRun.prompt(question: question, focus: focus, id: id), isolated: false,
            name: String(("Research: " + question).prefix(80)))
        let run = ResearchRun(id: id, sessionID: controller.id, question: question, focus: focus)
        let active = Set(controllers.values.filter(\.isBusy).map(\.id))
        updateProject(project.id) { $0.research = ResearchRun.retained(($0.research ?? []) + [run], active: active) }
        return run
    }

    func publishResearch(id: UUID, report: String, callerID: UUID, projectID: UUID) throws {
        guard var run = project(id: projectID)?.research?.first(where: { $0.id == id }), run.sessionID == callerID else {
            throw AgentError.launchFailed("Publish only to the Research run assigned to this chat.")
        }
        try run.publish(report, callerID: callerID)
        updateProject(projectID) { current in
            guard let index = current.research?.firstIndex(where: { $0.id == id && $0.sessionID == callerID }) else { return }
            current.research?[index].report = run.report
        }
    }
}
