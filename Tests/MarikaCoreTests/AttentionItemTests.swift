import Foundation
import Testing
@testable import MarikaCore

struct AttentionItemTests {
    private let date = Date(timeIntervalSince1970: 1_000)
    private func session(task: Bool = true) -> SessionMeta {
        SessionMeta(projectID: UUID(), agent: .codex, title: "Improve navigation", agentTask: task ? AgentTask(prompt: "Improve navigation") : nil)
    }
    private func evidence(_ state: SessionAttention.State = .completed, changes: Bool = true, id: String = "turn-1") -> SessionAttention {
        SessionAttention(state: state, eventID: id, date: date, detail: "Updated navigation.", hasChanges: changes)
    }

    @Test func liveApprovalsTakePriorityAndCannotBeDismissed() throws {
        var meta = session(); meta.dismissedAttentionEvent = "Needs approval:approval"
        let item = try #require(AttentionItem.current(meta: meta, evidence: evidence(.failed), phase: .running,
            approval: ApprovalRequest(id: "approval", toolKind: .shell, title: "Run tests")))
        #expect(item.kind == .approval && !item.canDismiss && item.detail == "Run tests")
        #expect(AttentionItem.current(meta: meta, evidence: evidence(.failed), phase: .running) == nil)
        #expect(AttentionItem.current(meta: meta, evidence: evidence(), phase: .waitingForUser)?.kind == .input)
    }

    @Test func busyWorkHidesOldFailuresAndRestartedWorkOffersRecovery() {
        let meta = session()
        #expect(AttentionItem.current(meta: meta, evidence: evidence(.failed), phase: .running) == nil)
        #expect(AttentionItem.current(meta: meta, evidence: evidence(.working))?.kind == .blocked)
        #expect(AttentionItem.current(meta: meta, evidence: evidence(.idle)) == nil)
        #expect(AttentionItem.current(meta: meta, evidence: nil) == nil)
    }

    @Test func ordinaryRepliesStayOutOfTheInboxButEditedWorkNeedsReview() {
        let meta = session(task: false)
        #expect(AttentionItem.current(meta: meta, evidence: evidence(changes: false)) == nil)
        #expect(AttentionItem.current(meta: meta, evidence: evidence())?.kind == .review)
        #expect(AttentionItem.current(meta: session(), evidence: evidence(changes: false))?.kind == .review)
    }

    @Test func failureAndStoppedWorkRemainActionable() {
        for state in [SessionAttention.State.failed, .stopped] {
            #expect(AttentionItem.current(meta: session(), evidence: evidence(state))?.kind == .blocked)
        }
    }

    @Test func checksUseLatestTurnAndClearWhileRerunningOrAfterPassing() {
        var meta = session()
        meta.taskVerification = TaskVerificationRecord(command: "swift test", output: "Failed", succeeded: false, date: date.addingTimeInterval(1))
        #expect(AttentionItem.current(meta: meta, evidence: evidence())?.kind == .checks)
        #expect(AttentionItem.current(meta: meta, evidence: evidence(), checksRunning: true) == nil)
        meta.taskVerification?.succeeded = nil
        #expect(AttentionItem.current(meta: meta, evidence: evidence())?.kind == .checks)
        meta.taskVerification?.succeeded = true
        #expect(AttentionItem.current(meta: meta, evidence: evidence())?.kind == .review)
        meta.taskVerification?.succeeded = false; meta.taskVerification?.date = date.addingTimeInterval(-1)
        #expect(AttentionItem.current(meta: meta, evidence: evidence())?.kind == .review)
    }

    @Test func dismissalPersistsButANewRunOrCheckFailureReturns() throws {
        var meta = session()
        let first = try #require(AttentionItem.current(meta: meta, evidence: evidence(.failed)))
        meta.dismissedAttentionEvent = first.eventID; meta.attention = evidence(.failed)
        let restored = try JSONDecoder().decode(SessionMeta.self, from: JSONEncoder().encode(meta))
        #expect(AttentionItem.current(meta: restored, evidence: restored.attention) == nil)
        #expect(AttentionItem.current(meta: restored, evidence: evidence(.failed, id: "turn-2")) != nil)
        meta.taskVerification = TaskVerificationRecord(command: "swift test", output: "Failed", succeeded: false, date: date.addingTimeInterval(1))
        let checks = try #require(AttentionItem.current(meta: meta, evidence: evidence()))
        meta.dismissedAttentionEvent = checks.eventID
        #expect(AttentionItem.current(meta: meta, evidence: evidence()) == nil)
        meta.taskVerification?.date = date.addingTimeInterval(2)
        #expect(AttentionItem.current(meta: meta, evidence: evidence())?.kind == .checks)
    }

    @Test func ticketsOnlyShowTheirLatestUnacceptedRun() {
        let meta = session()
        var ticket = SpaceTicket(key: "WORK-1", title: "Improve navigation")
        let work = TicketWork(sessionID: meta.id, projectID: meta.projectID, contextDigest: "context")
        ticket.work = [work]
        #expect(AttentionItem.current(meta: meta, evidence: evidence(), ticket: ticket)?.ticketID == ticket.id)
        ticket.work?[0].acceptedAt = date
        #expect(AttentionItem.current(meta: meta, evidence: evidence(), ticket: ticket) == nil)
        ticket.work = [work]; ticket.status = .done
        #expect(AttentionItem.current(meta: meta, evidence: evidence(), ticket: ticket) == nil)
        ticket.status = .inProgress; ticket.archived = true
        #expect(AttentionItem.current(meta: meta, evidence: evidence(.failed), ticket: ticket) == nil)
        ticket.archived = false
        ticket.work?.append(TicketWork(sessionID: UUID(), projectID: meta.projectID, contextDigest: "new"))
        #expect(AttentionItem.current(meta: meta, evidence: evidence(.failed), ticket: ticket) == nil)
        #expect(AttentionItem.current(meta: meta, evidence: evidence(), phase: .waitingForUser, ticket: ticket)?.kind == .input)
    }

    @Test func checkDismissalUsesTheStoresDatePrecision() throws {
        var meta = session(); meta.attention = evidence()
        meta.taskVerification = TaskVerificationRecord(command: "swift test", output: "Failed", succeeded: false, date: date.addingTimeInterval(1.75))
        meta.dismissedAttentionEvent = try #require(AttentionItem.current(meta: meta, evidence: meta.attention)).eventID
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(SessionMeta.self, from: encoder.encode(meta))
        #expect(AttentionItem.current(meta: restored, evidence: restored.attention) == nil)
    }

    @Test func reviewedOrDiscardedWorkDoesNotKeepRequestingReview() {
        var meta = session()
        meta.agentTask?.workspace = AgentWorkspace(rootPath: "/tmp/project", workingPath: "/tmp/work", branch: "task", baseCommit: "base")
        for state in [AgentWorkspace.Status.reviewed, .applied, .discarded] {
            meta.agentTask?.workspace?.status = state
            #expect(AttentionItem.current(meta: meta, evidence: evidence()) == nil)
        }
    }

    @Test func orderingPutsApprovalsBeforeBlockersAndReview() throws {
        let review = try #require(AttentionItem.current(meta: session(), evidence: evidence()))
        let failure = try #require(AttentionItem.current(meta: session(), evidence: evidence(.failed)))
        let approval = try #require(AttentionItem.current(meta: session(), evidence: evidence(), phase: .waitingForUser))
        #expect(AttentionItem.sorted([review, failure, approval]).map(\.kind) == [.input, .blocked, .review])
    }
}
