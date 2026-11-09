import MarikaCore
import SwiftUI

struct ProjectAgentsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var filter: AgentTaskFilter = .all
    @State private var renameTarget: UUID?
    @State private var renameText = ""

    private func presentation(_ task: SessionMeta) -> AgentTaskPresentation {
        let controller = model.controllers[task.id]
        return AgentTaskPresentation(meta: controller?.meta ?? task, items: controller?.items ?? [],
                                     phase: controller?.phase ?? .idle, approval: controller?.pendingApproval, activity: controller?.activity)
    }
    private var activeCount: Int { tasks.filter { presentation($0).state.isActive }.count }
    private var attentionCount: Int { tasks.filter { presentation($0).state.needsAttention }.count }
    private var visibleTasks: [SessionMeta] {
        tasks.filter { filter.includes(presentation($0).state) }
    }

    private var tasks: [SessionMeta] {
        model.sessions(in: project).filter { $0.agentTask != nil || model.controllers[$0.id]?.isBusy == true }
    }

    var body: some View {
        if let selected = model.selectedAgentTaskIDs[project.id], tasks.contains(where: { $0.id == selected }) {
            AgentTaskDetailView(project: project, sessionID: selected)
        } else { taskList }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { heading.fixedSize(); Spacer(minLength: 0); filters }
                VStack(alignment: .leading, spacing: 12) { heading; filters }
            }
            .padding(24)
            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("Delegate a task", systemImage: "person.2")
                } description: {
                    Text("Give Claude or Codex a task and follow its progress here.")
                } actions: {
                    Button("New Agent") { model.agentLaunchProjectID = project.id }
                        .buttonStyle(.borderedProminent)
                }
            } else if visibleTasks.isEmpty {
                ContentUnavailableView(filter == .needsAttention ? "No agents need attention" : "No \(filter.rawValue.lowercased()) agents", systemImage: "person.2",
                    description: Text("Choose All to see every agent in this project."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleTasks) { meta in
                            AgentTaskCard(meta: meta, controller: model.controllers[meta.id]) {
                                renameText = model.controllers[meta.id]?.meta.title ?? meta.title; renameTarget = meta.id
                            }
                            if meta.id != visibleTasks.last?.id { Divider().padding(.leading, 60) }
                        }
                    }
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline) }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "folder")
                Text(tasks.contains(where: { $0.agentTask?.workspace != nil }) ? "Review isolated changes before applying" : "Agents use this project's files")
                Spacer()
                Text(project.name).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.canvas)
        .task(id: tasks.map(\.id)) {
            for task in tasks { await model.open(task.id) }
        }
        .alert("Rename agent", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Agent name", text: $renameText)
            Button("Save") { if let id = renameTarget { model.rename(id, to: renameText) }; renameTarget = nil }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: { Text("The agent's @mention stays the same.") }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Agents").font(.system(size: 20, weight: .semibold))
            HStack {
                Button("Queue (\((model.project(id: project.id)?.taskQueue?.pendingCount ?? 0) + (model.project(id: project.id)?.taskQueue?.items.count { $0.state == .failed } ?? 0)))", systemImage: "list.bullet.clipboard") { model.taskQueueProjectID = project.id }
                Button("Activity (\((model.project(id: project.id)?.taskActivity ?? []).count { !$0.isRead }))", systemImage: "bell") { model.taskActivityProjectID = project.id }
            }.controlSize(.small)
            Button("Review plans and results") { model.showExperience("Artifacts", project: project) }.buttonStyle(.link).font(.caption)
            Text("\(activeCount) active · \(attentionCount) need attention · \(tasks.count) in this project")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private var filters: some View {
        Picker("Show agents", selection: $filter) {
            ForEach(AgentTaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: 340).controlSize(.small)
    }

}

private struct AgentTaskCard: View {
    @Environment(AppModel.self) private var model
    let meta: SessionMeta
    let controller: SessionController?
    var rename: () -> Void
    private var presentation: AgentTaskPresentation {
        AgentTaskPresentation(meta: controller?.meta ?? meta, items: controller?.items ?? [], phase: controller?.phase ?? .idle,
                              approval: controller?.pendingApproval, activity: controller?.activity)
    }

    private var stateColor: Color { presentation.state.color }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: meta.agent == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor).frame(width: 30, height: 30)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(controller?.meta.title ?? meta.title)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .help(controller?.meta.title ?? meta.title)
                    Button(action: rename) { Image(systemName: "pencil") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename agent")
                        .accessibilityLabel("Rename " + (controller?.meta.title ?? meta.title))
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        if controller?.phase == .running { ProgressView().controlSize(.mini) }
                        else { Circle().fill(stateColor).frame(width: 5, height: 5) }
                        Text(presentation.state.rawValue).font(.system(size: 11))
                    }
                    .foregroundStyle(stateColor)
                }
                if let text = presentation.preview {
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { taskContext; Spacer(minLength: 4); taskActions }
                    VStack(alignment: .leading, spacing: 10) { taskContext; taskActions }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
    }
    private var taskContext: some View {
        Text((controller?.meta.agent ?? meta.agent).shortName + " · " + (meta.agentTask?.workspace == nil ? "Shared files" : "Isolated worktree"))
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
    }
    private var taskActions: some View {
        HStack(spacing: 8) {
            if let workspace = meta.agentTask?.workspace {
                if workspace.status == .ready || workspace.status == .reviewed {
                    Button(workspace.status == .reviewed ? "Review complete" : "Review Changes") { Task { await model.openAgentReview(meta.id) } }.disabled(controller?.isBusy == true)
                } else { Text(workspace.status == .applied ? "Applied" : "Discarded").font(.caption).foregroundStyle(.secondary) }
            }
            if controller?.isBusy == true { Button("Stop", role: .destructive) { controller?.interrupt() } }
            Button(controller?.phase == .waitingForUser ? "Review Approval" : "Open Chat") { model.openAgentChat(meta.id) }
            if controller?.isBusy != true {
                Button("Review Work") { model.taskCompletionID = meta.id }
            }
            Button("Task details") { model.selectedAgentTaskIDs[meta.projectID] = meta.id }
        }
    }
}

struct LaunchAgentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    var initialPrompt = ""
    var initialName = ""
    var parentSessionID: UUID?
    var researchReference: ResearchTaskReference?
    var onLaunched: ((SessionController) -> Void)?
    @State private var agent: AgentKind = .claude
    @State private var selectedModel = ""
    @State private var mode: ApprovalMode = .ask
    @State private var prompt = ""
    @State private var name = ""
    @State private var includeFile = false
    @State private var isolated = true
    @State private var isGitProject: Bool?
    @State private var isLaunching = false
    @State private var error: String?
    @FocusState private var taskFocused: Bool

    private var selectedFile: String? { model.editors[project.id]?.selectedDocument?.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("New agent").font(.system(size: 20, weight: .semibold))
                Text("A new agent will work in \(project.name) with its own chat.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Picker("Agent", selection: $agent) {
                ForEach(AgentKind.allCases) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 18) {
                Picker("Model", selection: $selectedModel) {
                    Text("Default").tag("")
                    ForEach(model.capabilities[agent]?.models.filter { $0.id != "default" } ?? []) { Text($0.name).tag($0.id) }
                }
                Picker("Permissions", selection: $mode) {
                    ForEach([ApprovalMode.ask, .acceptEdits, .plan, .auto]) { Text($0.title(for: agent)).tag($0) }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                TextField("Agent name (optional)", text: $name).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Agent name")
                Text(name.isEmpty ? "Suggested name: \(AgentTaskName.suggested(from: prompt))" : "You can rename the agent later.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Task").font(.system(size: 12, weight: .medium))
                TextEditor(text: $prompt).font(.system(size: 13)).focused($taskFocused)
                    .scrollContentBackground(.hidden).padding(8)
                    .frame(height: 130).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline) }
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text("For example: review the UI and fix the file navigation.")
                                .font(.system(size: 13)).foregroundStyle(.tertiary).padding(13).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Agent task")
            }
            if let selectedFile {
                Toggle("Include selected file: \(selectedFile)", isOn: $includeFile)
                    .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    .help("\(selectedFile)\nThe agent will read the saved file in the project.")
            }
            Toggle("Use an isolated Git worktree", isOn: $isolated)
                .font(.system(size: 12))
                .disabled(isGitProject == false)
                .help("Git projects get a separate checkout. Review and apply changes from the Agents panel. Other folders use their existing files.")
            if isGitProject == false {
                Text("This folder has no Git repository, so agents use the project files.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.attention) }
            AgentStatusLine(agent: agent)
            HStack {
                Text("Other agents can keep working.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Queue task") { enqueue() }.disabled(isLaunching || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(isLaunching ? "Launching…" : "Launch Agent", action: launch)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(isLaunching || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 590)
        .onAppear { agent = model.workspace.preferences.defaultAgent; prompt = initialPrompt; name = initialName; taskFocused = true }
        .task { isGitProject = await Git(environment: model.gitEnvironment).snapshot(at: project.url).isRepository; if isGitProject == false { isolated = false } }
        .onChange(of: agent) { _, _ in selectedModel = "" }
    }

    private func launch() {
        isLaunching = true
        error = nil
        var task = prompt
        if includeFile, let selectedFile { task += "\n\nStart with this project file: \(selectedFile)" }
        Task {
            do {
                let opensChat = model.projectTabs[project.id] == .conversation
                let controller = try await model.launchAgent(in: project, agent: agent,
                    settings: AgentSettings(model: selectedModel.isEmpty ? nil : selectedModel, mode: mode), prompt: task, parentSessionID: parentSessionID, isolated: isolated, name: name)
                onLaunched?(controller)
                if opensChat { model.openAgentChat(controller.id) }
                else { model.showAgents(for: project) }
                dismiss()
            } catch { self.error = error.localizedDescription; isLaunching = false }
        }
    }

    private func enqueue() {
        isLaunching = true; error = nil
        var task = prompt
        if includeFile, let selectedFile { task += "\n\nStart with this project file: \(selectedFile)" }
        Task {
            do {
                try await model.enqueueTask(in: project, agent: agent,
                    settings: AgentSettings(model: selectedModel.isEmpty ? nil : selectedModel, mode: mode), prompt: task,
                    name: name, isolated: isolated, parentSessionID: parentSessionID, research: researchReference)
                model.selectedAgentTaskIDs[project.id] = nil
                model.showAgents(for: project); dismiss()
            } catch { self.error = error.localizedDescription; isLaunching = false }
        }
    }
}
