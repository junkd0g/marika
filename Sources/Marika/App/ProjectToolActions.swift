import Foundation
import MarikaCore

extension AppModel {
    func ensureTerminal(for project: Project) {
        guard terminals[project.id] == nil else { return }
        let terminal = ProjectTerminal()
        terminals[project.id] = terminal
        terminal.add(at: project.url, name: project.name, environment: gitEnvironment)
    }
    func openTerminal(command: String? = nil) {
        guard let project = selectedProject else { return }
        ensureTerminal(for: project)
        if terminals[project.id]?.current?.view.process.running != true {
            terminals[project.id]?.add(at: project.url, name: project.name, environment: gitEnvironment)
        }
        switchPanel(.terminal)
        if let command { terminals[project.id]?.send(command) }
    }

    func runChatCommand(_ command: ChatTerminalCommand, sessionID: UUID) throws {
        guard let session = controllers[sessionID], let project = project(for: session.meta) else {
            throw AgentError.launchFailed("This chat is no longer available.")
        }
        guard !session.isBusy else { throw AgentError.launchFailed("Wait for the agent to finish before running this command.") }
        let invocation = try command.invocation(project: project, session: session.meta, environment: toolEnvironment)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: invocation.directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentError.launchFailed("The command's working folder no longer exists.")
        }
        let terminal = terminals[project.id] ?? ProjectTerminal()
        terminals[project.id] = terminal
        terminal.run(command, invocation: invocation, environment: toolEnvironment)
        if selectedProject?.id != project.id { openProject(project) }
        switchPanel(.terminal)
    }
    func saveTools(_ tools: ProjectTools, for project: Project) throws {
        _ = try ProjectMCP.servers(tools.mcpConfig)
        for machine in tools.remoteMachines ?? [] { _ = try machine.arguments() }
        guard (tools.memory?.count ?? 0) <= 32_000, (tools.hooks ?? []).allSatisfy({ $0.command.count <= 32_000 }) else {
            throw AgentError.launchFailed("Keep memory and hook commands under 32,000 characters.")
        }
        guard tools.setupCommand.count < 32000, tools.instructions.count <= 64000, tools.schedules.allSatisfy({ $0.prompt.count <= 32000 }), tools.skills.allSatisfy({ $0.instructions.count <= 32000 }) else {
            throw AgentError.launchFailed("Keep setup and each playbook under 32,000 characters.")
        }
        var saved = tools
        for index in saved.schedules.indices {
            guard !saved.schedules[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !saved.schedules[index].prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentError.launchFailed("Give each job a name and task.")
            }
            let next = try saved.schedules[index].nextOccurrence(after: Date())
            if let live = self.project(id: project.id)?.tools?.schedules.first(where: { $0.id == saved.schedules[index].id }) {
                saved.schedules[index].runs = live.runs
                saved.schedules[index].lastError = live.lastError
                if saved.schedules[index].hours == live.hours && saved.schedules[index].enabled == live.enabled && saved.schedules[index].cron == live.cron && saved.schedules[index].timeZoneID == live.timeZoneID {
                    saved.schedules[index].nextRun = live.nextRun
                } else { saved.schedules[index].nextRun = next }
            } else { saved.schedules[index].nextRun = next }
        }
        let liveTools = self.project(id: project.id)?.tools
        let reconnect = liveTools?.instructions != saved.instructions || liveTools?.mcpConfig != saved.mcpConfig
        updateProject(project.id) { $0.tools = saved }
        for (key, ide) in ideWorkspaces where key.hasPrefix(project.id.uuidString) { ide.configure(saved.ide ?? IDEPreferences()) }
        if reconnect {
            for controller in controllers.values where controller.meta.projectID == project.id { controller.disconnectWhenIdle() }
        }
    }
    func startScheduler() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runTaskQueues()
                await self?.runSchedules()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    func runSchedules(now: Date = Date()) async {
        guard !runningSchedules, !workspaceLoadFailed else { return }
        runningSchedules = true
        defer { runningSchedules = false }
        for project in workspace.projects {
            for schedule in project.tools?.schedules ?? [] where schedule.enabled && schedule.nextRun <= now {
                guard !Task.isCancelled else { return }
                if schedule.runs.contains(where: { controllers[$0]?.isBusy == true }) { continue }
                guard controllers.values.filter({ $0.meta.projectID == project.id && $0.meta.agentTask != nil && $0.isBusy }).count < AgentTaskPolicy.maxConcurrent else { continue }
                do {
                    try await executeJob(schedule.id, projectID: project.id, now: now, manual: false)
                } catch {
                    updateSchedule(schedule.id, projectID: project.id) { $0.lastError = error.localizedDescription }
                }
                await save()
            }
        }
    }

    func runJobNow(_ id: UUID, projectID: UUID) async throws {
        do { try await executeJob(id, projectID: projectID, now: Date(), manual: true) }
        catch {
            updateSchedule(id, projectID: projectID) { $0.lastError = error.localizedDescription }
            throw error
        }
    }

    private func executeJob(_ id: UUID, projectID: UUID, now: Date, manual: Bool) async throws {
        guard let project = project(id: projectID), let job = project.tools?.schedules.first(where: { $0.id == id }),
              manual || job.enabled else { return }
        guard !launchingJobs.contains(id), !job.runs.contains(where: { controllers[$0]?.isBusy == true }) else {
            throw AgentError.launchFailed("This job already has an active run.")
        }
        launchingJobs.insert(id)
        defer { launchingJobs.remove(id) }
        let next = manual && job.nextRun > now ? job.nextRun : try job.nextOccurrence(after: now)
        updateSchedule(id, projectID: projectID) { $0.nextRun = next; $0.lastError = nil }
        // Persist the claim before creating a worktree or contacting a provider.
        guard await save() else { throw AgentError.launchFailed("Couldn't save this job's run. Restore saved data before retrying.") }
        guard !Task.isCancelled, self.project(id: projectID)?.tools?.schedules.contains(where: { $0.id == id && (manual || $0.enabled) }) == true else { return }
        let agent = try await launchAgent(in: project, agent: job.agent,
            settings: AgentSettings(model: job.model, mode: .ask), prompt: job.prompt)
        rename(agent.id, to: job.name)
        updateSchedule(id, projectID: projectID) { $0.runs = Array(($0.runs + [agent.id]).suffix(12)) }
        await save()
    }
    private func updateSchedule(_ id: UUID, projectID: UUID, update: (inout ProjectSchedule) -> Void) {
        updateProject(projectID) { project in
            guard let index = project.tools?.schedules.firstIndex(where: { $0.id == id }) else { return }
            update(&project.tools!.schedules[index])
        }
    }
}
