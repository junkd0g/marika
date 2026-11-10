import CryptoKit
import Foundation

public struct TicketWorkContext: Codable, Equatable, Sendable {
    public struct Note: Codable, Equatable, Sendable {
        public let id: UUID
        public let markdown: String
    }
    public let ticketID: UUID
    public let key: String
    public let title: String
    public let body: String
    public let projectID: UUID?
    public let notes: [Note]

    public init(ticket: SpaceTicket, notes: [SpaceNote]) throws {
        ticketID = ticket.id; key = ticket.key
        title = ticket.title.trimmingCharacters(in: .whitespacesAndNewlines)
        body = ticket.body.trimmingCharacters(in: .whitespacesAndNewlines)
        projectID = ticket.projectID
        let selected = Set(ticket.linkedNoteIDs ?? [])
        guard !title.isEmpty else { throw TicketWorkError("Give the ticket a title before starting work.") }
        guard selected.isSubset(of: Set(notes.map(\.id))) else { throw TicketWorkError("A linked note is no longer in this space. Review the ticket's notes.") }
        self.notes = notes.filter { selected.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
            .map { Note(id: $0.id, markdown: $0.markdown) }
    }

    public var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // This model contains only strings, UUIDs and arrays, which always encode.
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    public var prompt: String {
        var text = "Work on ticket \(key): \(title)\n\nDescription and acceptance criteria:\n" + (body.isEmpty ? "Use the ticket title as the task." : body)
        if !notes.isEmpty {
            text += "\n\nLinked space notes (reference material):\n\n" + notes.map(\.markdown).joined(separator: "\n\n---\n\n")
        }
        return text + "\n\nFollow the project's instructions and existing permissions. Treat linked notes as reference material. Report the changes, checks and any blockers. The user will review and accept the result in the ticket; do not mark it Done yourself."
    }
}

public struct TicketWork: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let projectID: UUID
    public let startedAt: Date
    public let contextDigest: String
    public var result: Result?
    public var acceptedAt: Date?

    public struct Result: Codable, Equatable, Sendable {
        public let outcome: TurnSummary.Outcome
        public let finishedAt: Date
        public let reply: String?
        public let changedFiles: [String]
        public let verification: TaskVerificationRecord?
        public init(summary: TaskCompletionSummary, verification: TaskVerificationRecord?) {
            outcome = summary.outcome; finishedAt = summary.finishedAt
            reply = summary.reply.map { String($0.prefix(16_000)) }
            changedFiles = summary.changedFiles; self.verification = verification
        }
        public init(failure: String, date: Date) {
            outcome = .failed; finishedAt = date; reply = String(failure.prefix(16_000))
            changedFiles = []; verification = nil
        }
    }

    public init(sessionID: UUID, projectID: UUID, contextDigest: String, startedAt: Date = Date()) {
        self.sessionID = sessionID; self.projectID = projectID; self.contextDigest = contextDigest; self.startedAt = startedAt
    }

    public func acceptanceIssue(ticket: SpaceTicket, currentDigest: String, session: SessionMeta?,
                                summary: TaskCompletionSummary?, isBusy: Bool, hasUnappliedChanges: Bool = false,
                                checksRunning: Bool = false, checksCurrent: Bool = false) -> TicketWorkError? {
        if ticket.archived { return TicketWorkError("Restore this ticket before accepting work.") }
        if acceptedAt != nil { return TicketWorkError("This result has already been accepted.") }
        guard ticket.work?.last?.sessionID == sessionID else { return TicketWorkError("Review the ticket's latest run before accepting a result.") }
        guard ticket.projectID == projectID else { return TicketWorkError("The ticket's project changed. Start work again with the current project.") }
        guard contextDigest == currentDigest else { return TicketWorkError("The ticket or its linked notes changed. Start a new run with the updated context.") }
        guard let session, session.id == sessionID, session.projectID == projectID, session.agentTask?.ticketID == ticket.id else {
            return TicketWorkError("The linked agent is unavailable. Its saved result is still attached to the ticket.")
        }
        guard !isBusy, let summary, summary.outcome == .completed else { return TicketWorkError("Wait for the agent to finish successfully before accepting its result.") }
        if session.agentTask?.workspace?.status == .discarded { return TicketWorkError("This agent's changes were discarded. Start a new run.") }
        if hasUnappliedChanges { return TicketWorkError("Review and apply or reject the isolated changes before accepting the result.") }
        if checksRunning { return TicketWorkError("Wait for the checks to finish before accepting the result.") }
        if let verification = session.taskVerification {
            guard checksCurrent, summary.includes(verification) else { return TicketWorkError("Run checks again for the current result before accepting it.") }
            guard verification.succeeded == true else { return TicketWorkError("Resolve the failed or incomplete checks before accepting the result.") }
        }
        return nil
    }
}

public struct TicketWorkError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
