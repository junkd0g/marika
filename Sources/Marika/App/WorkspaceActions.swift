import AppKit
import MarikaCore

extension AppModel {
    var selectedProject: Project? { selectedSession.flatMap(project(for:)) }
    var worktreeService: AgentWorktrees { AgentWorktrees(directory: store.worktreesDirectory, environment: gitEnvironment) }

    func layout(for id: UUID) -> ProjectLayout { project(id: id)?.layout ?? ProjectLayout() }
    func updateLayout(_ layout: ProjectLayout, for id: UUID) {
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
        updateLayout(saved, for: project.id)
    }
    func switchPanel(_ tab: ProjectPanel) {
        guard let project = selectedProject else { return }
        var saved = layout(for: project.id)
        let previous = projectTabs[project.id] ?? .conversation
        if saved.secondary == tab { saved.secondary = previous }
        saved.panel = tab
        updateLayout(saved, for: project.id)
        selectProjectTab(tab)
    }
    func preview(for project: Project) -> ProjectPreview {
        if let preview = previews[project.id] { return preview }
        let preview = ProjectPreview()
        preview.onReady = { [weak self] url in
            guard let self, let current = self.project(id: project.id) else { return }
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
    func runPreview(for project: Project? = nil) {
        guard let project = project ?? selectedProject else { return }
        guard let configuration = project.previewConfiguration ?? ProjectPreview.detect(at: project.url) else {
            openPreviewSettings(for: project); return
        }
        preview(for: project).start(configuration, at: project.url, environment: gitEnvironment)
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
