import Foundation

public struct TaskActivity: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case approval, completed, failed, stopped, queueFailed
        public var title: String {
            switch self {
            case .approval: "Approval requested"
            case .completed: "Task finished"
            case .failed: "Task failed"
            case .stopped: "Task stopped"
            case .queueFailed: "Queued task could not start"
            }
        }
    }
    public var id: String
    public var sessionID: UUID?
    public var queueID: UUID?
    public var kind: Kind
    public var taskTitle: String
    public var detail: String?
    public var date: Date
    public var isRead = false
    public init(id: String, sessionID: UUID?, queueID: UUID? = nil, kind: Kind, taskTitle: String, detail: String? = nil, date: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.queueID = queueID; self.kind = kind
        self.taskTitle = taskTitle; self.detail = detail; self.date = date
    }
    public static func recording(_ event: TaskActivity, in events: [TaskActivity]) -> [TaskActivity] {
        guard !events.contains(where: { $0.id == event.id }) else { return events }
        return Array((events + [event]).suffix(100))
    }
}
