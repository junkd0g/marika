import Foundation

public enum ToolKind: String, Codable, Sendable {
    case shell
    case read
    case edit
    case write
    case search
    case web
    case subagent
    case todo
    case question
    case plan
    case mcp
    case skill
    case other
}

public enum ToolStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case denied
    case cancelled

    public var isFinished: Bool { self != .running }
}

/// One action the agent took, in a form every agent can share.
public struct ToolCall: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ToolKind
    public var title: String
    public var detail: String
    public var input: JSONValue
    public var output: String
    public var status: ToolStatus
    public var diff: [DiffFile]
    public var parentID: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: String, name: String, kind: ToolKind, title: String, detail: String, input: JSONValue = .object([:]),
        output: String = "", status: ToolStatus = .running, diff: [DiffFile] = [], parentID: String? = nil,
        startedAt: Date = Date(), finishedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.title = title
        self.detail = detail
        self.input = input
        self.output = output
        self.status = status
        self.diff = diff
        self.parentID = parentID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct TodoItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress
        case completed
    }

    public var text: String
    public var status: Status

    public var id: String { text }

    public init(text: String, status: Status) {
        self.text = text
        self.status = status
    }
}

public struct Notice: Codable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    public enum Action: String, Codable, Sendable {
        case signIn
    }

    public var level: Level
    public var text: String
    public var action: Action?
    /// Notices sharing a key replace each other, so a retry loop stays one line.
    public var key: String?

    public init(level: Level, text: String, action: Action? = nil, key: String? = nil) {
        self.level = level
        self.text = text
        self.action = action
        self.key = key
    }
}

public struct TurnSummary: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case completed
        case interrupted
        case failed
    }

    public var outcome: Outcome
    public var durationMs: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// The conversation's running total, at API list prices.
    public var totalCostUSD: Double?
    public var message: String?

    public init(
        outcome: Outcome, durationMs: Int? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
        totalCostUSD: Double? = nil, message: String? = nil
    ) {
        self.outcome = outcome
        self.durationMs = durationMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalCostUSD = totalCostUSD
        self.message = message
    }
}

public struct TranscriptItem: Codable, Equatable, Sendable, Identifiable {
    public enum Content: Codable, Equatable, Sendable {
        case user(text: String, images: [ImageAttachment])
        case assistant(text: String)
        case thinking(text: String, durationMs: Int?)
        case tool(ToolCall)
        case notice(Notice)
        case turnEnd(TurnSummary)
    }

    public var id: String
    public var date: Date
    public var parentToolID: String?
    public var content: Content

    public init(id: String, date: Date = Date(), parentToolID: String? = nil, content: Content) {
        self.id = id
        self.date = date
        self.parentToolID = parentToolID
        self.content = content
    }

    public var tool: ToolCall? {
        if case .tool(let call) = content { return call }
        return nil
    }
}
