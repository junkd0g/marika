import Foundation

public enum AgentTaskState: String, Sendable, CaseIterable {
    case working = "Working", needsApproval = "Needs approval", failed = "Failed"
    case completed = "Completed", stopped = "Stopped", idle = "Ready", archived = "Archived"

    public var isActive: Bool { self == .working || self == .needsApproval }
    public var needsAttention: Bool { self == .failed || self == .needsApproval }
}

public enum AgentTaskFilter: String, CaseIterable, Sendable {
    case all = "All", active = "Active", needsAttention = "Needs attention", finished = "Finished"

    public func includes(_ state: AgentTaskState) -> Bool {
        switch self {
        case .all: true
        case .active: state.isActive
        case .needsAttention: state.needsAttention
        case .finished: state == .completed || state == .stopped || state == .archived
        }
    }
}

/// One interpretation of task activity and results for both Chat and Agents.
public struct AgentTaskPresentation: Equatable, Sendable {
    public let state: AgentTaskState
    public let preview: String?

    public init(meta: SessionMeta, items: [TranscriptItem], phase: AgentPhase,
                approval: ApprovalRequest? = nil, activity: String? = nil) {
        let turn = items.reversed().prefix { item in
            if item.parentToolID == nil, case .user = item.content { return false }
            return true
        }.filter { $0.parentToolID == nil }
        let terminalError = turn.compactMap { item -> String? in
            if case .notice(let notice) = item.content, notice.level == .error { return notice.text }
            return nil
        }.first
        var settled: AgentTaskState = .idle
        var error: String?
        for item in turn {
            if case .notice(let notice) = item.content, notice.level == .error {
                settled = .failed; error = notice.text; break
            }
            if case .turnEnd(let summary) = item.content {
                settled = summary.outcome == .completed ? .completed : summary.outcome == .interrupted ? .stopped : .failed
                error = summary.message ?? terminalError
                break
            }
        }
        if meta.agentTask?.workspace?.status == .discarded { state = .archived }
        else if approval != nil || phase == .waitingForUser { state = .needsApproval }
        else if phase == .running { state = .working }
        else { state = settled }

        let reply = turn.compactMap { item -> String? in
            if case .assistant(let text) = item.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            return nil
        }.first
        switch state {
        case .working: preview = activity ?? "Working on the task…"
        case .needsApproval: preview = approval.map { "Approval needed: " + $0.title } ?? "Open chat to respond."
        case .failed: preview = error ?? reply.map(Self.summary) ?? "The task failed. Open chat for details."
        case .completed: preview = reply.map(Self.summary) ?? "Task completed. Open chat for details."
        case .stopped: preview = reply.map(Self.summary) ?? "Task stopped before producing a result."
        case .archived: preview = "The isolated workspace was discarded."
        case .idle: preview = meta.agentTask.map { Self.summary($0.prompt) }
        }
    }

    private static func summary(_ text: String) -> String {
        let blocks = MarkdownParser.parse(String(text.prefix(4000)))
        let prose = blocks.compactMap { block -> String? in
            switch block {
            case .paragraph(let value), .quote(let value): value
            case .list(let items): items.prefix(3).map(\.text).joined(separator: " · ")
            default: nil
            }
        }.first ?? "Result available in chat."
        let compact = prose.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > 240 ? String(compact.prefix(239)) + "…" : compact
    }
}

public enum AgentTaskName {
    public static func suggested(from prompt: String) -> String {
        var line = prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "New task"
        guard !line.isEmpty else { return "New task" }
        if let end = line.range(of: #"[.!?](?:\s|$)"#, options: .regularExpression) { line = String(line[..<end.lowerBound]) }
        let words = line.split(whereSeparator: \.isWhitespace)
        var result = ""
        for word in words.prefix(6) {
            let candidate = result.isEmpty ? String(word) : result + " " + word
            if candidate.count > 42 { break }
            result = candidate
        }
        if result.isEmpty { result = String(line.prefix(41)) }
        return result.count < line.count ? result + "…" : result
    }
}
