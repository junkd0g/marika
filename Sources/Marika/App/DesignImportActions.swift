import Foundation
import MarikaCore

extension AppModel {
    func startDesignImport(projectID: UUID, paths: [String], focus: String, agent: AgentKind, model: String?, updating: UUID? = nil, selection: Set<UUID> = [], reference: DesignImportReference? = nil, referenceImage: Data? = nil) async throws {
        guard let project = project(id: projectID), project.runtime == nil else { throw DesignToolError("Open a local project to import its interface.") }
        guard project.designImport?.isActive != true else { throw DesignToolError("A design import is already running.") }
        var run = DesignImportRun(projectPath: project.path, agent: agent)
        if let updating {
            guard project.designImportBatches?.contains(where: { $0.id == updating }) == true, !selection.isEmpty else { throw DesignToolError("Select imported layers to update.") }
            run.updatingBatchID = updating; run.targetIDs = selection
        }
        preparingDesignImports.insert(run.id)
        defer { preparingDesignImports.remove(run.id) }
        updateProject(projectID) { $0.designImport = run }
        do {
            let snapshot = try await DesignImportSources.capture(paths, at: project.url)
            var prompt = try DesignImportPrompt.make(snapshot: snapshot, focus: focus)
            if updating != nil {
                let context = design(for: project).document.nodes.filter { selection.contains($0.id) }.map { $0.name }.joined(separator: ", ")
                prompt += "\nUPDATE ONLY these imported components: " + String(context.prefix(3_000)) + ". Keep their layer names and source paths stable. Return only this selected scope, not the whole project."
            }
            var images: [ImageAttachment] = []
            if var reference, let referenceImage {
                guard referenceImage.count <= 8_000_000 else { throw DesignToolError("Reference screenshot exceeds 8 MB.") }
                prompt += "\n" + (try reference.prompt())
                let directory = store.attachmentsDirectory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(run.id.uuidString + "-reference.png")
                try referenceImage.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                reference.imagePath = url.path; run.reference = reference
                images = [ImageAttachment(path: url.path, mediaType: "image/png")]
            }
            try await DesignImportSources.stage(snapshot, id: run.id)
            guard self.project(id: projectID)?.designImport?.id == run.id,
                  self.project(id: projectID)?.path == project.path,
                  self.project(id: projectID)?.designImport?.status == .preparing else { throw CancellationError() }
            updateDesignImport(projectID, id: run.id) { $0.files = snapshot.files; $0.reference = run.reference; $0.status = .running }
            _ = try await launchAgent(in: project, agent: agent, settings: AgentSettings(model: model, mode: .plan), prompt: prompt,
                isolated: false, name: "Import UI design", sessionID: run.sessionID, designImportID: run.id, images: images)
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
            try await DesignImportSources.verify(run.files, at: project.url)
            let proposal: DesignImportProposal
            do { proposal = try DesignImportProposal.parse(response, files: run.files) }
            catch {
                if (run.repairAttempts ?? 0) == 0 {
                    updateDesignImport(project.id, id: run.id) { $0.repairAttempts = 1 }
                    session.send(UserInput(text: "Validation rejected the draft: " + String(error.localizedDescription.prefix(500)) + "\nReturn corrected JSON only with summary, notes, and design. Preserve the source links and schema from the initial request. Do not edit or execute any files. This is the single validation repair attempt."))
                    return
                }
                throw error
            }
            let reviewRevision = try? DesignTools.revision(of: design(for: project).document)
            updateDesignImport(project.id, id: run.id) {
                guard $0.status == .running else { return }
                $0.proposal = proposal; $0.status = .ready; $0.error = nil
                $0.reviewRevision = reviewRevision
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

    func applyDesignImport(projectID: UUID, useGenerated: Set<UUID> = []) async throws {
        guard let project = project(id: projectID), let run = project.designImport,
              run.status == .ready, let proposal = run.proposal, run.projectPath == project.path else { throw DesignToolError("No reviewed design is ready to import.") }
        try await DesignImportSources.verify(run.files, at: project.url)
        guard self.project(id: projectID)?.designImport?.id == run.id,
              self.project(id: projectID)?.path == project.path,
              self.project(id: projectID)?.designImport?.status == .ready else { throw DesignToolError("This import changed. Open the current draft again.") }
        let editor = design(for: project)
        let selection: Set<UUID>
        if let batchID = run.updatingBatchID, let batch = self.project(id: projectID)?.designImportBatches?.first(where: { $0.id == batchID }) {
            guard run.reviewRevision == (try DesignTools.revision(of: editor.document)) else { throw DesignToolError("The canvas changed. Refresh the review before applying this update.") }
            let plan = try DesignImportMerge(batch: batch, current: editor.document, targets: run.targetIDs ?? [], proposal: proposal.document)
            let merged = try plan.applying(useGenerated: useGenerated)
            try saveDesignVersion(projectID: projectID, name: "Before importing UI design")
            editor.edit { $0 = merged.document }
            updateProject(projectID) { project in
                if let index = project.designImportBatches?.firstIndex(where: { $0.id == batchID }) {
                    project.designImportBatches?[index].baseline = merged.baseline
                    project.designImportBatches?[index].files = run.files
                }
            }
            selection = Set(merged.document.nodes.filter { $0.importOrigin?.batchID == batchID }.map(\.id))
        } else {
            let merged = try proposal.appending(to: editor.document, batchID: run.id)
            try saveDesignVersion(projectID: projectID, name: "Before importing UI design")
            editor.edit { $0 = merged.document }
            var baseline = merged.document
            baseline.nodes = baseline.nodes.filter { $0.importOrigin?.batchID == run.id }
            let ids = Set(baseline.nodes.map(\.id)); baseline.connections = baseline.connections?.filter { ids.contains($0.from) && ids.contains($0.to) }
            let batch = DesignImportBatch(id: run.id, name: proposal.document.title ?? "Imported UI", baseline: baseline, files: run.files)
            updateProject(projectID) { $0.designImportBatches = Array((($0.designImportBatches ?? []) + [batch]).suffix(20)) }
            selection = [merged.selection]
        }
        updateDesignImport(projectID, id: run.id) { $0.status = .applied; $0.proposal = nil }
        if let canvas = designCanvases[projectID] {
            canvas.selection = selection; canvas.selectedConnection = nil; canvas.fitSelection()
        }
    }

    func refreshDesignImportReview(projectID: UUID) {
        guard let project = project(id: projectID), let run = project.designImport else { return }
        let revision = try? DesignTools.revision(of: design(for: project).document)
        updateDesignImport(projectID, id: run.id) { $0.reviewRevision = revision }
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
