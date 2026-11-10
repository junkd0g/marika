#if DEBUG
import Foundation
import MarikaCore

@MainActor enum DebugTicketWorkChecks {
    static func run(_ step: JSONValue, model: AppModel) async throws {
        guard let ticket = model.selectedSpace.tickets.first, let location = model.ticketLocation(ticket.id) else { throw TicketWorkError("Ticket fixture missing") }
        let phase = step["phase"]?.string ?? ""
        if phase == "launchGuards" {
            let draft = try model.ticketLaunchDraft(ticket.id)
            let before = model.workspace.sessions.count
            model.updateSpaceTicket(ticket.id, in: location.spaceID) { $0.body += " Changed while launch was open." }
            try await rejected { _ = try await model.launchAgent(in: model.project(id: draft.projectID)!, agent: .codex, settings: AgentSettings(), prompt: draft.prompt, isolated: false, ticketLaunch: draft) }
            model.updateSpaceTicket(ticket.id, in: location.spaceID) { $0.body = ticket.body }
            guard model.workspace.sessions.count == before, model.ticket(ticket.id, in: location.spaceID)?.work?.isEmpty != false else { throw TicketWorkError("A stale launch created work") }
            guard await model.save() else { throw TicketWorkError("Initial save failed") }
            let file = model.store.root.appendingPathComponent("workspace.json"), backup = model.store.root.appendingPathComponent("qa-workspace.saved")
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            do {
                try await rejected { _ = try await model.launchAgent(in: model.project(id: draft.projectID)!, agent: .codex, settings: AgentSettings(), prompt: draft.prompt, isolated: false, ticketLaunch: draft) }
                try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
            } catch {
                try? FileManager.default.removeItem(at: file); try? FileManager.default.moveItem(at: backup, to: file); throw error
            }
            guard model.workspace.sessions.count == before, model.ticket(ticket.id, in: location.spaceID)?.status == .todo,
                  model.ticket(ticket.id, in: location.spaceID)?.work?.isEmpty != false else { throw TicketWorkError("A failed save left orphaned ticket work") }
            guard await model.save() else { throw TicketWorkError("Could not recover after injected save failure") }
            return
        }
        guard let work = ticket.work?.last else { throw TicketWorkError("No linked run") }
        await model.open(work.sessionID)
        guard let controller = model.controllers[work.sessionID], controller.meta.agentTask?.ticketID == ticket.id else { throw TicketWorkError("Ticket and agent are not linked") }
        switch phase {
        case "started":
            guard controller.isBusy, ticket.status == .inProgress, controller.meta.agentTask?.prompt.contains("Selected design context") == true,
                  controller.meta.agentTask?.prompt.contains("Unselected context") == false else { throw TicketWorkError("Start did not scope context and progress") }
            try await rejected { try await model.acceptTicketResult(ticket.id) }
            try await rejected { _ = try model.ticketLaunchDraft(ticket.id) }
        case "approval":
            controller.apply(.approvalRequested(ApprovalRequest(id: "ticket-approval", toolKind: .shell, title: "Run the fixture tests")))
            guard model.ticketWorkStatus(work).title == "Needs approval" else { throw TicketWorkError("Approval was not visible on the ticket") }
        case "blocked":
            controller.apply(.approvalCancelled(id: "ticket-approval"))
            controller.apply(.turnFinished(TurnSummary(outcome: .failed, message: "Fixture blocked")))
            controller.apply(.phaseChanged(.idle))
            guard model.ticketWorkStatus(work).title == "Blocked", model.ticketLocation(ticket.id)?.ticket.status == .inProgress,
                  model.ticketLocation(ticket.id)?.ticket.work?.last?.result?.outcome == .failed else { throw TicketWorkError("Failure completed the ticket or lost the result") }
        case "complete":
            let root = model.project(id: work.projectID)!.url
            try "# Ticket work completed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            controller.apply(.tool(ToolCall(id: "ticket-edit", name: "edit", kind: .edit, title: "Update README", detail: "", status: .succeeded,
                diff: [DiffFile(path: "README.md", newContent: "# Ticket work completed\n")])))
            controller.apply(.textFinished(id: "ticket-answer", text: "Implemented the ticket using the selected design context.", parentToolID: nil))
            controller.apply(.turnFinished(TurnSummary(outcome: .completed)))
            controller.apply(.phaseChanged(.idle))
            guard model.ticketLocation(ticket.id)?.ticket.status == .inProgress,
                  model.ticketLocation(ticket.id)?.ticket.work?.last?.result?.changedFiles == ["README.md"] else { throw TicketWorkError("Completion did not preserve review before Done") }
        case "value":
            let value = step["value"]?.int ?? 42
            try "public let expected = \(value)\n".write(to: model.project(id: work.projectID)!.url.appendingPathComponent("Sources/Fixture/Value.swift"), atomically: true, encoding: .utf8)
        case "checks":
            let checks = model.taskVerification(for: work.sessionID)
            for _ in 0..<600 where checks.running { try await Task.sleep(for: .milliseconds(100)) }
            await checks.refreshFreshness()
            let expected = step["passed"]?.bool ?? true
            guard controller.meta.taskVerification?.succeeded == expected,
                  model.ticketLocation(ticket.id)?.ticket.work?.last?.result?.verification?.succeeded == expected else {
                throw TicketWorkError("Checks did not attach to the ticket: " + (controller.meta.taskVerification?.output ?? "no output"))
            }
            if !expected { try await rejected { try await model.acceptTicketResult(ticket.id) } }
        case "contextGuard":
            let old = ticket.body
            model.updateSpaceTicket(ticket.id, in: location.spaceID) { $0.body += " New acceptance criterion." }
            try await rejected { try await model.acceptTicketResult(ticket.id) }
            model.updateSpaceTicket(ticket.id, in: location.spaceID) { $0.body = old }
            let note = model.workspace.spaces.first { $0.id == location.spaceID }!.notes[0]
            model.updateSpaceNote(note.id, in: location.spaceID) { $0.blocks[0].text += " Updated after launch." }
            try await rejected { try await model.acceptTicketResult(ticket.id) }
            model.updateSpaceNote(note.id, in: location.spaceID) { $0.blocks = note.blocks }
        case "restored":
            let checks = model.taskVerification(for: work.sessionID); await checks.refreshFreshness()
            guard ticket.work?.count == 2, ticket.work?.first?.result?.outcome == .failed, ticket.status == .inProgress,
                  work.result?.changedFiles == ["README.md"], controller.meta.taskVerification?.succeeded == true,
                  model.ticketAcceptanceIssue(ticket) == nil else { throw TicketWorkError("Saved work did not restore for review: " + (model.ticketAcceptanceIssue(ticket)?.message ?? "unknown")) }
            let file = model.store.root.appendingPathComponent("workspace.json"), backup = model.store.root.appendingPathComponent("qa-acceptance.saved")
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            do {
                try await rejected { try await model.acceptTicketResult(ticket.id) }
                guard let saved = model.ticketLocation(ticket.id)?.ticket, saved.status == .inProgress, saved.work?.last?.acceptedAt == nil else {
                    throw TicketWorkError("A failed acceptance save left the ticket Done")
                }
                try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
            } catch {
                try? FileManager.default.removeItem(at: file); try? FileManager.default.moveItem(at: backup, to: file); throw error
            }
            guard await model.save() else { throw TicketWorkError("Could not recover after failed acceptance") }
        case "accepted":
            guard ticket.status == .done, work.acceptedAt != nil, work.result?.verification?.succeeded == true else { throw TicketWorkError("Acceptance did not save Done and its checks") }
        case "isolated":
            model.updateSpaceTicket(ticket.id, in: location.spaceID) { $0.status = .inProgress }
            let draft = try model.ticketLaunchDraft(ticket.id)
            let project = model.project(id: draft.projectID)!
            let isolated = try await model.launchAgent(in: project, agent: .codex, settings: AgentSettings(), prompt: draft.prompt, isolated: true, ticketLaunch: draft)
            try await Task.sleep(for: .milliseconds(300))
            let path = URL(fileURLWithPath: isolated.meta.agentTask!.workspace!.workingPath).appendingPathComponent("Isolated.txt")
            try "Reviewed ticket change\n".write(to: path, atomically: true, encoding: .utf8)
            isolated.apply(.tool(ToolCall(id: "isolated-edit", name: "edit", kind: .edit, title: "Isolated change", detail: "", status: .succeeded,
                diff: [DiffFile(path: "Isolated.txt", newContent: "Reviewed ticket change\n")])))
            isolated.apply(.textFinished(id: "isolated-result", text: "Isolated changes are ready to review.", parentToolID: nil))
            isolated.apply(.turnFinished(TurnSummary(outcome: .completed))); isolated.apply(.phaseChanged(.idle))
            try await rejected { try await model.acceptTicketResult(ticket.id) }
            guard !FileManager.default.fileExists(atPath: project.url.appendingPathComponent("Isolated.txt").path) else { throw TicketWorkError("Acceptance applied work without a review") }
            let review = AgentReviewWorkspace(model: model, projectID: project.id, sessionID: isolated.id)
            await review.refresh(); await review.acceptRemaining()
            guard review.error == nil, isolated.meta.agentTask?.workspace?.status == .reviewed else { throw TicketWorkError("Isolated review failed: " + (review.error ?? "unknown")) }
            try await model.acceptTicketResult(ticket.id)
            guard model.ticketLocation(ticket.id)?.ticket.status == .done else { throw TicketWorkError("Reviewed isolated result could not be accepted") }
        case "resume":
            guard let older = ticket.work?.first, older.sessionID != work.sessionID else { throw TicketWorkError("Run history fixture missing") }
            await model.open(older.sessionID)
            let previous = model.controllers[older.sessionID]!
            previous.send(UserInput(text: "Continue this ticket with a follow-up change."))
            let reopened = model.ticketLocation(ticket.id)!.ticket
            guard reopened.status == .inProgress, reopened.work?.last?.sessionID == older.sessionID,
                  reopened.work?.last?.acceptedAt == nil, reopened.work?.last?.result == nil else { throw TicketWorkError("Resuming earlier work left the ticket marked Done") }
            previous.interrupt()
        default: throw TicketWorkError("Unknown ticket test phase")
        }
    }

    private static func rejected(_ action: () async throws -> Void) async throws {
        var failed = false
        do { try await action() } catch { failed = true }
        guard failed else { throw TicketWorkError("An invalid ticket action was allowed") }
    }
}
#endif
