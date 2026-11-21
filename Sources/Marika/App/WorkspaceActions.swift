import AppKit
import MarikaCore

extension AppModel {
    var activeEditor: CodeWorkspace? {
        guard let projectID = selectedSession?.projectID, commandPanel == .code else { return nil }
        return editors[projectID]
    }

    var activeBrowser: BrowserWorkspace? {
        guard let id = selectedSession?.projectID, commandPanel == .browser else { return nil }
        return projectRuntimeTools[id]?.browser
    }

    var commandPanel: ProjectPanel? {
        guard !showsWelcome, selectedSpace.section == .projects else { return nil }
        guard let id = selectedSession?.projectID else { return nil }
        let primary = projectTabs[id] ?? .conversation
        if let focused = focusedPanels[id], focused == primary || focused == layout(for: id).secondary { return focused }
        return primary
    }

    func openProject(_ project: Project, tab: ProjectTab? = nil, showProject: Bool = true) {
        guard let current = self.project(id: project.id) else { return }
        if showProject { showsWelcome = false }
        if showProject { presentProjectSpace(current.spaceID) }
        let conversation = workspace.chat(for: current.id) ?? newSession(in: current)
        selectedSessionID = conversation.id
        showsInspector = current.layout?.showsInspector ?? true
        rememberProjectConversation(conversation)
        rememberChat(conversation)
        if let tab { projectTabs[current.id] = tab }
        let saved = layout(for: current.id)
        let primary = projectTabs[current.id] ?? .conversation
        preparePanel(primary, for: current)
        if let secondary = saved.secondary { preparePanel(secondary, for: current) }
        if (projectTabs[current.id] ?? .conversation) == .conversation { composerFocusRequest = UUID() }
    }

    func preparePanel(_ panel: ProjectPanel, for project: Project) {
        switch panel {
        case .code: _ = editor(for: project)
        case .browser: _ = browser(for: project)
        case .terminal: ensureTerminal(for: project)
        case .design: _ = design(for: project)
        case .containers: _ = containers(for: project)
        case .qa: _ = qa(for: project)
        case .conversation, .changes, .agents, .stats, .pipelines, .api, .research: break
        }
    }

    func selectProjectTab(_ tab: ProjectTab) {
        guard let meta = selectedSession, let project = project(for: meta) else { return }
        focusedPanels[project.id] = tab
        if tab == .conversation { openProject(project, tab: tab); return }
        preparePanel(tab, for: project)
        if tab == .code { editors[project.id]?.focusEditor() }
        projectTabs[project.id] = tab
    }

    func showCode(quickOpen: Bool = false, focusFiles: Bool = false) {
        guard let meta = selectedSession, let project = project(for: meta) else { return }
        let editor = editor(for: project)
        switchPanel(.code)
        if quickOpen { editor.showsQuickOpen = true }
        if focusFiles { editor.focusNavigator() }
    }

    func showAgents(for preferredProject: Project? = nil, launch: Bool = false) {
        guard let project = preferredProject ?? selectedSession.flatMap(project(for:)) ?? spaceProjects.first else { return }
        openSpaceSection(.projects)
        if selectedSession?.projectID != project.id {
            openProject(project)
        }
        projectTabs[project.id] = .agents
        if launch { agentLaunchProjectID = project.id }
    }


    var selectedProject: Project? { selectedSession.flatMap(project(for:)) }
    func design(for project: Project) -> DesignWorkspace {
        if let existing = designs[project.id] { return existing }
        let editor = DesignWorkspace(document: self.project(id: project.id)?.design ?? DesignDocument())
        editor.onChange = { [weak self] document in
            self?.updateProject(project.id) { $0.design = document }
        }
        designs[project.id] = editor
        designCanvases[project.id] = DesignCanvasModel(editor: editor, projectID: project.id, app: self)
        return editor
    }
    func openDesign(for projectID: UUID) {
        guard let project = project(id: projectID) else { return }
        if let spaceID = project.spaceID, selectedSpace.id != spaceID { selectSpace(spaceID) }
        if selectedProject?.id == projectID { switchPanel(.design) }
        else { openProject(project, tab: .design) }
    }
    func useDesignElementsInChat(projectID: UUID, selection: Set<UUID>) async throws {
        guard let project = project(id: projectID) else { throw DesignToolError("This project is no longer available.") }
        let reference = try DesignTools.referencePrompt(design(for: project).document, selection: selection)
        let chat = selectedSession.flatMap { $0.projectID == projectID ? $0 : nil }
            ?? workspace.chat(for: projectID) ?? newSession(in: project)
        await open(chat.id)
        guard self.project(id: projectID) != nil, let controller = controllers[chat.id] else {
            throw DesignToolError("The project chat couldn't be opened.")
        }
        controller.draft = DesignTools.mergingReference(reference, into: controller.draft)
        if let spaceID = project.spaceID, selectedSpace.id != spaceID { selectSpace(spaceID) }
        openAgentChat(chat.id)
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
        if let secondary = saved.secondary { preparePanel(secondary, for: project) }
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
        if let secondary = saved.secondary { preparePanel(secondary, for: project) }
        updateLayout(saved, for: project.id)
        selectProjectTab(saved.panel)
    }
    func preview(for project: Project) -> ProjectPreview {
        if let preview = projectRuntimeTools[project.id]?.preview { return preview }
        let preview = ProjectPreview()
        preview.onReady = { [weak self] url in
            guard let self, let current = self.project(id: project.id) else { return }
            if let target = self.previewRecoveryTargets.removeValue(forKey: project.id) {
                guard let page = self.projectRuntimeTools[project.id]?.browser?.pages.first(where: { $0.id == target.pageID }),
                      page.url == target.address, let reload = PreviewRecovery.reloadURL(target.address, server: url) else { return }
                page.load(reload)
                return
            }
            self.browser(for: current).navigate(url.absoluteString)
            if self.selectedProject?.id == project.id { self.switchPanel(.browser) }
        }
        runtimeTools(for: project.id).preview = preview
        return preview
    }
    func openPreviewSettings(for project: Project) {
        _ = preview(for: project)
        previewProjectID = project.id
    }
    func runPipeline(_ job: PipelineJob, project: Project, image: String) {
        let runner = projectRuntimeTools[project.id]?.pipeline ?? ProjectPipelineRunner()
        runtimeTools(for: project.id).pipeline = runner
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
                  projectRuntimeTools[project.id]?.browser?.pages.contains(where: { $0 === page }) == true,
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
