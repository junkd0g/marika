import Foundation
import Testing
@testable import MarikaCore

struct AgentTaskPresentationTests {
    private var meta: SessionMeta { SessionMeta(projectID: UUID(), agent: .codex, agentTask: AgentTask(prompt: "Original task")) }
    private func item(_ content: TranscriptItem.Content, parent: String? = nil) -> TranscriptItem {
        TranscriptItem(id: UUID().uuidString, parentToolID: parent, content: content)
    }

    @Test func terminalErrorsNeedAttentionWithOrWithoutATurnEnd() {
        var items = [item(.user(text: "Run tests", images: [])), item(.notice(Notice(level: .error, text: "Runner unavailable")))]
        var status = AgentTaskPresentation(meta: meta, items: items, phase: .idle)
        #expect(status.state == .failed && status.preview == "Runner unavailable")
        #expect(AgentTaskFilter.needsAttention.includes(status.state))
        #expect(!AgentTaskFilter.finished.includes(status.state))
        items.append(item(.turnEnd(TurnSummary(outcome: .failed))))
        status = AgentTaskPresentation(meta: meta, items: items, phase: .idle)
        #expect(status.state == .failed && status.preview == "Runner unavailable")
    }

    @Test func liveActivityAndApprovalTakePriorityOverPreviousFailures() {
        let items = [item(.notice(Notice(level: .error, text: "Old failure")))]
        let running = AgentTaskPresentation(meta: meta, items: items, phase: .running, activity: "Retrying")
        #expect(running.state == .working && running.preview == "Retrying")
        let waiting = AgentTaskPresentation(meta: meta, items: items, phase: .waitingForUser, approval: ApprovalRequest(id: "r", title: "Run command?"))
        #expect(waiting.state == .needsApproval && waiting.preview == "Approval needed: Run command?")
        #expect(AgentTaskFilter.active.includes(waiting.state))
        #expect(AgentTaskFilter.needsAttention.includes(waiting.state))
        #expect(!AgentTaskFilter.finished.includes(waiting.state))
    }

    @Test func completedPreviewsUseTheLatestRootResultAndIgnoreResolvedErrors() {
        let items = [item(.user(text: "Fix", images: [])), item(.notice(Notice(level: .error, text: "Temporary failure"))),
                     item(.assistant(text: "## Summary\n\nUpdated empty states.\nVerified compact layout.")),
                     item(.assistant(text: "Internal child result"), parent: "tool"), item(.turnEnd(TurnSummary(outcome: .completed)))]
        let status = AgentTaskPresentation(meta: meta, items: items, phase: .idle)
        #expect(status.state == .completed)
        #expect(status.preview == "Updated empty states. Verified compact layout.")
        #expect(AgentTaskFilter.finished.includes(status.state))
        #expect(!AgentTaskFilter.needsAttention.includes(status.state))
    }

    @Test func followUpsNeverShowAStaleResultAsTheNewOutcome() {
        let items = [item(.assistant(text: "Previous result")), item(.turnEnd(TurnSummary(outcome: .completed))),
                     item(.user(text: "Try something else", images: [])), item(.turnEnd(TurnSummary(outcome: .interrupted)))]
        let status = AgentTaskPresentation(meta: meta, items: items, phase: .idle)
        #expect(status.state == .stopped)
        #expect(status.preview == "Task stopped before producing a result.")
        #expect(AgentTaskFilter.finished.includes(status.state))
        #expect(!AgentTaskFilter.needsAttention.includes(status.state))
    }

    @Test func discardedAndUnstartedTasksHaveDistinctStates() {
        var task = meta
        #expect(AgentTaskPresentation(meta: task, items: [], phase: .idle).state == .idle)
        #expect(!AgentTaskFilter.finished.includes(.idle))
        task.agentTask?.workspace = AgentWorkspace(rootPath: "/tmp/task", workingPath: "/tmp/task", branch: "task", baseCommit: "abc")
        task.agentTask?.workspace?.status = .discarded
        #expect(AgentTaskPresentation(meta: task, items: [], phase: .idle).state == .archived)
    }

    @Test func suggestedNamesAreShortWithoutSplittingFilenamesOrUnicode() {
        #expect(AgentTaskName.suggested(from: "Review this project's code health. First call a tool.") == "Review this project's code health")
        #expect(AgentTaskName.suggested(from: "Fix App.swift loading states") == "Fix App.swift loading states")
        #expect(AgentTaskName.suggested(from: "   \n ") == "New task")
        let title = AgentTaskName.suggested(from: "Implement empty and loading states for the dashboard and cover both layouts")
        #expect(title == "Implement empty and loading states for…")
        #expect(AgentTaskName.suggested(from: String(repeating: "🦊", count: 60)).count <= 43)
    }

    @MainActor @Test func taskNamesSurviveFirstSendAndFollowUps() async {
        var task = meta
        task.title = "Dashboard states"
        let controller = SessionController(meta: task) { _ in IdleAgent() }
        controller.send(UserInput(text: "A long detailed task that should never replace the chosen name"))
        #expect(controller.meta.title == "Dashboard states")
        controller.rename("UI polish")
        controller.send(UserInput(text: "Follow-up"))
        #expect(controller.meta.title == "UI polish")
        #expect(ProjectChat.handle(for: controller.meta) == ProjectChat.handle(for: task))
        await controller.shutdown()
    }
}
