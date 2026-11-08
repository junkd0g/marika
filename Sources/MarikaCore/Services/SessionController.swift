import Foundation
import Observation

/// One session as the app sees it: reduces agent events into a transcript the UI renders.
@MainActor
@Observable
public final class SessionController: Identifiable {
    public typealias AgentFactory = @MainActor (SessionMeta) async throws -> any AgentSession

    public private(set) var meta: SessionMeta
    public private(set) var reportedModel: String?
    public private(set) var items: [TranscriptItem] = []
    public private(set) var phase: AgentPhase = .idle
    public private(set) var approvals: [ApprovalRequest] = []
    public private(set) var todos: [TodoItem] = []
    public private(set) var context: ContextUsage?
    public private(set) var activity: String?
    public private(set) var turnStartedAt: Date?
    /// The mode the running turn started in, for agents that can't change it mid-turn.
    public private(set) var runningMode: ApprovalMode?
    /// Advances whenever files in the project may have changed.
    public private(set) var changeCount = 0

    public var draft: String {
        get { meta.draft?.text ?? "" }
        set {
            var draft = meta.draft ?? SessionDraft()
            draft.text = newValue
            updateDraft(draft)
        }
    }

    public var draftImages: [ImageAttachment] {
        get { meta.draft?.images ?? [] }
        set {
            var draft = meta.draft ?? SessionDraft()
            draft.images = newValue
            updateDraft(draft)
        }
    }

    /// Called when transcript content or session settings change.
    @ObservationIgnored public var onChange: ((SessionController) -> Void)?
    /// Draft edits only change metadata; saving them needn't rewrite a long transcript.
    @ObservationIgnored public var onDraftChange: ((SessionController) -> Void)?
    /// Called when a turn ends or the agent starts waiting, for notifications.
    @ObservationIgnored public var onAttentionNeeded: ((SessionController, Attention) -> Void)?
    @ObservationIgnored public var onRateLimit: ((RateLimitSnapshot) -> Void)?
    @ObservationIgnored public var onCapabilities: ((AgentKind, AgentCapabilities) -> Void)?
    @ObservationIgnored public var beforeTurn: ((SessionController, UserInput) async throws -> Void)?
    @ObservationIgnored public var afterTurn: ((SessionController) async -> Void)?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var connectionEpoch = 0

    public enum Attention: Sendable {
        case approvalNeeded
        case turnFinished(TurnSummary.Outcome)
    }

    public nonisolated var id: UUID { sessionID }

    private struct PendingDelta {
        var isThinking: Bool
        var parentToolID: String?
        var text: String
    }

    private nonisolated let sessionID: UUID
    @ObservationIgnored private let makeAgent: AgentFactory
    @ObservationIgnored private var agent: (any AgentSession)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var itemIndex: [String: Int] = [:]
    @ObservationIgnored private var deltaOrder: [String] = []
    @ObservationIgnored private var deltas: [String: PendingDelta] = [:]
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var disconnectsWhenIdle = false

    /// Text arrives token by token. Batching it keeps long answers from re-rendering on every
    /// token without any visible lag.
    private static let flushInterval: Duration = .milliseconds(33)

    public init(meta: SessionMeta, items: [TranscriptItem] = [], makeAgent: @escaping AgentFactory) {
        sessionID = meta.id
        self.meta = meta
        self.makeAgent = makeAgent
        self.items = items.map(Self.settled)
        todos = meta.taskPlan ?? []
        for (position, item) in self.items.enumerated() { itemIndex[item.id] = position }
        applyQueuedAgentIfIdle()
    }

    /// Nothing can still be in flight in a transcript loaded from disk.
    private static func settled(_ item: TranscriptItem) -> TranscriptItem {
        guard case .tool(var call) = item.content, call.status == .running else { return item }
        call.status = .cancelled
        var updated = item
        updated.content = .tool(call)
        return updated
    }

    public var isBusy: Bool { phase != .idle }
    public var pendingApproval: ApprovalRequest? { approvals.first }
    public var hasStarted: Bool { !items.isEmpty }

    // MARK: Actions

    private func updateDraft(_ draft: SessionDraft) {
        let value = draft.isEmpty ? nil : draft
        guard meta.draft != value else { return }
        meta.draft = value
        onDraftChange?(self)
    }

    public func send(_ input: UserInput) {
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !input.images.isEmpty else { return }
        if meta.agentTask?.workspace?.status == .applied || meta.agentTask?.workspace?.status == .reviewed {
            meta.agentTask?.workspace?.status = .ready
            meta.agentTask?.workspace?.acceptedChanges = nil
            meta.agentTask?.workspace?.rejectedChanges = nil
        }
        if meta.agentTask?.workspace?.status == .discarded {
            addNotice(Notice(level: .error, text: "This agent's worktree was discarded. Start a new agent for another task."))
            return
        }
        if !isBusy { applyQueuedAgentIfIdle() }
        let startsTurn = !isBusy
        let epoch = connectionEpoch
        flushDeltas()
        let handoffItems = meta.needsProviderContext == true ? items : []
        let isFirstMessage = !items.contains { if case .user = $0.content { true } else { false } }
        append(TranscriptItem(id: UUID().uuidString, content: .user(text: input.text, images: input.images)))
        if isFirstMessage {
            if meta.agentTask == nil { meta.title = Self.title(from: input.text) }
            else if meta.title == "New session" { meta.title = AgentTaskName.suggested(from: input.text) }
        }
        meta.updatedAt = Date()
        if meta.agent == .codex, !isBusy { runningMode = meta.mode }
        setPhase(.running)
        onChange?(self)

        let previousPreparation = preparation
        let sending = Task {
            do {
                if startsTurn { await completion?.value }
                else { await previousPreparation?.value }
                try Task.checkCancellation()
                guard epoch == connectionEpoch else { throw CancellationError() }
                if startsTurn, let beforeTurn { try await beforeTurn(self, input) }
                try Task.checkCancellation()
                guard epoch == connectionEpoch else { throw CancellationError() }
                let agent = try await connectedAgent()
                let handoff = meta.needsProviderContext == true
                let outgoing = handoff ? ProviderHandoff.input(input, history: handoffItems, task: meta.agentTask?.prompt) : input
                try await agent.send(outgoing)
                if handoff, epoch == connectionEpoch {
                    meta.needsProviderContext = nil
                    onChange?(self)
                }
            } catch is CancellationError {
                if await agent?.hasActiveTurn() == true { await agent?.interrupt() }
                else {
                    if startsTurn { await afterTurn?(self) }
                    setPhase(.idle)
                }
            } catch {
                // One rejected message doesn't end a turn that is still running.
                let stillRunning = await agent?.hasActiveTurn() ?? false
                if !stillRunning {
                    if startsTurn { await afterTurn?(self) }
                    setPhase(.idle)
                }
                addNotice(Notice(level: .error, text: error.localizedDescription))
            }
        }
        if startsTurn { preparation = sending }
    }

    public func interrupt() {
        preparation?.cancel()
        approvals.removeAll()
        if phase == .waitingForUser { setPhase(.running) }
        activity = "Stopping"
        Task { await agent?.interrupt() }
    }

    public func answer(_ request: ApprovalRequest, with decision: ApprovalDecision) {
        approvals.removeAll { $0.id == request.id }
        if approvals.isEmpty, phase == .waitingForUser { setPhase(.running) }
        switch decision {
        case .approvePlan(let nextMode):
            meta.mode = nextMode ?? .ask
            onChange?(self)
        case .denyWithFeedback(let feedback):
            // The user typed this, so it belongs in the conversation they can see.
            append(TranscriptItem(id: UUID().uuidString, content: .user(text: feedback, images: [])))
            onChange?(self)
        default:
            break
        }
        Task { await agent?.answer(requestID: request.id, decision: decision) }
    }

    public func update(settings: AgentSettings) {
        guard settings != meta.settings else { return }
        meta.settings = settings
        onChange?(self)
        Task { await agent?.update(settings: settings) }
    }

    /// Retains the app conversation, draft and worktree, but never reuses another provider's resume ID.
    @discardableResult public func switchAgent(to kind: AgentKind) -> Bool {
        guard !isBusy, meta.agent != kind, meta.agentTask?.workspace?.status != .discarded else { return false }
        disconnect()
        meta.queuedAgent = nil
        if meta.agentTask != nil { meta.agentHandle = ProjectChat.handle(for: meta) }
        meta.previousProviderCostUSD = meta.totalCostUSD
        meta.agent = kind
        meta.conversationID = nil
        meta.model = nil; meta.effort = nil; meta.serviceTier = nil
        meta.needsProviderContext = hasStarted ? true : nil
        context = nil; todos = []; approvals = []
        if hasStarted {
            append(TranscriptItem(id: UUID().uuidString, content: .notice(Notice(level: .info,
                text: "Switched to \(kind.shortName). Your next message continues with recent conversation context in the same workspace."))))
        }
        meta.updatedAt = Date()
        onChange?(self)
        return true
    }

    @discardableResult public func requestAgentSwitch(to kind: AgentKind) -> Bool {
        guard meta.agentTask?.workspace?.status != .discarded else { return false }
        if isBusy {
            meta.queuedAgent = kind == meta.agent ? nil : kind
            onChange?(self)
            return true
        }
        meta.queuedAgent = nil
        let changed = switchAgent(to: kind)
        if !changed { onChange?(self) }
        return true
    }

    public func cancelAgentSwitch() {
        guard meta.queuedAgent != nil else { return }
        meta.queuedAgent = nil
        onChange?(self)
    }

    private func applyQueuedAgentIfIdle() {
        guard !isBusy, let next = meta.queuedAgent else { return }
        meta.queuedAgent = nil
        if !switchAgent(to: next) { onChange?(self) }
    }

    public func rename(_ title: String) {
        meta.title = title
        onChange?(self)
    }

    public func recordVerification(_ record: TaskVerificationRecord) {
        meta.taskVerification = record
        onChange?(self)
    }

    public func updateAgentWorkspace(_ workspace: AgentWorkspace) {
        meta.agentTask?.workspace = workspace
        if workspace.status == .discarded { meta.queuedAgent = nil }
        onChange?(self)
    }

    public func shutdown() async {
        connectionEpoch += 1
        preparation?.cancel()
        await completion?.value
        eventTask?.cancel()
        await agent?.shutdown()
        agent = nil
        approvals.removeAll()
        setPhase(.idle, appliesQueuedSwitch: false)
    }

    /// Drops the running agent so the next message starts one with fresh credentials.
    public func disconnect() {
        connectionEpoch += 1
        preparation?.cancel()
        reportedModel = nil
        let agent = agent
        self.agent = nil
        eventTask?.cancel()
        eventTask = nil
        Task { await agent?.shutdown() }
    }

    /// Drops the agent as soon as nothing is running, so a busy turn isn't cut off.
    public func disconnectWhenIdle() {
        if isBusy { disconnectsWhenIdle = true } else { disconnect() }
    }

    private func connectedAgent() async throws -> any AgentSession {
        if let agent { return agent }
        let epoch = connectionEpoch
        let agent = try await makeAgent(meta)
        guard epoch == connectionEpoch, !Task.isCancelled else {
            await agent.shutdown()
            throw CancellationError()
        }
        self.agent = agent
        let events = agent.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, self?.connectionEpoch == epoch else { break }
                self?.apply(event)
            }
        }
        return agent
    }

    // MARK: Reducing events

    public func apply(_ event: AgentEvent) {
        switch event {
        case .textDelta(let id, let delta, let parent):
            buffer(id: id, delta: delta, isThinking: false, parent: parent)
            return
        case .thinkingDelta(let id, let delta, let parent):
            buffer(id: id, delta: delta, isThinking: true, parent: parent)
            return
        default:
            flushDeltas()
        }

        switch event {
        case .textDelta, .thinkingDelta:
            break
        case .conversationStarted(let id, let model):
            reportedModel = model
            if meta.conversationID != id {
                meta.conversationID = id
                onChange?(self)
            }
        case .conversationLost:
            meta.conversationID = nil
            onChange?(self)
        case .phaseChanged(let phase):
            setPhase(phase)
        case .modeChanged(let mode):
            if meta.mode != mode {
                meta.mode = mode
                onChange?(self)
            }
        case .modeInForce(let mode):
            runningMode = mode
        case .activity(let activity):
            self.activity = activity
        case .textFinished(let id, let text, let parent):
            clearRetryNotice()
            upsert(id: id, parent: parent, content: .assistant(text: text))
        case .itemRetracted(let id):
            removeItem(id: id)
        case .thinkingFinished(let id, let text, let durationMs, let parent):
            upsert(id: id, parent: parent, content: .thinking(text: text, durationMs: durationMs))
        case .tool(let call):
            clearRetryNotice()
            upsert(call)
        case .toolOutput(let id, let delta):
            updateTool(id) { $0.output += delta }
        case .toolFinished(let id, let output, let status, let diff):
            updateTool(id) { call in
                if !output.isEmpty { call.output = output }
                call.status = status
                call.finishedAt = Date()
                if !diff.isEmpty { call.diff = diff }
            }
            // Long turns are saved as they go, not just when they end.
            onChange?(self)
        case .approvalRequested(let request):
            approvals.append(request)
            setPhase(.waitingForUser)
            onAttentionNeeded?(self, .approvalNeeded)
        case .approvalCancelled(let id):
            approvals.removeAll { $0.id == id }
            if approvals.isEmpty, phase == .waitingForUser { setPhase(.running) }
        case .todosUpdated(let todos):
            self.todos = todos
            meta.taskPlan = todos
            onChange?(self)
        case .notice(let notice):
            addNotice(notice)
        case .contextUsage(let usage):
            context = usage
        case .rateLimit(let snapshot):
            onRateLimit?(snapshot)
        case .capabilities(let capabilities):
            onCapabilities?(meta.agent, capabilities)
        case .filesChanged:
            changeCount += 1
        case .turnFinished(let summary):
            finishTurn(summary)
        case .terminated(let status, let message):
            handleTermination(status: status, message: message)
        }
    }

    private func setPhase(_ phase: AgentPhase, appliesQueuedSwitch: Bool = true) {
        // The CLI reports `running` again right after an approval, and that must not restart
        // the clock for the turn.
        if phase != .idle, turnStartedAt == nil { turnStartedAt = Date() }
        if phase == .idle {
            turnStartedAt = nil
            activity = nil
            runningMode = nil
        }
        self.phase = phase
        if phase == .idle, disconnectsWhenIdle {
            disconnectsWhenIdle = false
            disconnect()
        }
        if phase == .idle, appliesQueuedSwitch, meta.queuedAgent != nil {
            // Run after the current event/error handler has recorded its final output.
            Task { [weak self] in self?.applyQueuedAgentIfIdle() }
        }
    }

    private func finishTurn(_ summary: TurnSummary) {
        clearRetryNotice()
        // A stopped or failed turn won't report on its open tools again. After a completed one they
        // are background work that really is still running, such as a sub-agent or a server.
        if summary.outcome != .completed { closeOpenTools() }
        append(TranscriptItem(id: UUID().uuidString, content: .turnEnd(summary)))
        if let cost = summary.totalCostUSD { meta.totalCostUSD = (meta.previousProviderCostUSD ?? 0) + cost }
        meta.updatedAt = Date()
        changeCount += 1
        onChange?(self)
        onAttentionNeeded?(self, .turnFinished(summary.outcome))
        completion = Task { await afterTurn?(self) }
    }

    private func handleTermination(status: Int32, message: String?) {
        approvals.removeAll()
        agent = nil
        eventTask = nil
        clearRetryNotice()
        let wasRunningCommand = items.contains { $0.tool?.status == .running && $0.tool?.kind == .shell }
        closeOpenTools()
        let lastLine = message?.split(separator: "\n").last.map(String.init)
        var text = "The agent stopped unexpectedly (exit \(status))"
        if let lastLine { text += ": \(lastLine)" }
        if wasRunningCommand { text += ". A command it started may still be running." }
        addNotice(Notice(level: .error, text: text))
        setPhase(.idle)
        onChange?(self)
    }

    private func closeOpenTools() {
        for item in items {
            if let call = item.tool, !call.status.isFinished {
                updateTool(call.id) {
                    $0.status = .cancelled
                    $0.finishedAt = Date()
                }
            }
        }
    }

    private func append(_ item: TranscriptItem) {
        itemIndex[item.id] = items.count
        items.append(item)
    }

    private func upsert(id: String, parent: String?, content: TranscriptItem.Content) {
        if let position = itemIndex[id] {
            items[position].content = content
        } else {
            append(TranscriptItem(id: id, parentToolID: parent, content: content))
        }
    }

    private func upsert(_ call: ToolCall) {
        guard let position = itemIndex[call.id], case .tool(let existing) = items[position].content else {
            append(TranscriptItem(id: call.id, parentToolID: call.parentID, content: .tool(call)))
            return
        }
        var merged = call
        merged.startedAt = existing.startedAt
        merged.output = existing.output
        merged.status = existing.status
        merged.finishedAt = existing.finishedAt
        if merged.diff.isEmpty { merged.diff = existing.diff }
        items[position].content = .tool(merged)
    }

    private func updateTool(_ id: String, _ change: (inout ToolCall) -> Void) {
        guard let position = itemIndex[id], case .tool(var call) = items[position].content else { return }
        change(&call)
        items[position].content = .tool(call)
    }

    private func removeItem(id: String) {
        guard let position = itemIndex[id] else { return }
        items.remove(at: position)
        itemIndex.removeAll(keepingCapacity: true)
        for (position, item) in items.enumerated() { itemIndex[item.id] = position }
    }

    private func addNotice(_ notice: Notice) {
        if let key = notice.key,
            let position = items.lastIndex(where: {
                if case .notice(let existing) = $0.content { existing.key == key } else { false }
            })
        {
            items[position].content = .notice(notice)
        } else {
            append(TranscriptItem(id: UUID().uuidString, content: .notice(notice)))
        }
    }

    private func clearRetryNotice() {
        guard
            let item = items.last(where: {
                if case .notice(let notice) = $0.content { notice.key == "retry" } else { false }
            })
        else { return }
        removeItem(id: item.id)
    }

    // MARK: Delta batching

    private func buffer(id: String, delta: String, isThinking: Bool, parent: String?) {
        if deltas[id] == nil {
            deltas[id] = PendingDelta(isThinking: isThinking, parentToolID: parent, text: delta)
            deltaOrder.append(id)
        } else {
            deltas[id]?.text += delta
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            self?.flushDeltas()
        }
    }

    /// Applies buffered text. Also runs before any other event, so order is preserved.
    public func flushDeltas() {
        flushScheduled = false
        guard !deltaOrder.isEmpty else { return }
        for id in deltaOrder {
            guard let pending = deltas[id] else { continue }
            if let position = itemIndex[id] {
                switch items[position].content {
                case .assistant(let text):
                    items[position].content = .assistant(text: text + pending.text)
                case .thinking(let text, let durationMs):
                    items[position].content = .thinking(text: text + pending.text, durationMs: durationMs)
                default:
                    break
                }
            } else {
                let content: TranscriptItem.Content =
                    pending.isThinking
                    ? .thinking(text: pending.text, durationMs: nil) : .assistant(text: pending.text)
                append(TranscriptItem(id: id, parentToolID: pending.parentToolID, content: content))
            }
        }
        deltas.removeAll(keepingCapacity: true)
        deltaOrder.removeAll(keepingCapacity: true)
    }

    private static func title(from text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "New session"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}
