import Foundation

/// Everything an agent can tell the app, normalised across agents.
public enum AgentEvent: Sendable {
    /// The agent's own conversation id, used to resume it later.
    case conversationStarted(id: String, model: String?)
    /// The agent no longer has this conversation, so the next message has to start a new one.
    case conversationLost
    case phaseChanged(AgentPhase)
    case modeChanged(ApprovalMode)
    /// The mode the running turn really has, for agents that can't change it mid-turn.
    case modeInForce(ApprovalMode?)
    /// A short description of what is happening, for the status line.
    case activity(String?)

    case textDelta(id: String, delta: String, parentToolID: String?)
    case textFinished(id: String, text: String, parentToolID: String?)
    /// Something shown so far was abandoned, because the agent is retrying from the start.
    case itemRetracted(id: String)
    case thinkingDelta(id: String, delta: String, parentToolID: String?)
    case thinkingFinished(id: String, text: String, durationMs: Int?, parentToolID: String?)

    /// A tool call started or gained detail. Upserted by id.
    case tool(ToolCall)
    case toolOutput(id: String, delta: String)
    case toolFinished(id: String, output: String, status: ToolStatus, diff: [DiffFile])

    case approvalRequested(ApprovalRequest)
    case approvalCancelled(id: String)

    case todosUpdated([TodoItem])
    case notice(Notice)
    case contextUsage(ContextUsage)
    case rateLimit(RateLimitSnapshot)
    case capabilities(AgentCapabilities)
    /// The working tree probably changed.
    case filesChanged

    case turnFinished(TurnSummary)
    case terminated(status: Int32, message: String?)
}
