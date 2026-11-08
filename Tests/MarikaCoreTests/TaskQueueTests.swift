import Foundation
import Testing
@testable import MarikaCore

struct TaskQueueTests {
    private func task(_ title: String) throws -> QueuedAgentTask {
        try QueuedAgentTask(title: title, prompt: "Inspect the fixture", agent: .codex, settings: AgentSettings(model: "model", mode: .ask))
    }

    @Test func queueIsFIFOAndPausedQueuesCannotStart() throws {
        var queue = AgentTaskQueue()
        let first = try task("First"), second = try task("Second"), third = try task("Third")
        try queue.append(first); try queue.append(second); try queue.append(third)
        #expect(queue.next?.id == first.id && queue.pendingCount == 3)
        queue.isPaused = true
        #expect(queue.next == nil)
        queue.move(third.id, offset: -1); queue.move(third.id, offset: -1)
        #expect(queue.items.map(\.id) == [third.id, first.id, second.id])
        queue.isPaused = false
        #expect(queue.next?.id == third.id)
        queue.cancel(third.id)
        #expect(queue.next?.id == first.id && queue.pendingCount == 2)
    }

    @Test func recoveryLinksDurableLaunchesAndRequiresExplicitRetryForUnknownOnes() throws {
        var queue = AgentTaskQueue()
        var first = try task("Saved launch"), unknown = try task("Uncertain launch")
        first.state = .launching; unknown.state = .launching
        try queue.append(first); try queue.append(unknown)
        var session = SessionMeta(projectID: UUID(), agent: .codex, agentTask: AgentTask(prompt: first.prompt))
        session.agentTask?.queueID = first.id
        queue.recover(sessions: [session])
        #expect(queue.items[0].state == .launched && queue.items[0].sessionID == session.id)
        #expect(queue.items[1].state == .failed && queue.items[1].error?.contains("interrupted") == true)
        #expect(queue.isPaused && queue.next == nil)
        queue.retry(unknown.id)
        #expect(queue.items[1].state == .queued && queue.items[1].error == nil && queue.next == nil)
        queue.isPaused = false
        #expect(queue.next?.id == unknown.id)
    }

    @Test func claimedAndLaunchedTasksCannotBeCancelledOrReorderedAsWaitingTasks() throws {
        var queue = AgentTaskQueue()
        var claimed = try task("Claimed"), started = try task("Started")
        claimed.state = .launching; started.state = .launched; started.sessionID = UUID()
        try queue.append(claimed); try queue.append(started)
        queue.cancel(claimed.id); queue.cancel(started.id); queue.move(claimed.id, offset: 1)
        #expect(queue.items[0].state == .launching && queue.items[1].state == .launched)
    }

    @Test func queueBoundsWaitingWorkAndTrimsFinishedHistory() throws {
        var queue = AgentTaskQueue()
        for index in 0..<50 { try queue.append(task("Task \(index)")) }
        #expect(throws: AgentError.self) { try queue.append(task("Overflow")) }
        for item in queue.items { queue.cancel(item.id) }
        try queue.append(task("New task"))
        #expect(queue.items.count == 31 && queue.pendingCount == 1)
        #expect(throws: AgentError.self) { try QueuedAgentTask(title: "Name", prompt: " ", agent: .codex, settings: AgentSettings()) }
    }

    @Test func queueSettingsProvenanceAndActivitySurviveWorkspaceReload() throws {
        var project = Project(path: "/tmp/task-queue")
        var queue = AgentTaskQueue()
        let reference = ResearchTaskReference(runID: UUID(), findingID: "F1")
        let item = try QueuedAgentTask(title: "Research follow-up", prompt: "Implement the finding", agent: .claude,
            settings: AgentSettings(model: "model", effort: "high", mode: .ask), parentSessionID: UUID(), research: reference)
        try queue.append(item); project.taskQueue = queue
        project.taskActivity = [TaskActivity(id: "event", sessionID: UUID(), kind: .completed, taskTitle: "Task")]
        let workspace = Workspace(projects: [project])
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(decoded == workspace && decoded.projects.first?.taskQueue?.items.first?.research == reference)
        let old = Project(path: "/tmp/older")
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(old)).taskQueue == nil)
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"defaultAgent":"claude","defaultMode":"ask","claudeBilling":"subscription"}"#.utf8))
        #expect(prefs.taskNotifications == nil)
    }

    @Test func activityDeduplicatesDeliveryAndRetainsOnlyRecentEvents() {
        let event = TaskActivity(id: "same", sessionID: UUID(), kind: .approval, taskTitle: "Task")
        var events = TaskActivity.recording(event, in: [])
        events[0].isRead = true
        #expect(TaskActivity.recording(event, in: events) == events)
        for index in 0..<110 { events = TaskActivity.recording(TaskActivity(id: "e\(index)", sessionID: nil, queueID: UUID(), kind: .queueFailed, taskTitle: "Task"), in: events) }
        #expect(events.count == 100 && events.first?.id == "e10" && events.last?.id == "e109")
    }
}
