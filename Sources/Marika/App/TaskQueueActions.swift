import Foundation
import MarikaCore

extension AppModel {
    func enqueueTask(in project: Project, agent: AgentKind, settings: AgentSettings, prompt: String, name: String,
                     isolated: Bool, parentSessionID: UUID?, research: ResearchTaskReference? = nil) async throws {
        let item = try QueuedAgentTask(title: name, prompt: prompt, agent: agent, settings: settings, isolated: isolated,
            parentSessionID: parentSessionID, research: research)
        guard let current = self.project(id: project.id), !isShuttingDown else { throw AgentError.launchFailed("This project is unavailable.") }
        var queue = current.taskQueue ?? AgentTaskQueue()
        try queue.append(item)
        updateProject(project.id) { $0.taskQueue = queue }
        guard await save() else { throw AgentError.launchFailed("Couldn't save the queued task. It will not start until saving succeeds.") }
        Task { await runTaskQueues() }
    }

    func updateTaskQueue(_ projectID: UUID, _ change: (inout AgentTaskQueue) -> Void) {
        updateProject(projectID) { project in
            var queue = project.taskQueue ?? AgentTaskQueue(); change(&queue); project.taskQueue = queue
        }
    }

    func setTaskQueuePaused(_ paused: Bool, projectID: UUID) {
        updateTaskQueue(projectID) { $0.isPaused = paused }
        if !paused { Task { await runTaskQueues() } }
    }

    func recoverTaskQueues() {
        let sessions = workspace.sessions
        for project in workspace.projects where project.taskQueue != nil {
            updateTaskQueue(project.id) { $0.recover(sessions: sessions.filter { $0.projectID == project.id }) }
        }
    }

    func runTaskQueues() async {
        guard !runningTaskQueues, !isShuttingDown, isReady, !workspaceLoadFailed else { return }
        runningTaskQueues = true
        defer { runningTaskQueues = false }
        for projectID in workspace.projects.map(\.id) {
            while !isShuttingDown, let project = project(id: projectID), let next = project.taskQueue?.next {
                let active = controllers.values.count { $0.meta.projectID == projectID && $0.meta.agentTask != nil && $0.isBusy }
                let reserved = launchingProjects.values.count { $0 == projectID }
                guard active + reserved < AgentTaskPolicy.maxConcurrent else { break }
                updateTaskQueue(projectID) { queue in
                    if let index = queue.items.firstIndex(where: { $0.id == next.id }) { queue.items[index].state = .launching }
                }
                // Persist the claim before worktree creation or provider usage.
                guard await save() else {
                    updateTaskQueue(projectID) { queue in
                        if let index = queue.items.firstIndex(where: { $0.id == next.id }) { queue.items[index].state = .queued }
                        queue.isPaused = true
                    }
                    break
                }
                guard !isShuttingDown, self.project(id: projectID)?.taskQueue?.isPaused == false else {
                    updateTaskQueue(projectID) { queue in
                        if let index = queue.items.firstIndex(where: { $0.id == next.id && $0.state == .launching }) { queue.items[index].state = .queued }
                    }
                    _ = await save(); break
                }
                // A manual launch may have occupied the last slot while the claim was saved.
                let nowActive = controllers.values.count { $0.meta.projectID == projectID && $0.meta.agentTask != nil && $0.isBusy }
                let nowReserved = launchingProjects.values.count { $0 == projectID }
                if nowActive + nowReserved >= AgentTaskPolicy.maxConcurrent {
                    updateTaskQueue(projectID) { queue in
                        if let index = queue.items.firstIndex(where: { $0.id == next.id }) { queue.items[index].state = .queued }
                    }
                    _ = await save(); break
                }
                do {
                    let session = try await launchAgent(in: project, agent: next.agent, settings: next.settings,
                        prompt: next.prompt, parentSessionID: next.parentSessionID, isolated: next.isolated, name: next.title, queueID: next.id)
                    updateTaskQueue(projectID) { queue in
                        if let index = queue.items.firstIndex(where: { $0.id == next.id }) {
                            queue.items[index].state = .launched; queue.items[index].sessionID = session.id; queue.items[index].error = nil
                        }
                    }
                    if let reference = next.research {
                        updateProject(projectID) { current in
                            guard let index = current.research?.firstIndex(where: { $0.id == reference.runID }) else { return }
                            var links = current.research?[index].implementationTasks ?? [:]; links[reference.findingID] = session.id
                            current.research?[index].implementationTasks = links
                        }
                    }
                } catch {
                    updateTaskQueue(projectID) { queue in
                        if let index = queue.items.firstIndex(where: { $0.id == next.id }) {
                            queue.items[index].state = .failed; queue.items[index].error = error.localizedDescription
                        }
                        queue.isPaused = true
                    }
                    let eventID = "queue-" + next.id.uuidString + "-" + UUID().uuidString
                    recordTaskActivity(TaskActivity(id: eventID, sessionID: nil,
                        queueID: next.id, kind: .queueFailed, taskTitle: next.title, detail: error.localizedDescription), projectID: projectID)
                    notify(title: "Queued task could not start", body: next.title, projectID: projectID, eventID: eventID)
                }
                _ = await save()
            }
        }
    }

    func recordTaskActivity(_ event: TaskActivity, projectID: UUID) {
        updateProject(projectID) { $0.taskActivity = TaskActivity.recording(event, in: $0.taskActivity ?? []) }
    }

    func markTaskActivityRead(_ id: String?, projectID: UUID) {
        updateProject(projectID) { project in
            guard var events = project.taskActivity else { return }
            for index in events.indices where id == nil || events[index].id == id { events[index].isRead = true }
            project.taskActivity = events
        }
    }

    func openTaskActivity(_ eventID: String, projectID: UUID) {
        guard let project = project(id: projectID), let event = project.taskActivity?.first(where: { $0.id == eventID }) else { return }
        markTaskActivityRead(eventID, projectID: projectID)
        taskActivityProjectID = nil
        if let id = event.sessionID, let session = workspace.sessions.first(where: { $0.id == id }) {
            if event.kind == .approval || session.agentTask == nil { openAgentChat(id) }
            else { selectedAgentTaskIDs[projectID] = id; showAgents(for: project) }
        } else if event.queueID != nil { taskQueueProjectID = projectID }
    }
}
