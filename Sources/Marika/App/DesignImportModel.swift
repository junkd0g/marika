import Foundation
import MarikaCore
import Observation

@MainActor @Observable final class DesignImportModel {
    let projectID: UUID
    @ObservationIgnored weak var app: AppModel?
    var files: [DesignImportFile] = []
    var selected: Set<String> = []
    var filter = ""
    var focus = ""
    var agent: AgentKind
    var modelID = ""
    var loading = false
    var working = false
    var error: String?

    init(projectID: UUID, app: AppModel) {
        self.projectID = projectID; self.app = app
        let previous = app.project(id: projectID)?.designImport
        let session = previous.flatMap { run in app.workspace.sessions.first { $0.id == run.sessionID } } ?? app.selectedSession
        agent = previous?.agent ?? session?.agent ?? app.workspace.preferences.defaultAgent
        if session?.agent == agent { modelID = session?.model ?? "" }
        selected = Set(previous?.files.map(\.path) ?? [])
    }

    var run: DesignImportRun? { app?.project(id: projectID)?.designImport }
    var controller: SessionController? { run.flatMap { app?.controllers[$0.sessionID] } }
    var models: [ModelOption] { app?.capabilities[agent]?.models ?? [] }
    var visibleFiles: [DesignImportFile] { files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) } }
    var frameworks: String { Array(Set(files.filter { selected.contains($0.path) }.map(\.framework))).sorted().joined(separator: " · ") }

    func load() async {
        guard let app, let project = app.project(id: projectID) else { error = "Project unavailable."; return }
        loading = true; defer { loading = false }
        do {
            guard project.runtime == nil else { throw DesignToolError("Import is available for local project files.") }
            files = try await DesignImportSources.discover(at: project.url)
            if selected.isEmpty { selected = Set(files.prefix(24).map(\.path)) }
            selected.formIntersection(Set(files.map(\.path)))
            await app.resumeDesignImport(projectID: projectID)
        } catch { self.error = error.localizedDescription }
    }

    func generate() async {
        guard let app else { return }
        error = nil; working = true; defer { working = false }
        do { try await app.startDesignImport(projectID: projectID, paths: selected.sorted(), focus: focus, agent: agent, model: modelID.isEmpty ? nil : modelID) }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    func apply() async -> Bool {
        guard let app else { return false }
        error = nil; working = true; defer { working = false }
        do { try await app.applyDesignImport(projectID: projectID); return true }
        catch { self.error = error.localizedDescription; return false }
    }

    func startOver() { app?.clearDesignImport(projectID: projectID); error = nil }
    func stop() { app?.stopDesignImport(projectID: projectID) }
    func openConversation() { if let run { app?.openAgentChat(run.sessionID) } }
}
