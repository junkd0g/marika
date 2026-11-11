import AppKit
import MarikaCore

extension AppModel {
    var allEditors: [CodeWorkspace] { repositoryEditors.values.flatMap { Array($0.values) } }

    func showExperience(_ section: String, project: Project) {
        experienceSection = section; experienceProjectID = project.id
    }
    func selectRepository(_ url: URL, project: Project) {
        guard project.repositoryURLs.contains(url) else { return }
        updateProject(project.id) { $0.selectedRepositoryPath = url.path }
        if let updated = self.project(id: project.id) { _ = editor(for: updated) }
    }
    func attachRepository(to project: Project) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Attach folder"
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL.resolvingSymlinksInPath(),
              !project.repositoryURLs.contains(url) else { return }
        updateProject(project.id) { $0.repositoryPaths = ($0.repositoryPaths ?? []) + [url.path] }
        for session in controllers.values where session.meta.projectID == project.id { session.disconnectWhenIdle() }
        if let current = self.project(id: project.id) { selectRepository(url, project: current) }
    }
    func prepareTurn(_ session: SessionController, input: UserInput) async throws {
        guard let project = project(for: session.meta) else { return }
        if let id = session.meta.agentTask?.designImportID {
            guard project.designImport?.id == id, project.designImport?.status == .running else {
                throw DesignToolError("Start a new import from Design to analyze the project again.")
            }
            return
        }
        // Remote files are not snapshots of the local cache. Never advertise local recovery for them.
        guard project.runtime == nil else { return }
        // Finish an interrupted/failed preparation before starting another baseline.
        await completeTurn(session)
        let roots = session.meta.agentTask?.workspace.map { [URL(fileURLWithPath: $0.workingPath)] } ?? project.repositoryURLs
        let record = try await checkpointService.begin(projectID: project.id, sessionID: session.id, title: input.text, roots: roots)
        activeCheckpoints[session.id] = record.id
        await reloadCheckpoints(project.id)
        try await runHooks(.beforeTurn, session: session, project: project)
    }
    func completeTurn(_ session: SessionController) async {
        if session.meta.agentTask?.designImportID != nil { await finishDesignImport(session); return }
        guard let id = activeCheckpoints.removeValue(forKey: session.id) else { return }
        if let project = project(for: session.meta) {
            do { try await runHooks(.afterTurn, session: session, project: project) }
            catch { session.apply(.notice(Notice(level: .warning, text: "After-turn hook: " + error.localizedDescription))) }
        }
        do {
            let service = checkpointService
            _ = try await Task { try await service.finish(id) }.value
        }
        catch { session.apply(.notice(Notice(level: .warning, text: "Couldn't finish checkpoint: " + error.localizedDescription))) }
        await reloadCheckpoints(session.meta.projectID)
        saveWalkthrough(session)
    }
    private func runHooks(_ event: ProjectHook.Event, session: SessionController, project: Project) async throws {
        let root = session.meta.agentTask?.workspace.map { URL(fileURLWithPath: $0.workingPath) } ?? project.url
        var environment = gitEnvironment
        environment["MARIKA_PROJECT_DIR"] = root.path
        environment["MARIKA_SESSION_ID"] = session.id.uuidString
        for hook in project.tools?.hooks ?? [] where hook.enabled && hook.event == event {
            try Task.checkCancellation()
            try await ProjectSetup.run(command: hook.command, directory: root, environment: environment, timeout: 60)
        }
    }
    func reloadCheckpoints(_ projectID: UUID) async {
        do { checkpointRecords[projectID] = try await checkpointService.list(projectID: projectID) }
        catch { debugErrors[projectID] = error.localizedDescription }
    }
    func restoreCheckpoint(_ record: CodeCheckpoint) async throws {
        guard !controllers.values.contains(where: { $0.meta.projectID == record.projectID && $0.isBusy }),
              debugTasks[record.projectID] == nil else { throw AgentError.launchFailed("Stop running agents and debugging commands before rewinding.") }
        guard !(repositoryEditors[record.projectID]?.values.contains(where: { !$0.modifiedDocuments.isEmpty }) ?? false) else {
            throw AgentError.launchFailed("Save or close your unsaved editor drafts before rewinding.")
        }
        _ = try await checkpointService.restore(record.id)
        for editor in repositoryEditors[record.projectID]?.values ?? [:].values { await editor.refresh() }
        for session in controllers.values where session.meta.projectID == record.projectID {
            session.disconnectWhenIdle()
            session.apply(.notice(Notice(level: .info, text: "Code restored to the checkpoint before: " + record.title + ". Conversation history was kept.")))
            session.apply(.filesChanged)
        }
        await reloadCheckpoints(record.projectID)
    }
    func runDebug(_ command: String, project: Project) {
        guard debugTasks[project.id] == nil, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let environment = gitEnvironment
        debugErrors[project.id] = nil
        debugTasks[project.id] = Task {
            defer { debugTasks[project.id] = nil }
            do {
                let result = try await Command.run(URL(fileURLWithPath: "/bin/zsh"), ["-l", "-c", command],
                    workingDirectory: project.editorURL, environment: environment, timeout: 120, outputLimit: 64_000)
                let run = DebugRun(command: command, directory: project.editorURL.path,
                    output: String((result.output + "\n" + result.errorOutput).suffix(64_000)), exitCode: result.status, timedOut: result.timedOut)
                updateProject(project.id) { $0.debugRuns = Array((($0.debugRuns ?? []) + [run]).suffix(20)) }
            } catch is CancellationError { debugErrors[project.id] = "Reproduction stopped." }
            catch { debugErrors[project.id] = error.localizedDescription }
        }
    }
    func debugWithAgent(_ run: DebugRun, project: Project) {
        guard let session = workspace.conversation(for: project.id) else { return }
        Task {
            await open(session.id)
            guard let controller = controllers[session.id], !controller.isBusy else { return }
            experienceProjectID = nil
            openAgentChat(session.id)
            controller.send(UserInput(text: run.agentPrompt))
        }
    }
    func openRemote(_ machine: RemoteMachine, project: Project, agent: AgentKind? = nil) throws {
        let arguments = try machine.arguments(command: agent.map { $0.executableName })
        ensureTerminal(for: project)
        terminals[project.id]?.addRemote(arguments: arguments, name: machine.name, directory: project.url, environment: gitEnvironment)
        projectSettingsID = nil
        switchPanel(.terminal)
    }

    func saveWalkthrough(_ session: SessionController) {
        guard let project = project(for: session.meta),
              !project.artifacts.orEmpty.contains(where: { $0.sessionID == session.id && $0.kind == .walkthrough && $0.date >= (session.items.last(where: { if case .user = $0.content { return true }; return false })?.date ?? .distantPast) }),
              let item = session.items.reversed().prefix(while: { if case .user = $0.content { return false }; return true })
                .first(where: { if case .assistant = $0.content { return $0.parentToolID == nil }; return false }),
              case .assistant(let text) = item.content, !text.isEmpty else { return }
        let artifact = ProjectArtifact(sessionID: session.id, title: session.meta.title, kind: .walkthrough, body: String(text.prefix(60_000)))
        saveArtifact(artifact, projectID: project.id)
    }
    func recordBrowserEvidence(projectID: UUID, sessionID: UUID, action: String, url: String, image: Data) async {
        guard let project = project(id: projectID) else { return }
        let folder = store.root.appendingPathComponent("browser-evidence", isDirectory: true)
        let filename = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try image.write(to: folder.appendingPathComponent(filename), options: .atomic)
            var artifact = project.artifacts?.last(where: { $0.kind == .browser && $0.sessionID == sessionID })
                ?? ProjectArtifact(sessionID: sessionID, title: "Browser evidence", kind: .browser, body: "# Observed browser actions\n")
            artifact.body = String((artifact.body + "\n- \(Date().formatted(date: .omitted, time: .standard)) · \(action) · \(url)").suffix(16_000))
            artifact.images.append(filename)
            for old in artifact.images.dropLast(20) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
            artifact.images = Array(artifact.images.suffix(20))
            saveArtifact(artifact, projectID: projectID)
        } catch { debugErrors[projectID] = "Browser evidence couldn't be saved: " + error.localizedDescription }
    }
    func submitArtifact(_ artifact: ProjectArtifact, projectID: UUID, approve: Bool) async {
        await open(artifact.sessionID)
        guard let session = controllers[artifact.sessionID], !session.isBusy else { return }
        if approve {
            updateProject(projectID) { current in
                if let index = current.artifacts?.firstIndex(where: { $0.id == artifact.id }) { current.artifacts?[index].approved = true }
            }
            var settings = session.meta.settings; settings.mode = .ask; session.update(settings: settings)
        }
        let prompt = (approve ? "Implement this reviewed plan. Keep changes within its scope and verify the result.\n" : "Revise the artifact using this review.\n")
            + artifact.title + "\n" + artifact.body + "\n\nReview comments:\n" + artifact.feedback
        experienceProjectID = nil
        openAgentChat(session.id)
        session.send(UserInput(text: prompt))
    }
    func saveArtifact(_ artifact: ProjectArtifact, projectID: UUID) {
        let previous = project(id: projectID)?.artifacts ?? []
        let retained = Array((previous.filter { $0.id != artifact.id } + [artifact]).suffix(60))
        let needed = Set(retained.flatMap(\.images))
        updateProject(projectID) { $0.artifacts = retained }
        for name in Set(previous.flatMap(\.images)).subtracting(needed) {
            let file = URL(fileURLWithPath: name)
            guard file.lastPathComponent == name, file.pathExtension == "png",
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            try? FileManager.default.removeItem(at: store.root.appendingPathComponent("browser-evidence").appendingPathComponent(name))
        }
    }
}

private extension Optional where Wrapped == [ProjectArtifact] {
    var orEmpty: [ProjectArtifact] { self ?? [] }
}
