#if DEBUG
import Foundation
import MarikaCore

@MainActor enum DebugAttentionChecks {
    static func run(_ step: JSONValue, model: AppModel) async throws {
        func controller(_ title: String) async throws -> SessionController {
            guard let meta = model.workspace.sessions.first(where: { $0.title == title }) else { throw TicketWorkError("Missing inbox fixture: " + title) }
            await model.open(meta.id)
            guard let controller = model.controllers[meta.id] else { throw TicketWorkError("Couldn't open inbox fixture") }
            return controller
        }
        switch step["phase"]?.string ?? "" {
        case "fixture":
            guard let ticket = model.selectedSpace.tickets.first,
                  let session = model.workspace.sessions.first(where: { $0.title == "Review ticket" }) else { throw TicketWorkError("Missing ticket fixture") }
            try model.attachTicketWork(model.ticketLaunchDraft(ticket.id), session: session)
            for title in ["Blocked agent", "Review ticket", "Failed checks", "Other space result", "Ordinary reply"] {
                let c = try await controller(title)
                c.apply(.phaseChanged(.running))
                c.apply(.textFinished(id: title + "-reply", text: title == "Blocked agent" ? "Could not complete the fixture task." : "Updated the project navigation and kept keyboard controls.", parentToolID: nil))
                c.apply(.turnFinished(TurnSummary(outcome: title == "Blocked agent" ? .failed : .completed, message: title == "Blocked agent" ? "The fixture needs a missing configuration file." : nil)))
                c.apply(.phaseChanged(.idle))
                if title == "Failed checks" { c.recordVerification(TaskVerificationRecord(command: "swift test", output: "Fixture failed", succeeded: false)) }
            }
            let approval = try await controller("Approval agent")
            approval.apply(.phaseChanged(.running))
            approval.apply(.approvalRequested(ApprovalRequest(id: "inbox-approval", toolKind: .shell, title: "Run the project checks")))
            guard model.attentionItems.count == 5, model.attentionItems.first?.kind == .approval else { throw TicketWorkError("Inbox did not scope the fixture: " + String(describing: model.attentionItems.map(\.kind))) }
        case "approvalResolved":
            let c = try await controller("Approval agent")
            c.apply(.approvalCancelled(id: "inbox-approval"))
            guard !model.attentionItems.contains(where: { $0.id == c.id }) else { throw TicketWorkError("Resolved approval stayed in the inbox") }
            // Settle without creating a new review item in this ordinary conversation.
            c.apply(.turnFinished(TurnSummary(outcome: .completed))); c.apply(.phaseChanged(.idle))
        case "checksPassed":
            let c = try await controller("Failed checks")
            c.recordVerification(TaskVerificationRecord(command: "swift test", output: "Fixture passed", succeeded: true))
            guard !model.attentionItems.contains(where: { $0.id == c.id && $0.kind == .checks }) else { throw TicketWorkError("Passing checks left a failure in the inbox") }
        case "newFailure":
            let c = try await controller("Blocked agent")
            c.apply(.phaseChanged(.running))
            c.apply(.turnFinished(TurnSummary(outcome: .failed, message: "A new failure needs attention.")))
            c.apply(.phaseChanged(.idle))
            guard model.attentionItems.contains(where: { $0.id == c.id && $0.kind == .blocked }) else { throw TicketWorkError("New failure did not return after dismissal") }
        case "accepted":
            guard let ticket = model.selectedSpace.tickets.first else { throw TicketWorkError("Missing inbox ticket") }
            try await model.acceptTicketResult(ticket.id)
            guard !model.attentionItems.contains(where: { $0.ticketID == ticket.id }) else { throw TicketWorkError("Accepted ticket stayed in the inbox") }
        case "restored":
            let blocked = model.workspace.sessions.first { $0.title == "Blocked agent" }!
            guard !model.attentionItems.contains(where: { $0.id == blocked.id }),
                  model.attentionItems.count == 2 else { throw TicketWorkError("Dismissal or resolved items did not persist: " + String(describing: model.attentionItems.map(\.title))) }
        default: throw TicketWorkError("Unknown inbox test phase")
        }
        if let expected = step["count"]?.int, model.attentionItems.count != expected { throw TicketWorkError("Unexpected inbox count: \(model.attentionItems.count), expected \(expected)") }
    }
}
#endif
