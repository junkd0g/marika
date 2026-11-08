import AppKit
import MarikaCore
import PDFKit

extension AppModel {
    func showResearchSection(_ section: String, project: Project) {
        researchSections[project.id] = section
        if selectedProject?.id != project.id { openProject(project) }
        switchPanel(.research)
    }
    func launchComparison(_ question: String, synthesizer: AgentKind = .codex, project: Project) async throws -> UUID {
        let active = controllers.values.count { $0.meta.projectID == project.id && $0.meta.agentTask != nil && $0.isBusy }
        guard active + launchingProjects.values.count(where: { $0 == project.id }) <= 2 else { throw AgentError.launchFailed("Comparison needs two free agent slots. Wait for running work or stop it first.") }
        let run = try ModelComparison(question: question, synthesizer: synthesizer)
        // Retain active/incomplete runs; don't prune pending work when a new comparison starts.
        guard (self.project(id: project.id)?.comparisons?.count ?? 0) < 40 else { throw AgentError.launchFailed("This project has 40 comparisons. Remove an old comparison before starting another.") }
        updateProject(project.id) { $0.comparisons = ($0.comparisons ?? []) + [run] }
        guard await save() else { throw AgentError.launchFailed("Couldn't save the comparison. No agents started.") }
        for agent in AgentKind.allCases { await startComparisonAnswer(run.id, agent: agent, project: project) }
        return run.id
    }
    func startComparisonAnswer(_ id: UUID, agent: AgentKind, project: Project) async {
        guard let run = self.project(id: project.id)?.comparisons?.first(where: { $0.id == id }), run.synthesisID == nil else { return }
        let sessionID = run.sessionID(for: agent)
        do {
            if workspace.sessions.contains(where: { $0.id == sessionID }) {
                await open(sessionID)
                guard let controller = controllers[sessionID], !controller.isBusy else { return }
                guard controllers.values.count(where: { $0.meta.projectID == project.id && $0.isBusy && $0.meta.agentTask != nil }) < 4 else { throw AgentError.launchFailed("Wait for a free agent slot before retrying.") }
                controller.send(UserInput(text: run.analysisPrompt))
            } else {
                _ = try await launchAgent(in: project, agent: agent, settings: AgentSettings(mode: .plan), prompt: run.analysisPrompt,
                    isolated: false, name: String(("Compare · " + agent.shortName + ": " + run.question).prefix(80)), sessionID: sessionID)
            }
            updateComparison(id, projectID: project.id) { $0.errors?[agent.rawValue] = nil }
        } catch { updateComparison(id, projectID: project.id) { if $0.errors == nil { $0.errors = [:] }; $0.errors?[agent.rawValue] = error.localizedDescription } }
    }
    func synthesizeComparison(_ id: UUID, agent: AgentKind, project: Project) async throws {
        guard !synthesizingComparisons.contains(id) else { return }
        synthesizingComparisons.insert(id)
        defer { synthesizingComparisons.remove(id) }
        guard let run = self.project(id: project.id)?.comparisons?.first(where: { $0.id == id }), run.synthesis == nil else { return }
        let prompt = try run.synthesisPrompt()
        let sessionID = run.synthesisID ?? UUID()
        updateComparison(id, projectID: project.id) { $0.synthesisID = sessionID }
        guard await save() else { throw AgentError.launchFailed("Couldn't save synthesis. No agent started.") }
        if workspace.sessions.contains(where: { $0.id == sessionID }) {
            await open(sessionID)
            guard let controller = controllers[sessionID], !controller.isBusy else { return }
            guard controllers.values.count(where: { $0.meta.projectID == project.id && $0.meta.agentTask != nil && $0.isBusy }) < 4 else { throw AgentError.launchFailed("Wait for a free agent slot before retrying synthesis.") }
            controller.send(UserInput(text: prompt))
        } else {
            _ = try await launchAgent(in: project, agent: agent, settings: AgentSettings(mode: .plan), prompt: prompt,
                isolated: false, name: String(("Synthesis: " + run.question).prefix(80)), sessionID: sessionID)
        }
        updateComparison(id, projectID: project.id) { $0.errors?["synthesis"] = nil }
    }
    func updateComparison(_ id: UUID, projectID: UUID, _ change: (inout ModelComparison) -> Void) {
        updateProject(projectID) { current in
            if let index = current.comparisons?.firstIndex(where: { $0.id == id }) { change(&current.comparisons![index]) }
        }
    }
    func saveKnowledge(_ entry: KnowledgeEntry, projectID: UUID, replacing id: UUID? = nil, revision: Int? = nil) throws {
        var knowledge = project(id: projectID)?.knowledge ?? ProjectKnowledge()
        try knowledge.save(entry, replacing: id, revision: revision)
        updateProject(projectID) { $0.knowledge = knowledge }
        reconnectKnowledge(projectID)
    }
    func approveKnowledge(_ id: UUID, projectID: UUID) throws {
        var knowledge = project(id: projectID)?.knowledge ?? ProjectKnowledge(); try knowledge.approve(id)
        updateProject(projectID) { $0.knowledge = knowledge }; reconnectKnowledge(projectID)
    }
    func reconnectKnowledge(_ projectID: UUID) {
        for controller in controllers.values where controller.meta.projectID == projectID { controller.disconnectWhenIdle() }
    }
    func importKnowledge(_ url: URL, projectID: UUID) async throws {
        let entry = try await Task.detached {
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 10_000_000 else { throw AgentError.launchFailed("Import a regular document under 10 MB.") }
            let text: String
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount <= 200 else { throw AgentError.launchFailed("Use an unlocked PDF with at most 200 pages.") }
                text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
            } else if ["docx", "rtf"].contains(url.pathExtension.lowercased()) {
                text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
            } else { text = try String(contentsOf: url, encoding: .utf8) }
            return try KnowledgeEntry(title: url.lastPathComponent, kind: .document, content: text, source: url.lastPathComponent)
        }.value
        try saveKnowledge(entry, projectID: projectID)
    }
}
