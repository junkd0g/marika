import Foundation

/// Small persisted evidence for the latest turn; the inbox never opens every agent to build its list.
public struct SessionAttention: Codable, Equatable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case working, completed, failed, stopped, idle }
    public var state: State
    public var eventID: String
    public var date: Date
    public var detail: String?
    public var hasChanges: Bool
    public init(state: State, eventID: String, date: Date, detail: String? = nil, hasChanges: Bool = false) {
        self.state = state; self.eventID = eventID; self.date = date
        self.detail = detail.map { String($0.prefix(500)) }; self.hasChanges = hasChanges
    }
}

public struct AttentionItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case approval = "Needs approval", input = "Needs input", blocked = "Blocked"
        case checks = "Checks need attention", review = "Ready to review"
        public var rank: Int { Self.allCases.firstIndex(of: self)! }
    }
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let projectID: UUID
    public let ticketID: UUID?
    public let title: String
    public let kind: Kind
    public let detail: String
    public let date: Date
    public let eventID: String
    public var canDismiss: Bool { kind != .approval && kind != .input }

    public static func current(meta: SessionMeta, evidence: SessionAttention?, phase: AgentPhase = .idle,
                               approval: ApprovalRequest? = nil, checksRunning: Bool = false,
                               ticket: SpaceTicket? = nil) -> AttentionItem? {
        func item(_ kind: Kind, _ detail: String, date: Date, event: String) -> AttentionItem? {
            let token = kind.rawValue + ":" + event
            guard !((kind != .approval && kind != .input) && meta.dismissedAttentionEvent == token) else { return nil }
            return AttentionItem(sessionID: meta.id, projectID: meta.projectID, ticketID: ticket?.id,
                title: ticket.map { $0.key + " · " + $0.displayTitle } ?? meta.title, kind: kind,
                detail: detail, date: date, eventID: token)
        }
        if let approval { return item(.approval, approval.title, date: meta.updatedAt, event: approval.id) }
        if phase == .waitingForUser { return item(.input, "Open the agent's chat to respond.", date: meta.updatedAt, event: "input") }
        guard phase == .idle, meta.agentTask?.workspace?.status != .discarded else { return nil }
        if let ticket {
            guard !ticket.archived, ticket.work?.last?.sessionID == meta.id else { return nil }
        }
        guard let evidence else { return nil }
        if evidence.state == .working {
            return item(.blocked, "This run was interrupted when the app closed. Open the chat to continue.", date: evidence.date, event: evidence.eventID)
        }
        if evidence.state == .failed || evidence.state == .stopped {
            return item(.blocked, evidence.detail ?? "Open the agent's chat to continue this work.", date: evidence.date, event: evidence.eventID)
        }
        guard evidence.state == .completed, !checksRunning else { return nil }
        if let record = meta.taskVerification, record.date >= evidence.date, record.succeeded != true {
            return item(.checks, record.succeeded == false ? "Checks failed. Review the output and run them again after fixing the issue." : "Checks were incomplete. Review the output and try again.",
                        date: record.date, event: evidence.eventID + ":" + String(Int64(record.date.timeIntervalSince1970)))
        }
        if let ticket {
            guard ticket.status != .done, ticket.work?.last?.acceptedAt == nil else { return nil }
        } else {
            guard meta.agentTask != nil || evidence.hasChanges else { return nil }
            guard meta.agentTask?.workspace?.status != .reviewed, meta.agentTask?.workspace?.status != .applied else { return nil }
        }
        return item(.review, evidence.detail ?? "Review the agent's result and changes.", date: evidence.date, event: evidence.eventID)
    }

    public static func sorted(_ items: [AttentionItem]) -> [AttentionItem] {
        items.sorted {
            if $0.kind.rank != $1.kind.rank { return $0.kind.rank < $1.kind.rank }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
