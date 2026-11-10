import AppKit
import MarikaCore

extension AppModel {
    var selectedProject: Project? { selectedSession.flatMap(project(for:)) }
    func design(for project: Project) -> DesignWorkspace {
        if let existing = designs[project.id] { return existing }
        let editor = DesignWorkspace(document: self.project(id: project.id)?.design ?? DesignDocument())
        editor.onChange = { [weak self] document in
            self?.updateProject(project.id) { $0.design = document }
        }
        designs[project.id] = editor
        return editor
    }
    func openDesign(for projectID: UUID) {
        guard let project = project(id: projectID) else { return }
        if let spaceID = project.spaceID, selectedSpace.id != spaceID { selectSpace(spaceID) }
        if selectedProject?.id == projectID { switchPanel(.design) }
        else { openProject(project, tab: .design) }
    }
    var worktreeService: AgentWorktrees { AgentWorktrees(directory: store.worktreesDirectory, environment: gitEnvironment) }

    func layout(for id: UUID) -> ProjectLayout { project(id: id)?.layout ?? ProjectLayout() }
    func updateLayout(_ layout: ProjectLayout, for id: UUID) {
        var layout = layout
        layout.normalizeTabs()
        updateProject(id) { $0.layout = layout }
        projectTabs[id] = layout.panel
    }
    func setSplit(_ secondary: ProjectPanel?, stacked: Bool? = nil) {
        guard let project = selectedProject else { return }
        var saved = layout(for: project.id)
        saved.panel = projectTabs[project.id] ?? .conversation
        saved.secondary = secondary == saved.panel ? nil : secondary
        if let stacked { saved.stacked = stacked }
        if secondary == .code { _ = editor(for: project) }
        if secondary == .browser { _ = browser(for: project) }
        if secondary == .design { _ = design(for: project) }
        updateLayout(saved, for: project.id)
    }
    func switchPanel(_ tab: ProjectPanel) {
        guard let project = selectedProject else { return }
        openSpaceSection(.projects)
        var saved = layout(for: project.id)
        saved.openTab(tab)
        updateLayout(saved, for: project.id)
        selectProjectTab(tab)
    }

    func closeProjectTab(_ tab: ProjectPanel) {
        guard let project = selectedProject else { return }
        var saved = layout(for: project.id)
        guard saved.closeTab(tab) else { return }
        updateLayout(saved, for: project.id)
        selectProjectTab(saved.panel)
    }

    func closeOtherProjectTabs(keeping tab: ProjectPanel) {
        guard let project = selectedProject else { return }
        var saved = layout(for: project.id)
        saved.closeOtherTabs(keeping: tab)
        updateLayout(saved, for: project.id)
        selectProjectTab(saved.panel)
    }

    func moveProjectTab(_ tab: ProjectPanel, offset: Int) {
        guard let project = selectedProject else { return }
        var saved = layout(for: project.id)
        if saved.moveTab(tab, offset: offset) { updateLayout(saved, for: project.id) }
    }

    func selectAdjacentProjectTab(_ offset: Int) {
        guard let project = selectedProject else { return }
        switchPanel(layout(for: project.id).adjacentTab(offset))
    }

    func splitProjectTab(_ drag: WorkspaceTabDrag, at edge: ProjectSplitEdge) {
        guard let project = selectedProject, project.id == drag.projectID else { return }
        var saved = layout(for: project.id)
        guard saved.splitTab(drag.panel, at: edge) else { return }
        for panel in [saved.panel, saved.secondary].compactMap({ $0 }) {
            switch panel {
            case .code: _ = editor(for: project)
            case .browser: _ = browser(for: project)
            case .terminal: ensureTerminal(for: project)
            case .design: _ = design(for: project)
            default: break
            }
        }
        updateLayout(saved, for: project.id)
        selectProjectTab(saved.panel)
    }
    func preview(for project: Project) -> ProjectPreview {
        if let preview = previews[project.id] { return preview }
        let preview = ProjectPreview()
        preview.onReady = { [weak self] url in
            guard let self, let current = self.project(id: project.id) else { return }
            if let target = self.previewRecoveryTargets.removeValue(forKey: project.id) {
                guard let page = self.browsers[project.id]?.pages.first(where: { $0.id == target.pageID }),
                      page.url == target.address, let reload = PreviewRecovery.reloadURL(target.address, server: url) else { return }
                page.load(reload)
                return
            }
            self.browser(for: current).navigate(url.absoluteString)
            if self.selectedProject?.id == project.id { self.switchPanel(.browser) }
        }
        previews[project.id] = preview
        return preview
    }
    func openPreviewSettings(for project: Project) {
        _ = preview(for: project)
        previewProjectID = project.id
    }
    func runPipeline(_ job: PipelineJob, project: Project, image: String) {
        let runner = pipelineRunners[project.id] ?? ProjectPipelineRunner()
        pipelineRunners[project.id] = runner
        runner.onFinish = { [weak self] result in
            self?.updateProject(project.id) { current in
                current.pipelineRuns = Array(((current.pipelineRuns ?? []) + [result]).suffix(12))
            }
        }
        runner.run(job, root: project.url, environment: gitEnvironment, image: image)
    }
    func runPreview(for project: Project? = nil, recovering page: BrowserPage? = nil) {
        guard let project = (project ?? selectedProject).flatMap({ self.project(id: $0.id) }) else { return }
        guard let configuration = project.previewConfiguration ?? ProjectPreview.detect(at: project.url) else {
            openPreviewSettings(for: project); return
        }
        let preview = preview(for: project)
        guard !preview.isActive else { return }
        if let page {
            guard let url = page.url,
                  browsers[project.id]?.pages.contains(where: { $0 === page }) == true,
                  PreviewRecovery.matches(url, configuration: configuration, runningAddress: preview.address) else { return }
            previewRecoveryTargets[project.id] = (page.id, url)
        } else { previewRecoveryTargets[project.id] = nil }
        preview.start(configuration, at: project.url, environment: gitEnvironment)
    }
    func savePreviewConfiguration(_ config: PreviewConfiguration, for project: Project) {
        updateProject(project.id) { $0.previewConfiguration = config }
    }
    func openSearchMatch(_ match: ProjectSearchMatch) {
        openLocation(path: match.path, line: match.line, column: match.column, length: match.length)
    }
    func openLocation(path: String, line: Int, column: Int = 1, length: Int = 0, root: URL? = nil) {
        guard let project = selectedProject else { return }
        if let root { selectRepository(root, project: project) }
        switchPanel(.code)
        let editor = editor(for: self.project(id: project.id) ?? project)
        Task {
            await editor.open(path)
            editor.reveal(line: line, column: column, length: length)
        }
    }
}
