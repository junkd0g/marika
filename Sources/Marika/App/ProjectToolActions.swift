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
            if let live = self.project(id: project.id)?.tools?.schedules.first(where: { $0.id == saved.schedules[index].id }) {
                saved.schedules[index].runs = live.runs
                saved.schedules[index].lastError = live.lastError
                if saved.schedules[index].hours == live.hours && saved.schedules[index].enabled == live.enabled {
                    saved.schedules[index].nextRun = live.nextRun
                }
            }
        }
        updateProject(project.id) { $0.tools = saved }
        for (key, ide) in ideWorkspaces where key.hasPrefix(project.id.uuidString) { ide.configure(saved.ide ?? IDEPreferences()) }
        for controller in controllers.values where controller.meta.projectID == project.id { controller.disconnectWhenIdle() }
    }
    func startScheduler() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
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
                updateSchedule(schedule.id, projectID: project.id) {
                    $0.nextRun = now.addingTimeInterval(Double(max(1, schedule.hours)) * 3600)
                    $0.lastError = nil
                }
                // Persist the claim before starting work so a restart does not launch it twice.
                guard await save() else { return }
                guard !Task.isCancelled, self.project(id: project.id)?.tools?.schedules.contains(where: { $0.id == schedule.id && $0.enabled }) == true else { continue }
                do {
                    let agent = try await launchAgent(in: project, agent: schedule.agent,
                        settings: AgentSettings(model: schedule.model, mode: .ask), prompt: schedule.prompt)
                    updateSchedule(schedule.id, projectID: project.id) { $0.runs = Array(($0.runs + [agent.id]).suffix(12)) }
                } catch {
                    updateSchedule(schedule.id, projectID: project.id) { $0.lastError = error.localizedDescription }
                }
                await save()
            }
        }
    }
    private func updateSchedule(_ id: UUID, projectID: UUID, update: (inout ProjectSchedule) -> Void) {
        updateProject(projectID) { project in
            guard let index = project.tools?.schedules.firstIndex(where: { $0.id == id }) else { return }
            update(&project.tools!.schedules[index])
        }
    }
}
