import Foundation

public struct ChatHistoryMatch: Identifiable, Equatable, Sendable {
    public enum Speaker: String, Sendable { case user = "You", assistant = "Agent" }
    public let projectID: UUID
    public let projectName: String
    public let sessionID: UUID
    public let sessionTitle: String
    public let agent: AgentKind
    public let itemID: String
    public let date: Date
    public let speaker: Speaker
    public let snippet: String
    public var id: String { sessionID.uuidString + "/" + itemID }
}

public struct ChatHistoryResults: Sendable {
    public var matches: [ChatHistoryMatch] = []
    public var totalMatches = 0
    public var unreadableConversations = 0
    public init() {}
}

public enum ChatHistorySearch {
    public static func terms(_ query: String) -> [String] {
        String(query.prefix(500)).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func matches(in items: [TranscriptItem], session: SessionMeta, project: Project,
                               query: String, limit: Int = 200) throws -> ChatHistoryResults {
        let terms = terms(query)
        guard !terms.isEmpty, limit > 0 else { return ChatHistoryResults() }
        let limit = min(limit, 500)
        var result = ChatHistoryResults()
        for item in items where item.parentToolID == nil {
            try Task.checkCancellation()
            let text: String, speaker: ChatHistoryMatch.Speaker
            switch item.content {
            case .user(let value, _): text = value; speaker = .user
            case .assistant(let value): text = value; speaker = .assistant
            default: continue
            }
            let ranges = terms.compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            guard ranges.count == terms.count, let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }) else { continue }
            let start = text.index(first.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(start, offsetBy: 230, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = (start > text.startIndex ? "…" : "")
                + text[start..<end].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                + (end < text.endIndex ? "…" : "")
            result.totalMatches += 1
            result.matches.append(ChatHistoryMatch(projectID: project.id, projectName: project.name,
                sessionID: session.id, sessionTitle: session.title, agent: session.agent, itemID: item.id,
                date: item.date, speaker: speaker, snippet: snippet))
            if result.matches.count >= limit * 2 { result.matches = newest(result.matches, limit: limit) }
        }
        result.matches = newest(result.matches, limit: limit)
        return result
    }

    static func newest(_ matches: [ChatHistoryMatch], limit: Int) -> [ChatHistoryMatch] {
        Array(matches.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }.prefix(limit))
    }
}
