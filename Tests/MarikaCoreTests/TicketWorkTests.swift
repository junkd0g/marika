import Foundation
import Testing
@testable import MarikaCore

struct TicketWorkTests {
    @Test @MainActor func idlePhaseNotifiesLinkedWorkAfterTheTerminalEvent() {
        let session = SessionMeta(projectID: UUID(), agent: .codex)
        let controller = SessionController(meta: session) { _ in throw AgentError.launchFailed("Unused fixture agent") }
        var snapshots: [Bool] = []
        controller.onPhaseChange = { snapshots.append(!$0.isBusy && TaskCompletionSummary(items: $0.items)?.outcome == .completed) }
        controller.apply(.phaseChanged(.running))
        controller.apply(.turnFinished(TurnSummary(outcome: .completed)))
        #expect(snapshots == [false])
        controller.apply(.phaseChanged(.idle))
        #expect(snapshots == [false, true])
        controller.apply(.phaseChanged(.idle))
        #expect(snapshots == [false, true])
    }

    private func fixture() throws -> (SpaceTicket, TicketWork, SessionMeta, TaskCompletionSummary) {
        var ticket = SpaceTicket(key: "WORK-1", title: "Fix the welcome screen")
        ticket.projectID = UUID(); ticket.body = "Show the next setup step."
        let context = try TicketWorkContext(ticket: ticket, notes: [])
        let work = TicketWork(sessionID: UUID(), projectID: ticket.projectID!, contextDigest: context.digest)
        ticket.work = [work]
        var session = SessionMeta(id: work.sessionID, projectID: work.projectID, agent: .codex, agentTask: AgentTask(prompt: context.prompt))
        session.agentTask?.ticketID = ticket.id
        return (ticket, work, session, try summary(.completed))
    }
    private func summary(_ outcome: TurnSummary.Outcome) throws -> TaskCompletionSummary {
        try #require(TaskCompletionSummary(items: [
            TranscriptItem(id: "user", content: .user(text: "Fix the welcome screen", images: [])),
            TranscriptItem(id: "edit", content: .tool(ToolCall(id: "edit", name: "edit", kind: .edit, title: "Fix setup", detail: "", status: .succeeded, diff: [DiffFile(path: "Welcome.swift")]))),
            TranscriptItem(id: "answer", content: .assistant(text: "Updated the welcome checklist.")),
            TranscriptItem(id: "end", content: .turnEnd(TurnSummary(outcome: outcome))),
        ]))
    }

    @Test func oldTicketsDecodeWithoutWorkOrNotes() throws {
        let ticket = SpaceTicket(key: "OLD-1", title: "Existing ticket")
        let data = try JSONEncoder().encode(ticket)
        let restored = try JSONDecoder().decode(SpaceTicket.self, from: data)
        #expect(restored.linkedNoteIDs == nil && restored.work == nil)
        let task = try JSONDecoder().decode(AgentTask.self, from: Data(#"{"prompt":"Existing task"}"#.utf8))
        #expect(task.ticketID == nil)
    }

    @Test func onlySelectedNotesEnterThePromptAndDigestIgnoresSelectionOrder() throws {
        var ticket = SpaceTicket(key: "WORK-1", title: "Improve setup")
        ticket.body = "## Acceptance criteria\nShow the next action."
        let first = SpaceNote(title: "Design decisions", blocks: [SpaceNoteBlock(text: "Use a clear checklist.")])
        let second = SpaceNote(title: "Copy", blocks: [SpaceNoteBlock(text: "Keep the wording short.")])
        let privateNote = SpaceNote(title: "Unselected", blocks: [SpaceNoteBlock(text: "Do not include this note.")])
        ticket.linkedNoteIDs = [second.id, first.id]
        let context = try TicketWorkContext(ticket: ticket, notes: [privateNote, first, second])
        #expect(context.prompt.contains(ticket.key) && context.prompt.contains(ticket.body))
        #expect(context.prompt.contains(first.markdown) && context.prompt.contains(second.markdown))
        #expect(!context.prompt.contains(privateNote.markdown))
        ticket.linkedNoteIDs?.reverse(); ticket.status = .inProgress; ticket.assignee = "Jordan"
        #expect(try TicketWorkContext(ticket: ticket, notes: [second, first]).digest == context.digest)
        #expect(throws: TicketWorkError.self) { try TicketWorkContext(ticket: ticket, notes: [first]) }
    }

    @Test func requirementsAndLinkedNoteEditsInvalidateTheLaunchContext() throws {
        var ticket = SpaceTicket(key: "WORK-1", title: "Improve setup")
        var note = SpaceNote(title: "Plan")
        ticket.linkedNoteIDs = [note.id]
        let digest = try TicketWorkContext(ticket: ticket, notes: [note]).digest
        note.blocks[0].text = "A new requirement"
        #expect(try TicketWorkContext(ticket: ticket, notes: [note]).digest != digest)
        let current = try TicketWorkContext(ticket: ticket, notes: [note]).digest
        ticket.body = "Updated acceptance criteria"
        #expect(try TicketWorkContext(ticket: ticket, notes: [note]).digest != current)
    }

    @Test func acceptanceRequiresLatestLinkedSuccessfulIdleWork() throws {
        let (ticket, work, session, completed) = try fixture()
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false) == nil)
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: true) != nil)
        for outcome in [TurnSummary.Outcome.failed, .interrupted] {
            #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: session, summary: try summary(outcome), isBusy: false) != nil)
        }
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: nil, summary: completed, isBusy: false) != nil)
        var unrelated = session; unrelated.agentTask?.ticketID = UUID()
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: unrelated, summary: completed, isBusy: false) != nil)
        var newer = ticket; newer.work?.append(TicketWork(sessionID: UUID(), projectID: work.projectID, contextDigest: work.contextDigest))
        #expect(work.acceptanceIssue(ticket: newer, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false) != nil)
    }

    @Test func acceptanceRejectsChangedRequirementsProjectsAndUnappliedChanges() throws {
        let (ticket, work, session, completed) = try fixture()
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: "changed", session: session, summary: completed, isBusy: false) != nil)
        var moved = ticket; moved.projectID = nil
        #expect(work.acceptanceIssue(ticket: moved, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false) != nil)
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false, hasUnappliedChanges: true) != nil)
        var archived = ticket; archived.archived = true
        #expect(work.acceptanceIssue(ticket: archived, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false) != nil)
    }

    @Test func acceptanceUsesCurrentPassingChecksWhenChecksExist() throws {
        let (ticket, work, original, completed) = try fixture()
        var session = original
        session.taskVerification = TaskVerificationRecord(command: "swift test", output: "Passed", succeeded: true, date: .distantFuture)
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false, checksCurrent: true) == nil)
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false, checksCurrent: false) != nil)
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false, checksRunning: true, checksCurrent: true) != nil)
        for result in [false, nil] as [Bool?] {
            session.taskVerification?.succeeded = result
            #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false, checksCurrent: true) != nil)
        }
        session.taskVerification?.succeeded = true; session.taskVerification?.date = .distantPast
        #expect(work.acceptanceIssue(ticket: ticket, currentDigest: work.contextDigest, session: session, summary: completed, isBusy: false, checksCurrent: true) != nil)
    }

    @Test func workAndSavedResultsSurviveSpaceMergeAndRestart() throws {
        var (ticket, work, session, completed) = try fixture()
        let note = SpaceNote(title: "Design")
        var source = ProjectSpace(name: "Work", notes: [note], tickets: [])
        let target = ProjectSpace(name: "Team")
        var project = Project(id: work.projectID, path: "/project"); project.spaceID = source.id
        work.result = TicketWork.Result(summary: completed, verification: nil); work.acceptedAt = Date()
        ticket.work = [work]; ticket.linkedNoteIDs = [note.id]; source.tickets = [ticket]
        session.agentTask?.ticketID = ticket.id
        var workspace = Workspace(projects: [project], sessions: [session], spaces: [source, target])
        #expect({ workspace.deleteSpace(source.id, movingProjectsTo: target.id) }())
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        let saved = try #require(restored.spaces[0].tickets.first)
        #expect(saved.work == [work] && saved.linkedNoteIDs == [note.id])
        #expect(saved.work?.last?.result?.changedFiles == ["Welcome.swift"])
        #expect(restored.sessions[0].agentTask?.ticketID == ticket.id)
    }

    @Test func projectMovesDetachTheProjectAndPreserveRunHistory() throws {
        var (ticket, work, _, completed) = try fixture()
        work.result = TicketWork.Result(summary: completed, verification: nil); ticket.work = [work]
        let foreign = SpaceNote(title: "Another space")
        let destination = ProjectSpace(name: "Other", notes: [foreign])
        var source = ProjectSpace.personal; source.tickets = [ticket]
        var project = Project(id: work.projectID, path: "/project")
        project.spaceID = source.id; source.tickets[0].linkedNoteIDs = [foreign.id]
        var workspace = Workspace(projects: [project], spaces: [source, destination])
        #expect(workspace.spaces[0].tickets[0].linkedNoteIDs?.isEmpty == true)
        #expect({ workspace.moveProject(project.id, to: destination.id) }())
        #expect(workspace.spaces[0].tickets[0].projectID == nil)
        #expect(workspace.spaces[0].tickets[0].work == [work])
    }
}
