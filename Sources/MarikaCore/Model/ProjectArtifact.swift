import Foundation

public struct ArtifactComment: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var line: Int
    public var text: String
    public init(line: Int, text: String) { self.line = line; self.text = text }
}

public struct ProjectArtifact: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case plan = "Plan", walkthrough = "Walkthrough", browser = "Browser evidence", deliverable = "Deliverable" }
    public var id = UUID()
    public var sessionID: UUID
    public var date = Date()
    public var title: String
    public var kind: Kind
    public var body: String
    public var approved = false
    public var comments: [ArtifactComment] = []
    public var images: [String] = []
    public var deliverable: Deliverable?
    public init(sessionID: UUID, title: String, kind: Kind, body: String) {
        self.sessionID = sessionID; self.title = title; self.kind = kind; self.body = body
    }
    public static func validated(sessionID: UUID, title: String, kind: String, body: String) throws -> ProjectArtifact {
        guard let type = Kind(rawValue: kind), [.plan, .walkthrough].contains(type), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 180, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 100_000 else {
            throw AgentError.launchFailed("Provide a Plan or Walkthrough, a title under 180 characters, and nonempty Markdown under 100 KB.")
        }
        return ProjectArtifact(sessionID: sessionID, title: title, kind: type, body: body)
    }
    public var feedback: String {
        let lines = body.components(separatedBy: "\n")
        return comments.map { comment in
            let quote = lines.indices.contains(comment.line - 1) ? lines[comment.line - 1] : ""
            return "Line \(comment.line): \(quote)\nFeedback: \(comment.text)"
        }.joined(separator: "\n\n")
    }
}
