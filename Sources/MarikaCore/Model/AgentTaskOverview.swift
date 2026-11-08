import Foundation

public struct TaskVerificationRecord: Codable, Equatable, Hashable, Sendable {
    public var date: Date
    public var command: String
    public var output: String
    public var succeeded: Bool?
    public init(command: String, output: String, succeeded: Bool?, date: Date = Date()) {
        self.command = command; self.output = String(output.suffix(64_000)); self.succeeded = succeeded; self.date = date
    }
}

/// Evidence for a task page, kept separate from conclusions about whether the task succeeded.
public struct AgentTaskOverview: Sendable {
    public var changedFiles: [String]
    public var commands: [ToolCall]
    public var activeStep: String?
    public var blockers: [String]
    public init(meta: SessionMeta, items: [TranscriptItem], phase: AgentPhase, approval: ApprovalRequest? = nil, activity: String? = nil) {
        let tools = items.filter { $0.parentToolID == nil }.compactMap(\.tool).filter { $0.parentID == nil }
        changedFiles = Array(Set(tools.filter { $0.status == .succeeded }.flatMap { $0.diff.map { $0.movedTo ?? $0.path } })).sorted()
        commands = Array(tools.filter { $0.kind == .shell && $0.status.isFinished }.suffix(12).reversed())
        let latestTurn = items.reversed().prefix { item in
            if item.parentToolID == nil, case .user = item.content { return false }
            return true
        }
        let presentation = AgentTaskPresentation(meta: meta, items: items, phase: phase, approval: approval, activity: activity)
        if presentation.state.isActive {
            activeStep = activity ?? meta.taskPlan?.first(where: { $0.status == .inProgress })?.text
                ?? latestTurn.compactMap(\.tool).first(where: { $0.status == .running })?.title
        } else { activeStep = nil }
        blockers = approval.map { ["Approval needed: " + $0.title] } ?? []
        if presentation.state == .needsApproval, approval == nil { blockers.append("Open chat to answer the agent's pending request.") }
        if presentation.state == .archived { blockers.append("The isolated workspace was discarded. Start a new task to continue.") }
        if presentation.state == .failed, let preview = presentation.preview { blockers.append(preview) }
    }
}
