import AppKit
import MarikaCore
import SwiftUI

struct ProjectToolsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    var initialSection = "Setup"
    @State private var draft = ProjectTools()
    @State private var section = "Setup"
    @State private var error: String?
    @State private var actionName = ""
    @State private var actionCommand = ""
    @State private var skillName = ""
    @State private var skillText = ""
    @State private var selectedSkill: UUID?
    @State private var hookEvent = ProjectHook.Event.beforeTurn
    @State private var hookCommand = ""
    @State private var remoteName = ""
    @State private var remoteHost = ""
    @State private var remoteDirectory = ""
    @State private var extensionJSON = ""
    @State private var debugJSON = ""
    @State private var containerImage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(project.name).font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { if save() { dismiss() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    #if DEBUG
                    .background(DebugViewMarker(name: "project-tools-save"))
                    #endif
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["Setup", "Schedules", "Skills", "MCP", "Memory", "Hooks", "Remote", "Editor"], id: \.self) { name in
                        Button { section = name } label: {
                            Text(name == "MCP" ? "Connections" : name).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                                .background(section == name ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).foregroundStyle(section == name ? Color.accentColor : .primary)
                    }
                }.frame(width: 130)
                Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case "Setup": setup
                    case "Schedules": schedules
                    case "Skills": skills
                    case "Memory": memory
                    case "Hooks": hooks
                    case "Remote": remote
                    case "Editor": editorSettings
                    case "MCP": MCPConnectionsView(configuration: $draft.mcpConfig, root: project.url, projectID: project.id, environment: model.toolEnvironment)
                    default: setup
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }.font(.system(size: 12)).controlSize(.small).textFieldStyle(.roundedBorder).padding(20).frame(width: 820, height: 650).background(Theme.canvas)
        .onAppear {
            section = initialSection
            draft = model.project(id: project.id)?.tools ?? ProjectTools()
            debugJSON = String(data: (try? JSONEncoder().encode(draft.ide?.debug ?? DebugConfiguration())) ?? Data(), encoding: .utf8) ?? ""
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Worktree setup").font(.headline)
            Text("Runs in each new agent worktree before the agent starts. Use it to install dependencies or prepare local configuration.").foregroundStyle(.secondary)
            TextEditor(text: $draft.setupCommand).font(.body.monospaced()).frame(height: 100).padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            Text("Project actions").font(.headline)
            ForEach(draft.actions) { action in
                HStack {
                    VStack(alignment: .leading) { Text(action.name); Text(action.command).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Run") {
                        if save() { dismiss(); model.openTerminal(command: action.command) }
                    }
                    Button(role: .destructive) { draft.actions.removeAll { $0.id == action.id } } label: { Image(systemName: "trash") }
                }
            }
            TextField("Action name", text: $actionName)
            TextField("Command", text: $actionCommand)
            Button("Add action", systemImage: "plus") {
                draft.actions.append(ProjectAction(name: actionName, command: actionCommand)); actionName = ""; actionCommand = ""
            }.disabled(actionName.isEmpty || actionCommand.isEmpty)
        }
    }

    private var schedules: some View {
        ProjectJobsView(project: project, onOpenChat: { dismiss() })
            .frame(minHeight: 620)
            .onChange(of: model.project(id: project.id)?.tools?.schedules) { _, jobs in
                draft.schedules = jobs ?? []
            }
    }

    private var skills: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project playbooks").font(.headline)
            Text("Enabled playbooks are included in new Claude and Codex sessions. Use them for review standards, testing instructions, or recurring project workflows.").font(.caption).foregroundStyle(.secondary)
            ForEach($draft.skills) { $skill in
                HStack {
                    Toggle(skill.name, isOn: $skill.enabled)
                    Button("Edit") { selectedSkill = skill.id; skillName = skill.name; skillText = skill.instructions }
                    Button(role: .destructive) { draft.skills.removeAll { $0.id == skill.id } } label: { Image(systemName: "trash") }
                }
            }
            TextField("Playbook name", text: $skillName)
            TextEditor(text: $skillText).font(.body.monospaced()).frame(height: 170).padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(selectedSkill == nil ? "Add playbook" : "Update playbook") {
                    if let index = draft.skills.firstIndex(where: { $0.id == selectedSkill }) {
                        draft.skills[index].name = skillName; draft.skills[index].instructions = skillText
                    } else { draft.skills.append(ProjectSkill(name: skillName, instructions: skillText)) }
                    skillName = ""; skillText = ""; selectedSkill = nil
                }.disabled(skillName.isEmpty || skillText.isEmpty)
                Button("Import SKILL.md…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        do { skillText = try String(contentsOf: url, encoding: .utf8); skillName = url.deletingLastPathComponent().lastPathComponent; selectedSkill = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project memory").font(.headline)
            Text("Shared context for Claude and Codex. Record architecture decisions, conventions, and useful commands. Included when an agent next connects.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { draft.memory ?? "" }, set: { draft.memory = $0 }))
                .font(.body.monospaced()).frame(height: 270).padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            Text("Repository instructions").font(.headline)
            ForEach(["CLAUDE.md", "AGENTS.md", ".claude/settings.json"], id: \.self) { file in
                let exists = FileManager.default.fileExists(atPath: project.url.appendingPathComponent(file).path)
                HStack {
                    Text(file).font(.caption.monospaced())
                    Spacer()
                    if exists { Button("Open in editor") { dismiss(); model.openLocation(path: file, line: 1, root: project.url) } }
                    else { Text("Not present").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private var hooks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn hooks").font(.headline)
            Text("Run local commands before or after agent turns, in the agent’s working directory. Before-turn failures stop the turn. Commands receive MARIKA_PROJECT_DIR and MARIKA_SESSION_ID. Each hook has a 60-second limit.").font(.callout).foregroundStyle(.secondary)
            ForEach(draft.hooks ?? []) { hook in
                HStack {
                    Toggle(isOn: Binding(get: { draft.hooks?.first(where: { $0.id == hook.id })?.enabled ?? false }, set: { value in
                        if let index = draft.hooks?.firstIndex(where: { $0.id == hook.id }) { draft.hooks?[index].enabled = value }
                    })) { VStack(alignment: .leading) { Text(hook.event.rawValue); Text(hook.command).font(.caption.monospaced()) } }
                    Button(role: .destructive) { draft.hooks?.removeAll { $0.id == hook.id } } label: { Image(systemName: "trash") }
                }.padding(12).surface()
            }
            Picker("Event", selection: $hookEvent) { ForEach(ProjectHook.Event.allCases, id: \.self) { Text($0.rawValue) } }
            TextField("Command", text: $hookCommand)
            Button("Add hook", systemImage: "plus") { draft.hooks = (draft.hooks ?? []) + [ProjectHook(event: hookEvent, command: hookCommand)]; hookCommand = "" }
                .disabled(hookCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private var remote: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote machines").font(.headline)
            Text("Connect through your SSH configuration. Open a remote shell, or run the Claude or Codex CLI installed on that machine. Authentication happens in the terminal; remote agent sessions stay there.").font(.callout).foregroundStyle(.secondary)
            ForEach(draft.remoteMachines ?? []) { machine in
                VStack(alignment: .leading, spacing: 10) {
                    Text(machine.name).font(.headline)
                    Text(machine.host + " · " + machine.directory).font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack {
                        Button("Connect") { connect(machine, agent: nil) }
                        Button("Open workspace") {
                            if save() { Task { do { try await model.openRemoteWorkspace(WorkspaceRuntime(kind: .ssh, target: machine.host, directory: machine.directory), from: project); dismiss() } catch { self.error = error.localizedDescription } } }
                        }
                        Button("Claude") { connect(machine, agent: .claude) }
                        Button("Codex") { connect(machine, agent: .codex) }
                        Spacer()
                        Button("Remove", role: .destructive) { draft.remoteMachines?.removeAll { $0.id == machine.id } }
                    }
                }.padding(12).surface()
            }
            TextField("Machine name", text: $remoteName)
            TextField("SSH host or user@host", text: $remoteHost)
            TextField("Absolute remote project path", text: $remoteDirectory)
            Button("Add machine", systemImage: "plus") {
                let machine = RemoteMachine(name: remoteName, host: remoteHost, directory: remoteDirectory)
                do { _ = try machine.arguments(); draft.remoteMachines = (draft.remoteMachines ?? []) + [machine]; remoteName = ""; remoteHost = ""; remoteDirectory = "" }
                catch { self.error = error.localizedDescription }
            }.disabled(remoteName.isEmpty || remoteHost.isEmpty || remoteDirectory.isEmpty)
            Divider()
            Text("Development container").font(.headline)
            Text("Mount this project into a container. Language servers, tests, and configured debug adapters run inside it. Install your toolchain in the image first.").foregroundStyle(.secondary)
            TextField("Image, e.g. golang:1.26", text: $containerImage)
            Button("Start development container") {
                Task { do { try await model.openContainer(containerImage, project: project); dismiss() } catch { self.error = error.localizedDescription } }
            }.disabled(containerImage.isEmpty || project.runtime != nil)
        }
    }
    private var editorSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI code suggestions").font(.headline)
            Toggle("Suggest code as I type", isOn: Binding(get: { draft.completionsEnabled ?? false }, set: { draft.completionsEnabled = $0 }))
            Text("Uses the selected chat’s agent and model. Suggestions appear after a pause in typing. Press Tab to accept, Escape to dismiss, or Control-Space to request one. Requests use your existing CLI account and usage limits.").foregroundStyle(.secondary).font(.callout)
            Divider()
            Toggle("Format on save", isOn: Binding(get: { draft.ide?.formatOnSave ?? false }, set: { value in if draft.ide == nil { draft.ide = IDEPreferences() }; draft.ide?.formatOnSave = value }))
            Text("Language extensions").font(.headline)
            Text("Language servers provide diagnostics, navigation, completion, formatting, and refactoring. Installed tools run when you open a supported file.").foregroundStyle(.secondary)
            ForEach((draft.ide ?? IDEPreferences()).resolvedExtensions) { item in
                HStack {
                    Toggle(item.name, isOn: Binding(get: { (draft.ide ?? IDEPreferences()).resolvedExtensions.first(where: { $0.id == item.id })?.enabled ?? true }, set: { enabled in
                        var copy = item; copy.enabled = enabled; setExtension(copy)
                    }))
                    Spacer()
                    Text(item.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if ShellEnvironment.locate(item.command, in: model.toolEnvironment) != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            Button("Import language extension…") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    do { var item = try JSONDecoder().decode(IDEExtension.self, from: Data(contentsOf: url)); try item.validate(); item.enabled = false; setExtension(item) }
                    catch { self.error = error.localizedDescription }
                }
            }
            Text("Manifest: id, name, languages (file extensions), command, arguments, enabled. Imports start disabled; enable a tool after reviewing it.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Debugger adapter").font(.headline)
            Text("Go uses the bundled Delve adapter. For other languages, set an adapter executable and its DAP launch configuration.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $debugJSON).font(.system(size: 11, design: .monospaced)).frame(height: 150).padding(6).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            Button("Apply debugger configuration") {
                do { let configuration = try JSONDecoder().decode(DebugConfiguration.self, from: Data(debugJSON.utf8)); if draft.ide == nil { draft.ide = IDEPreferences() }; draft.ide?.debug = configuration }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    private func setExtension(_ item: IDEExtension) {
        if draft.ide == nil { draft.ide = IDEPreferences() }
        draft.ide?.extensions.removeAll { $0.id == item.id }; draft.ide?.extensions.append(item)
    }
    private func connect(_ machine: RemoteMachine, agent: AgentKind?) {
        guard save() else { return }
        do { try model.openRemote(machine, project: project, agent: agent); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func save() -> Bool {
        do { try model.saveTools(draft, for: project); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
