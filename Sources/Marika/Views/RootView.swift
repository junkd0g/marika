import MarikaCore
import SwiftUI

extension EnvironmentValues {
    @Entry var conversationIsVisible = true
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    #if DEBUG
        @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let message = model.storageError ?? model.storageRecoveryNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                    Text(message).font(.system(size: 12)).lineLimit(4).textSelection(.enabled).help(message)
                    Spacer(minLength: 8)
                    Button("Open Saved Data") { model.showSavedData() }
                    if model.storageError != nil {
                        Button("Try Again") { Task { await model.retryStorage() } }
                    } else {
                        Button("Dismiss") { model.storageRecoveryNotice = nil }
                    }
                }
                .controlSize(.small).padding(12).background(Theme.attention.opacity(0.1))
            }

            NavigationSplitView(columnVisibility: Binding(
                get: { model.showsProjectSidebar ? .all : .detailOnly },
                set: { model.showsProjectSidebar = $0 != .detailOnly }
            )) {
                SidebarView()
                    .disabled(model.workspaceLoadFailed)
                    .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 340)
            } detail: {
                if model.workspaceLoadFailed {
                    ContentUnavailableView {
                        Label("Couldn't load your workspace", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Your saved data has been kept. Open Saved Data to restore a valid workspace.json or its backup, then try again.")
                    } actions: {
                        Button("Open Saved Data") { model.showSavedData() }
                        Button("Try Again") { Task { await model.retryStorage() } }
                    }
                } else if !model.isReady {
                    Color.clear
                } else if let meta = model.selectedSession, let project = model.project(for: meta) {
                    ProjectWorkspaceView(meta: meta, project: project)
                        .id(project.id)
                } else {
                    Group {
                        if model.workspace.projects.isEmpty && model.workspace.spaces.count == 1 { WelcomeView() }
                        else { SpaceEmptyView() }
                    }
                        .overlay(alignment: .topLeading) {
                            if !model.showsProjectSidebar {
                                Button { model.showsProjectSidebar = true } label: { Image(systemName: "sidebar.left") }
                                    .buttonStyle(.plain).padding(16).help("Show projects")
                            }
                        }
                }
            }
            .toolbar(removing: .title)
            .toolbar(removing: .sidebarToggle)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.workspaceLoadFailed else { return false }
            let folders = urls.filter { $0.hasDirectoryPath }
            folders.forEach(model.addProject(at:))
            return !folders.isEmpty
        }
        .onChange(of: model.controllers.values.map(\.approvals.count)) { _, _ in
            model.updateDockBadge()
        }
        .sheet(item: Binding(
            get: { model.agentLaunchProjectID.flatMap(model.project(id:)) },
            set: { if $0 == nil { model.agentLaunchProjectID = nil } }
        )) { project in
            LaunchAgentView(project: project).environment(model)
        }
        .sheet(item: Binding(get: { model.projectSettingsID.flatMap(model.project(id:)) }, set: { if $0 == nil { model.projectSettingsID = nil } })) { project in
            ProjectToolsView(project: project, initialSection: model.projectSettingsSection).environment(model)
        }
        .sheet(isPresented: $model.showsCommandPalette, onDismiss: {
            let action = model.pendingPaletteAction
            model.pendingPaletteAction = nil
            action?()
        }) { CommandPaletteView().environment(model) }
        .sheet(item: Binding(get: { model.experienceProjectID.flatMap(model.project(id:)) }, set: { if $0 == nil { model.experienceProjectID = nil } })) { project in
            ProjectExperienceView(project: project).environment(model)
        }
        .sheet(isPresented: $model.showsProjectSearch) {
            if let project = model.selectedProject { ProjectSearchView(project: project).environment(model) }
        }
        .sheet(isPresented: $model.showsChatHistorySearch) {
            ChatHistorySearchView().environment(model)
        }
        .sheet(isPresented: $model.showsSpaceEditor, onDismiss: { model.spaceEditorProjectID = nil }) {
            SpaceEditorView(space: model.workspace.spaces.first { $0.id == model.editingSpaceID }).environment(model)
        }
        .sheet(item: Binding(
            get: { model.previewProjectID.flatMap(model.project(id:)) },
            set: { if $0 == nil { model.previewProjectID = nil } }
        )) { project in
            if let preview = model.previews[project.id] {
                PreviewConsoleView(project: project, preview: preview).environment(model)
            }
        }
        .sheet(item: Binding(
            get: { model.workspace.sessions.first { $0.id == model.reviewAgentID } },
            set: { if $0 == nil { model.reviewAgentID = nil } }
        )) { session in AgentReviewView(session: session).environment(model) }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: DebugDriver.openSettingsRequest)) { _ in
                openSettings()
            }
        #endif
    }
}

private struct ProjectWorkspaceView: View {
    @Environment(AppModel.self) private var model
    let meta: SessionMeta
    let project: Project

    @State private var dragStart: Double?
    @State private var inspectorPresented = false

    private var selectedTab: AppModel.ProjectTab { model.projectTabs[project.id] ?? .conversation }
    private var inspectorEligible: Bool {
        model.selectedSession?.projectID == project.id && selectedTab == .conversation && arrangement.secondary == nil
    }

    var body: some View {
        let shouldPresentInspector = inspectorEligible && model.showsInspector
        VStack(spacing: 0) {
            projectHeader
            Divider()
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    place(ProjectChatView(project: project, selection: meta)
                        .environment(\.conversationIsVisible, visible(.conversation)), panel: .conversation, size: geometry.size)
                    if let editor = model.editors[project.id] {
                        place(ProjectCodeView(editor: editor, changeCount: model.controllers[meta.id]?.changeCount ?? 0,
                            isVisible: visible(.code), isCompact: bounds(.code, in: geometry.size).width < 550,
                            ide: model.ide(for: project, editor: editor)),
                            panel: .code, size: geometry.size)
                    }
                    if let browser = model.browsers[project.id] {
                        place(ProjectBrowserView(browser: browser, isVisible: visible(.browser)), panel: .browser, size: geometry.size)
                    }
                    if visible(.changes) { place(ProjectChangesView(project: project), panel: .changes, size: geometry.size) }
                    if let _ = model.terminals[project.id] { place(ProjectTerminalView(project: project, isVisible: visible(.terminal)), panel: .terminal, size: geometry.size) }
                    if visible(.api) {
                        place(ProjectAPIView(project: project), panel: .api, size: geometry.size)
                    }
                    if visible(.pipelines) {
                        place(ProjectPipelinesView(project: project), panel: .pipelines, size: geometry.size)
                    }
                    if visible(.stats) {
                        place(ProjectStatsView(project: project), panel: .stats, size: geometry.size)
                    }
                    if visible(.agents) {
                        place(ProjectAgentsView(project: project), panel: .agents, size: geometry.size)
                    }
                    if arrangement.secondary != nil {
                        splitDivider(in: geometry.size)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading).clipped()
            }
            #if DEBUG
                .background(DebugViewMarker(name: "workspace-content"))
            #endif
        }
        .background(Theme.canvas)
        .inspector(isPresented: $inspectorPresented) {
            if let session = model.controllers[meta.id] {
                ChangesInspector(session: session, project: project)
                    .inspectorColumnWidth(min: 260, ideal: 360, max: 620)
            }
        }
        .onChange(of: shouldPresentInspector, initial: true) { _, presented in inspectorPresented = presented }
        .onChange(of: inspectorPresented) { _, presented in
            if inspectorEligible {
                if model.showsInspector != presented { model.showsInspector = presented }
            } else if presented {
                inspectorPresented = false
            }
        }
    }

    private var arrangement: ProjectLayout {
        var saved = model.layout(for: project.id)
        if saved.secondary == selectedTab { saved.secondary = nil }
        return saved
    }
    private func visible(_ panel: ProjectPanel) -> Bool { selectedTab == panel || arrangement.secondary == panel }
    private func bounds(_ panel: ProjectPanel, in size: CGSize) -> CGRect {
        guard let secondary = arrangement.secondary else { return CGRect(origin: .zero, size: size) }
        let length = (arrangement.stacked ? size.height : size.width) - 6
        let minimum = min(0.49, (arrangement.stacked ? 160 : 300) / max(1, length))
        let fraction = min(1 - minimum, max(minimum, arrangement.splitFraction))
        let first = floor(length * fraction)
        if arrangement.stacked {
            return panel == secondary ? CGRect(x: 0, y: first + 6, width: size.width, height: length - first)
                : CGRect(x: 0, y: 0, width: size.width, height: first)
        }
        return panel == secondary ? CGRect(x: first + 6, y: 0, width: length - first, height: size.height)
            : CGRect(x: 0, y: 0, width: first, height: size.height)
    }
    private func place<V: View>(_ view: V, panel: ProjectPanel, size: CGSize) -> some View {
        let rect = bounds(panel, in: size)
        return view.frame(width: rect.width, height: rect.height).clipped()
            .offset(x: rect.minX, y: rect.minY)
            .opacity(visible(panel) ? 1 : 0).allowsHitTesting(visible(panel)).accessibilityHidden(!visible(panel))
    }
    private func splitDivider(in size: CGSize) -> some View {
        let rect = bounds(selectedTab, in: size)
        return Rectangle().fill(Theme.hairline)
            .frame(width: arrangement.stacked ? size.width : 6, height: arrangement.stacked ? 6 : size.height)
            .contentShape(Rectangle())
            .offset(x: arrangement.stacked ? 0 : rect.maxX, y: arrangement.stacked ? rect.maxY : 0)
            .gesture(DragGesture().onChanged { value in
                if dragStart == nil { dragStart = arrangement.splitFraction }
                var saved = arrangement
                let delta = arrangement.stacked ? value.translation.height / size.height : value.translation.width / size.width
                saved.splitFraction = min(0.8, max(0.2, (dragStart ?? 0.5) + delta))
                model.updateLayout(saved, for: project.id)
            }.onEnded { _ in dragStart = nil })
            .help("Drag to resize the split")
    }

    private var projectHeader: some View {
        WorkspaceHeader(project: project, selection: selectedTab,
            activeAgents: model.sessions(in: project).filter { model.controllers[$0.id]?.isBusy == true }.count,
            select: model.switchPanel, launchAgent: { model.showAgents(for: project, launch: true) })
    }
}

/// Loads a session's transcript before showing it.
struct SessionContainer: View {
    @Environment(AppModel.self) private var model
    let meta: SessionMeta

    var body: some View {
        Group {
            if let session = model.controllers[meta.id], let project = model.project(for: meta) {
                SessionView(session: session, project: project)
            } else if model.storageError != nil {
                ContentUnavailableView("Couldn't load this conversation", systemImage: "exclamationmark.bubble",
                    description: Text("Your saved transcript has been kept. Use Try Again above after restoring it in Saved Data."))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: meta.id) { await model.open(meta.id) }
    }
}

struct SessionView: View {
    @Environment(AppModel.self) private var model
    let session: SessionController
    let project: Project

    /// The empty state already shows this. A session with history would otherwise have no hint.
    private var agentNeedsAttention: Bool {
        switch model.statuses[session.meta.agent]?.readiness {
        case .notInstalled, .signedOut, .unavailable: true
        default: false
        }
    }

    var body: some View {
        // A plain stack, not a safe-area inset. The scroll view needs its true height at first
        // layout, or opening a session stops short of the end by the height of the composer.
        VStack(spacing: 0) {
            Group {
                if session.hasStarted {
                    TranscriptView(session: session)
                } else {
                    SessionStartView(session: session, project: project)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                if let approval = session.pendingApproval {
                    ApprovalPanel(request: approval, session: session)
                        .id(approval.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !session.todos.isEmpty, session.isBusy {
                    TodoStrip(todos: session.todos)
                }
                if session.hasStarted, agentNeedsAttention {
                    AgentStatusLine(agent: session.meta.agent)
                }
                ComposerView(session: session)
            }
            .frame(maxWidth: Theme.transcriptWidth + 36)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                // Lets the transcript fade out instead of ending at a hard line.
                LinearGradient(colors: [Theme.canvas.opacity(0), Theme.canvas], startPoint: .top, endPoint: .bottom)
                    .frame(height: 20)
                    .offset(y: -20)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.18), value: session.pendingApproval?.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .environment(\.projectRoot, project.url)
    }
}

/// One line saying whether an agent is ready, with the next step if it isn't.
struct AgentStatusLine: View {
    @Environment(AppModel.self) private var model
    let agent: AgentKind
    /// Off inside Settings, where a link to Settings would go nowhere.
    var linksToSettings = true

    private var status: AgentStatus { model.statuses[agent] ?? AgentStatus() }

    var body: some View {
        HStack(spacing: 7) {
            switch status.readiness {
            case .checking:
                ProgressView().controlSize(.mini)
                Text("Checking \(agent.shortName)…").foregroundStyle(.secondary)
            case .ready:
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(readyLabel).foregroundStyle(.secondary)
            case .signedOut:
                Circle().fill(Theme.attention).frame(width: 7, height: 7)
                Text("Not signed in").foregroundStyle(.secondary)
                Button("Sign In…") { model.signIn(agent) }
                    .controlSize(.small)
            case .unavailable(let reason):
                Circle().fill(Theme.attention).frame(width: 7, height: 7)
                Text(reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Check Again") { Task { await model.refreshAgents(force: true) } }
                    .controlSize(.small)
                    .disabled(model.isRefreshingAgents)
            case .notInstalled:
                Circle().fill(.secondary).frame(width: 7, height: 7)
                Text("\(agent.executableName) isn't installed").foregroundStyle(.secondary)
                if linksToSettings {
                    SettingsLink { Text("Set Up…") }
                        .controlSize(.small)
                }
            }
        }
        .font(.system(size: 12))
    }

    private var readyLabel: String {
        let details = [status.plan, status.account].compactMap { $0 }.joined(separator: " · ")
        return details.isEmpty ? "\(agent.shortName) is ready" : details
    }
}
