import Foundation

/// Evidence from the latest finished turn, never from an earlier task in the chat.
public struct TaskCompletionSummary: Sendable {
    public let outcome: TurnSummary.Outcome
    public let finishedAt: Date
    public let changedFiles: [String]
    public let commands: [ToolCall]
    public let reply: String?

    public init?(items: [TranscriptItem]) {
        let top = items.filter { $0.parentToolID == nil }
        let start = top.lastIndex { if case .user = $0.content { true } else { false } } ?? top.startIndex
        let turn = top[start...]
        guard let end = turn.last(where: { if case .turnEnd = $0.content { true } else { false } }),
              case .turnEnd(let summary) = end.content else { return nil }
        outcome = summary.outcome; finishedAt = end.date
        let tools = turn.compactMap(\.tool).filter { $0.parentID == nil }
        changedFiles = Array(Set(tools.filter { $0.status == .succeeded }.flatMap { $0.diff.map { $0.movedTo ?? $0.path } })).sorted()
        commands = tools.filter { $0.kind == .shell && $0.status.isFinished }
        reply = turn.reversed().compactMap { item -> String? in
            if case .assistant(let text) = item.content { return text }
            return nil
        }.first
    }

    public func includes(_ record: TaskVerificationRecord) -> Bool { record.date >= finishedAt }
}
