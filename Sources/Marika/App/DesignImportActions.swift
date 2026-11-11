import Foundation
import MarikaCore

extension AppModel {
    func startDesignImport(projectID: UUID, paths: [String], focus: String, agent: AgentKind, model: String?) async throws {
        guard let project = project(id: projectID), project.runtime == nil else { throw DesignToolError("Open a local project to import its interface.") }
        guard project.designImport?.isActive != true else { throw DesignToolError("A design import is already running.") }
        let run = DesignImportRun(projectPath: project.path, agent: agent)
        preparingDesignImports.insert(run.id)
        defer { preparingDesignImports.remove(run.id) }
        updateProject(projectID) { $0.designImport = run }
        do {
            let snapshot = try await DesignImportSources.capture(paths, at: project.url)
            let prompt = try DesignImportPrompt.make(snapshot: snapshot, focus: focus)
            try await DesignImportSources.stage(snapshot, id: run.id)
            guard self.project(id: projectID)?.designImport?.id == run.id,
                  self.project(id: projectID)?.path == project.path,
                  self.project(id: projectID)?.designImport?.status == .preparing else { throw CancellationError() }
            updateDesignImport(projectID, id: run.id) { $0.files = snapshot.files; $0.status = .running }
            _ = try await launchAgent(in: project, agent: agent, settings: AgentSettings(model: model, mode: .plan), prompt: prompt,
                isolated: false, name: "Import UI design", sessionID: run.sessionID, designImportID: run.id)
        } catch {
            await DesignImportSources.discardStage(id: run.id)
            updateDesignImport(projectID, id: run.id) {
                if $0.status != .cancelled { $0.status = .failed; $0.error = error.localizedDescription }
            }
            throw error
        }
    }

    func finishDesignImport(_ session: SessionController) async {
        guard let project = project(for: session.meta), let run = project.designImport,
              run.id == session.meta.agentTask?.designImportID, run.sessionID == session.id, run.status == .running else { return }
        do {
            let turn = session.items.reversed().prefix { if case .user = $0.content { false } else { true } }
            let outcome = turn.compactMap { item -> TurnSummary.Outcome? in if case .turnEnd(let summary) = item.content { return summary.outcome }; return nil }.first
            guard outcome == .completed else { throw DesignToolError("The analysis stopped before finishing. Open its conversation for details or try again.") }
            let response = turn.compactMap { item -> String? in
                if item.parentToolID == nil, case .assistant(let text) = item.content { return text }; return nil
            }.first ?? ""
            let proposal = try DesignImportProposal.parse(response, files: run.files)
            try await DesignImportSources.verify(run.files, at: project.url)
            updateDesignImport(project.id, id: run.id) {
                guard $0.status == .running else { return }
                $0.proposal = proposal; $0.status = .ready; $0.error = nil
            }
        } catch {
            updateDesignImport(project.id, id: run.id) {
                guard $0.status == .running else { return }
                $0.status = .failed; $0.error = error.localizedDescription
            }
        }
        await DesignImportSources.discardStage(id: run.id)
    }

    func resumeDesignImport(projectID: UUID) async {
        guard let run = project(id: projectID)?.designImport else { return }
        guard run.isActive else { await DesignImportSources.discardStage(id: run.id); return }
        if preparingDesignImports.contains(run.id) { return }
        if run.status == .preparing {
            updateDesignImport(projectID, id: run.id) { $0.status = .failed; $0.error = "Import preparation was interrupted. Try again." }
            await DesignImportSources.discardStage(id: run.id)
            return
        }
        await open(run.sessionID)
        if let controller = controllers[run.sessionID], !controller.isBusy { await finishDesignImport(controller) }
        else if controllers[run.sessionID] == nil {
            updateDesignImport(projectID, id: run.id) { $0.status = .failed; $0.error = "The import conversation is unavailable. Start a new import." }
            await DesignImportSources.discardStage(id: run.id)
        }
    }

    func stopDesignImport(projectID: UUID) {
        guard let run = project(id: projectID)?.designImport, run.isActive else { return }
        updateDesignImport(projectID, id: run.id) { $0.status = .cancelled; $0.error = nil }
        controllers[run.sessionID]?.interrupt()
        Task { await DesignImportSources.discardStage(id: run.id) }
    }

    func applyDesignImport(projectID: UUID) async throws {
        guard let project = project(id: projectID), let run = project.designImport,
              run.status == .ready, let proposal = run.proposal, run.projectPath == project.path else { throw DesignToolError("No reviewed design is ready to import.") }
        try await DesignImportSources.verify(run.files, at: project.url)
        guard self.project(id: projectID)?.designImport?.id == run.id,
              self.project(id: projectID)?.path == project.path,
              self.project(id: projectID)?.designImport?.status == .ready else { throw DesignToolError("This import changed. Open the current draft again.") }
        let editor = design(for: project)
        let merged = try proposal.appending(to: editor.document)
        try saveDesignVersion(projectID: projectID, name: "Before importing UI design")
        editor.edit { $0 = merged.document }
        updateDesignImport(projectID, id: run.id) { $0.status = .applied; $0.proposal = nil }
        if let canvas = designCanvases[projectID] {
            canvas.selection = [merged.selection]; canvas.selectedConnection = nil; canvas.fitSelection()
        }
    }

    func clearDesignImport(projectID: UUID) {
        guard let run = project(id: projectID)?.designImport, !run.isActive else { return }
        updateProject(projectID) { $0.designImport = nil }
        Task { await DesignImportSources.discardStage(id: run.id) }
    }

    private func updateDesignImport(_ projectID: UUID, id: UUID, _ change: (inout DesignImportRun) -> Void) {
        updateProject(projectID) { project in
            guard var run = project.designImport, run.id == id else { return }
            change(&run); project.designImport = run
        }
    }
}
