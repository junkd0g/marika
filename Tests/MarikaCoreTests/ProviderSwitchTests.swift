import Foundation
import Testing
@testable import MarikaCore

private actor HandoffAgent: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>
    private let sink: AsyncStream<AgentEvent>.Continuation
    private(set) var inputs: [UserInput] = []
    private(set) var stopped = false
    var failNext = false
    private let holdsTurn: Bool
    init(holdsTurn: Bool = false) {
        self.holdsTurn = holdsTurn
        (events, sink) = AsyncStream.makeStream(of: AgentEvent.self)
    }
    func rejectNext() { failNext = true }
    func send(_ input: UserInput) async throws {
        if failNext { failNext = false; throw AgentError.launchFailed("Synthetic send failure") }
        inputs.append(input)
        if !holdsTurn { sink.yield(.phaseChanged(.idle)) }
    }
    func finish() {
        sink.yield(.turnFinished(TurnSummary(outcome: .completed)))
        sink.yield(.phaseChanged(.idle))
    }
    func interrupt() async {}
    func hasActiveTurn() async -> Bool { false }
    func answer(requestID: String, decision: ApprovalDecision) async {}
    func update(settings: AgentSettings) async {}
    func shutdown() async {
        stopped = true
        sink.yield(.conversationStarted(id: "stale-provider-id", model: "stale"))
        sink.finish()
    }
}

@MainActor struct ProviderSwitchTests {
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Condition did not complete")
    }

    @Test func switchingKeepsConversationDraftTaskAndStableMentionButClearsHarnessSettings() throws {
        var meta = SessionMeta(projectID: UUID(), agent: .claude, title: "Inspect routes", conversationID: "claude-id",
            model: "claude-model", effort: "high", mode: .plan, draft: SessionDraft(text: "Keep this draft"),
            agentTask: AgentTask(prompt: "Inspect routes", parentSessionID: UUID()), serviceTier: "priority")
        let originalHandle = ProjectChat.handle(for: meta)
        meta.agentTask?.workspace = AgentWorkspace(rootPath: "/tmp/project", workingPath: "/tmp/worktree", branch: "task", baseCommit: "abc")
        let workspace = meta.agentTask?.workspace
        let history = [TranscriptItem(id: "user", content: .user(text: "Inspect routes", images: [])),
                       TranscriptItem(id: "reply", content: .assistant(text: "Found a route"))]
        let controller = SessionController(meta: meta, items: history) { _ in IdleAgent() }
        #expect(controller.switchAgent(to: .codex))
        meta = controller.meta
        #expect(meta.id == controller.id && meta.title == "Inspect routes")
        #expect(meta.agent == .codex && meta.conversationID == nil)
        #expect(meta.model == nil && meta.effort == nil && meta.serviceTier == nil && meta.mode == .plan)
        #expect(controller.draft == "Keep this draft" && meta.agentTask?.prompt == "Inspect routes")
        #expect(meta.agentTask?.workspace == workspace)
        #expect(Array(controller.items.prefix(2)) == history)
        #expect(ProjectChat.handle(for: meta) == originalHandle)
        #expect(try ProjectChat.route("@\(originalHandle) continue", in: meta.projectID, sessions: [meta])?.sessionID == meta.id)
        let reloaded = try JSONDecoder().decode(SessionMeta.self, from: JSONEncoder().encode(meta))
        #expect(reloaded.needsProviderContext == true && reloaded.agentHandle == originalHandle)
        #expect(controller.switchAgent(to: .claude))
        #expect(controller.meta.agent == .claude && controller.meta.conversationID == nil)
    }

    @Test func busyTurnsAndDiscardedWorkspacesCannotSwitch() {
        let controller = SessionController(meta: SessionMeta(projectID: UUID(), agent: .claude)) { _ in IdleAgent() }
        controller.apply(.phaseChanged(.running))
        #expect(!controller.switchAgent(to: .codex))
        #expect(controller.meta.agent == .claude)
        controller.apply(.phaseChanged(.waitingForUser))
        #expect(!controller.switchAgent(to: .codex))
        controller.apply(.phaseChanged(.idle))
        #expect(controller.switchAgent(to: .codex))
        var discarded = SessionMeta(projectID: UUID(), agent: .claude, agentTask: AgentTask(prompt: "Old task"))
        discarded.agentTask?.workspace = AgentWorkspace(rootPath: "/tmp/project", workingPath: "/tmp/gone", branch: "old", baseCommit: "abc")
        discarded.agentTask?.workspace?.status = .discarded
        let old = SessionController(meta: discarded) { _ in IdleAgent() }
        #expect(!old.switchAgent(to: .codex))
    }

    @Test func eachNewProviderGetsContextOnceAndFailedSendsRetainTheHandoff() async throws {
        let first = HandoffAgent(), second = HandoffAgent()
        var launches: [SessionMeta] = []
        let controller = SessionController(meta: SessionMeta(projectID: UUID(), agent: .claude)) { meta in
            launches.append(meta)
            return meta.agent == .claude ? first : second
        }
        controller.send(UserInput(text: "Original request"))
        try await waitUntil { await first.inputs.count == 1 && !controller.isBusy }
        controller.apply(.textFinished(id: "answer", text: "Original answer", parentToolID: nil))
        controller.apply(.conversationStarted(id: "old-id", model: "old-model"))
        #expect(controller.switchAgent(to: .codex))
        await second.rejectNext()
        controller.send(UserInput(text: "Attempt"))
        try await waitUntil { !controller.isBusy }
        #expect(controller.meta.needsProviderContext == true)
        controller.send(UserInput(text: "Continue"))
        try await waitUntil { await second.inputs.count == 1 && !controller.isBusy }
        let transferred = try #require(await second.inputs.first)
        #expect(transferred.text.contains("Original request") && transferred.text.contains("Original answer"))
        #expect(transferred.text.hasSuffix("Continue"))
        #expect(controller.meta.needsProviderContext == nil)
        #expect(launches.last?.agent == .codex && launches.last?.conversationID == nil)
        #expect(controller.meta.conversationID == nil, "Late events from the old provider must not overwrite the new harness")
        #expect(await first.stopped)
        controller.send(UserInput(text: "Next turn"))
        try await waitUntil { await second.inputs.count == 2 }
        #expect(await second.inputs.last?.text == "Next turn")
        #expect(controller.items.contains { if case .user(let text, _) = $0.content { return text == "Continue" }; return false })
        #expect(!controller.items.contains { if case .user(let text, _) = $0.content { return text.contains("Conversation excerpts:") }; return false })
        await controller.shutdown()
    }

    @Test func handoffExcludesThinkingAndBoundsLargeHistory() {
        let items = [TranscriptItem(id: "thinking", content: .thinking(text: "PRIVATE_THINKING", durationMs: nil))] +
            (0..<12).map { TranscriptItem(id: "\($0)", content: .assistant(text: String(repeating: "🦊", count: 15_000))) }
        let result = ProviderHandoff.input(UserInput(text: "Current instruction"), history: items, task: "Original task")
        #expect(!result.text.contains("PRIVATE_THINKING"))
        #expect(result.text.count < 50_000 && result.text.hasSuffix("Current instruction"))
        #expect(result.text.contains("Original task"))
    }

    @Test func reportedCostsAccumulateAcrossFreshProviderHarnesses() {
        let controller = SessionController(meta: SessionMeta(projectID: UUID(), agent: .claude, totalCostUSD: 3.5)) { _ in IdleAgent() }
        #expect(controller.switchAgent(to: .codex))
        controller.apply(.turnFinished(TurnSummary(outcome: .completed, totalCostUSD: 2)))
        #expect(controller.meta.totalCostUSD == 5.5)
        #expect(controller.switchAgent(to: .claude))
        controller.apply(.turnFinished(TurnSummary(outcome: .completed, totalCostUSD: 1)))
        #expect(controller.meta.totalCostUSD == 6.5)
    }

    @Test func queuedSwitchKeepsSteeringOnTheCurrentProviderThenHandsOffTheNextTurn() async throws {
        let first = HandoffAgent(holdsTurn: true), second = HandoffAgent()
        let controller = SessionController(meta: SessionMeta(projectID: UUID(), agent: .claude)) { meta in
            meta.agent == .claude ? first : second
        }
        controller.send(UserInput(text: "Start"))
        try await waitUntil { await first.inputs.count == 1 }
        #expect(controller.requestAgentSwitch(to: .codex))
        #expect(controller.meta.agent == .claude && controller.meta.queuedAgent == .codex && controller.isBusy)
        controller.send(UserInput(text: "Steer this turn"))
        try await waitUntil { await first.inputs.count == 2 }
        #expect(await second.inputs.isEmpty)
        await first.finish()
        try await waitUntil { !controller.isBusy && controller.meta.agent == .codex }
        #expect(controller.meta.queuedAgent == nil)
        controller.send(UserInput(text: "Next turn"))
        try await waitUntil { await second.inputs.count == 1 && !controller.isBusy }
        let input = try #require(await second.inputs.first)
        #expect(input.text.contains("Start") && input.text.contains("Steer this turn") && input.text.hasSuffix("Next turn"))
        #expect(await first.inputs.count == 2)
        await controller.shutdown()
    }

    @Test func aQueuedSwitchCanBeCancelledAndSurvivesRestartWithoutResumingTheOldHarness() throws {
        var meta = SessionMeta(projectID: UUID(), agent: .claude, conversationID: "old-id", mode: .plan)
        let history = [TranscriptItem(id: "user", content: .user(text: "Existing task", images: []))]
        let controller = SessionController(meta: meta, items: history) { _ in IdleAgent() }
        controller.apply(.phaseChanged(.waitingForUser))
        controller.requestAgentSwitch(to: .codex)
        #expect(controller.meta.agent == .claude && controller.meta.queuedAgent == .codex)
        controller.cancelAgentSwitch()
        #expect(controller.meta.queuedAgent == nil && controller.isBusy)
        controller.requestAgentSwitch(to: .codex)
        controller.requestAgentSwitch(to: .claude)
        #expect(controller.meta.queuedAgent == nil)
        controller.requestAgentSwitch(to: .codex)
        meta = try JSONDecoder().decode(SessionMeta.self, from: JSONEncoder().encode(controller.meta))
        let reopened = SessionController(meta: meta, items: history) { _ in IdleAgent() }
        #expect(reopened.meta.agent == .codex && reopened.meta.conversationID == nil)
        #expect(reopened.meta.queuedAgent == nil && reopened.meta.needsProviderContext == true && reopened.meta.mode == .plan)
    }

    @Test func sendingImmediatelyAfterIdleCannotRaceOrLoseAQueuedHandoff() async throws {
        let next = HandoffAgent()
        var launched: SessionMeta?
        let history = [TranscriptItem(id: "user", content: .user(text: "Original task", images: []))]
        let controller = SessionController(meta: SessionMeta(projectID: UUID(), agent: .claude), items: history) { meta in
            launched = meta; return next
        }
        controller.apply(.phaseChanged(.running))
        controller.requestAgentSwitch(to: .codex)
        controller.apply(.phaseChanged(.idle))
        controller.send(UserInput(text: "Immediate follow-up"))
        try await waitUntil { await next.inputs.count == 1 && !controller.isBusy }
        #expect(launched?.agent == .codex && launched?.conversationID == nil)
        #expect(await next.inputs.first?.text.hasSuffix("Immediate follow-up") == true)
        #expect(controller.meta.queuedAgent == nil)
        await controller.shutdown()
    }

    @Test func failedTurnsApplyTheQueueAfterTheirErrorAndShutdownKeepsAnUnfinishedQueue() async throws {
        let first = HandoffAgent()
        await first.rejectNext()
        let controller = SessionController(meta: SessionMeta(projectID: UUID(), agent: .claude)) { _ in first }
        controller.send(UserInput(text: "Fail this turn"))
        controller.requestAgentSwitch(to: .codex)
        try await waitUntil { !controller.isBusy && controller.meta.agent == .codex }
        #expect(controller.notices.first?.text == "Synthetic send failure")
        #expect(controller.notices.last?.text.hasPrefix("Switched to Codex") == true)
        controller.apply(.phaseChanged(.running))
        controller.requestAgentSwitch(to: .claude)
        await controller.shutdown()
        #expect(controller.meta.queuedAgent == .claude && controller.meta.agent == .codex)
    }
}
