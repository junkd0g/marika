import Foundation

/// Project-local addressing shared by the chat navigator and composer.
public enum ProjectChat {
    public struct RoutedMessage: Equatable, Sendable {
        public var sessionID: UUID
        public var text: String
    }

    public enum RoutingError: LocalizedError, Equatable {
        case unknownAgent(String), ambiguousAgent(String), discardedAgent, emptyMessage

        public var errorDescription: String? {
            switch self {
            case .unknownAgent(let name): "No agent named @\(name) in this project. Choose an agent from the mention list."
            case .ambiguousAgent(let name): "More than one @\(name) is in this project. Choose a specific agent from the mention list."
            case .discardedAgent: "This agent's workspace was discarded. Start a new agent to continue."
            case .emptyMessage: "Write a message after the agent's @mention."
            }
        }
    }

    /// Stable across renaming and app restarts; human-readable provider plus session identity.
    public static func handle(for session: SessionMeta) -> String {
        session.agentHandle ?? (session.agent.rawValue + "-" + session.id.uuidString.prefix(8).lowercased())
    }

    public static func agents(in projectID: UUID, sessions: [SessionMeta], matching query: String = "") -> [SessionMeta] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions.filter {
            $0.projectID == projectID && $0.agentTask != nil && $0.agentTask?.workspace?.status != .discarded
                && (query.isEmpty || ($0.title + " " + handle(for: $0)).lowercased().contains(query))
        }.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.updatedAt > $1.updatedAt
        }
    }

    /// Only a leading mention addresses a DM. Mentions in ordinary prose remain ordinary text.
    public static func route(_ text: String, in projectID: UUID, sessions: [SessionMeta]) throws -> RoutedMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else { return nil }
        let end = trimmed.firstIndex(where: { $0.isWhitespace }) ?? trimmed.endIndex
        let token = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]).lowercased()
        let candidates = sessions.filter {
            $0.projectID == projectID && $0.agentTask != nil && (handle(for: $0) == token || $0.agent.rawValue == token)
        }
        guard !candidates.isEmpty else { throw RoutingError.unknownAgent(token) }
        guard candidates.count == 1, let target = candidates.first else { throw RoutingError.ambiguousAgent(token) }
        guard target.agentTask?.workspace?.status != .discarded else { throw RoutingError.discardedAgent }
        let message = trimmed[end...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw RoutingError.emptyMessage }
        return RoutedMessage(sessionID: target.id, text: message)
    }

    public static func unreadCount(in items: [TranscriptItem], since date: Date?) -> Int {
        guard let date else { return 0 } // Older workspaces don't start with every reply unread.
        var count = 0, hasReply = false, hasUnreadReply = false
        for item in items where item.parentToolID == nil {
            switch item.content {
            case .assistant(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                hasReply = true
                if item.date > date { count += 1; hasUnreadReply = true }
            case .turnEnd:
                // Streaming can start while visible and finish after the user switches away.
                if item.date > date && hasReply && !hasUnreadReply { count += 1 }
                hasReply = false; hasUnreadReply = false
            default: break
            }
        }
        return count
    }
}
