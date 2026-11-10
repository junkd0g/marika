import Foundation
import MarikaCore

struct TicketAgentLaunch: Identifiable {
    var id: UUID { ticketID }
    let ticketID: UUID
    let projectID: UUID
    let contextDigest: String
    let prompt: String
    let name: String
}

extension AppModel {
    func ticketLocation(_ id: UUID) -> (spaceID: UUID, ticket: SpaceTicket)? {
        for space in workspace.spaces {
            if let ticket = space.tickets.first(where: { $0.id == id }) { return (space.id, ticket) }
        }
        return nil
    }

    func ticketContext(_ id: UUID) throws -> TicketWorkContext {
        guard let location = ticketLocation(id), let space = workspace.spaces.first(where: { $0.id == location.spaceID }) else {
            throw TicketWorkError("This ticket is no longer available.")
        }
        return try TicketWorkContext(ticket: location.ticket, notes: space.notes)
    }

    func ticketHasActiveWork(_ ticket: SpaceTicket) -> Bool {
        (ticket.work ?? []).contains { controllers[$0.sessionID]?.isBusy == true }
    }

    func ticketLaunchDraft(_ id: UUID) throws -> TicketAgentLaunch {
        guard let location = ticketLocation(id), let projectID = location.ticket.projectID else { throw TicketWorkError("Choose a project for this ticket before starting work.") }
        guard (location.ticket.work?.count ?? 0) < 100 else { throw TicketWorkError("This ticket has 100 runs. Create a follow-up ticket for more work.") }
        let context = try ticketContext(id)
        let draft = TicketAgentLaunch(ticketID: id, projectID: projectID, contextDigest: context.digest,
                                      prompt: context.prompt, name: String((context.key + ": " + context.title).prefix(80)))
        try validateTicketLaunch(draft, projectID: projectID)
        guard draft.prompt.count <= 32_000 else { throw TicketWorkError("The ticket and selected notes exceed 32,000 characters. Shorten the description or link fewer notes.") }
        return draft
    }

    func validateTicketLaunch(_ launch: TicketAgentLaunch, projectID: UUID) throws {
        guard let location = ticketLocation(launch.ticketID), let project = project(id: projectID),
              launch.projectID == projectID, location.ticket.projectID == projectID, project.spaceID == location.spaceID else {
            throw TicketWorkError("The ticket's project changed or moved. Choose a project in this space.")
        }
        guard !location.ticket.archived, location.ticket.status != .done else { throw TicketWorkError("Reopen this ticket before starting more work.") }
        guard !isShuttingDown, !Task.isCancelled else { throw CancellationError() }
        guard !ticketHasActiveWork(location.ticket) else { throw TicketWorkError("An agent is already working on this ticket. Open its chat to continue or stop it.") }
        guard try ticketContext(launch.ticketID).digest == launch.contextDigest else { throw TicketWorkError("The ticket or its notes changed. Close this launch form and start again with the updated context.") }
    }

    func attachTicketWork(_ launch: TicketAgentLaunch, session: SessionMeta) throws {
        guard let location = ticketLocation(launch.ticketID), session.agentTask?.ticketID == launch.ticketID else { throw TicketWorkError("The ticket link could not be created.") }
        guard (location.ticket.work?.count ?? 0) < 100 else { throw TicketWorkError("This ticket has 100 runs. Create a follow-up ticket for more work.") }
        updateSpaceTicket(launch.ticketID, in: location.spaceID) {
            $0.work = ($0.work ?? []) + [TicketWork(sessionID: session.id, projectID: session.projectID, contextDigest: launch.contextDigest)]
            $0.status = .inProgress
        }
    }

    func rollbackTicketWork(_ ticketID: UUID, sessionID: UUID, previousStatus: SpaceTicket.Status?) {
        guard let location = ticketLocation(ticketID), location.ticket.work?.contains(where: { $0.sessionID == sessionID }) == true else { return }
        updateSpaceTicket(ticketID, in: location.spaceID) {
            let wasLatest = $0.work?.last?.sessionID == sessionID
            $0.work?.removeAll { $0.sessionID == sessionID }
            if wasLatest, $0.status == .inProgress, let previousStatus { $0.status = previousStatus }
        }
    }

    func syncTicketWork(_ controller: SessionController, phaseChanged: Bool = false) {
        guard let ticketID = controller.meta.agentTask?.ticketID, let location = ticketLocation(ticketID),
              let index = location.ticket.work?.firstIndex(where: { $0.sessionID == controller.id }),
              var work = location.ticket.work?[index] else { return }
        let before = work
        let resumed = phaseChanged && controller.isBusy
        if controller.isBusy { work.result = nil; work.acceptedAt = nil }
        else if let summary = TaskCompletionSummary(items: controller.items) {
            work.result = TicketWork.Result(summary: summary, verification: controller.meta.taskVerification)
        } else {
            let presentation = AgentTaskPresentation(meta: controller.meta, items: controller.items, phase: controller.phase)
            if presentation.state == .failed, let detail = presentation.preview, let date = controller.items.last?.date {
                work.result = TicketWork.Result(failure: detail, date: date)
            }
        }
        guard work != before || (resumed && index != location.ticket.work!.count - 1) else { return }
        updateSpaceTicket(ticketID, in: location.spaceID) {
            let wasAccepted = before.acceptedAt != nil || $0.work?.last?.acceptedAt != nil
            if resumed, index != $0.work!.count - 1 { $0.work?.remove(at: index); $0.work?.append(work) }
            else { $0.work?[index] = work }
            if wasAccepted, controller.isBusy, !$0.archived, $0.status == .done { $0.status = .inProgress }
        }
    }

    func openTicket(_ id: UUID) {
        guard let location = ticketLocation(id) else { return }
        selectSpace(location.spaceID)
        openSpaceSection(.tickets)
        spaceTicketSelections[location.spaceID] = id
    }

    func ticketAcceptanceIssue(_ ticket: SpaceTicket) -> TicketWorkError? {
        guard let work = ticket.work?.last else { return TicketWorkError("Start work on this ticket first.") }
        if launchingTickets.contains(ticket.id) || ticketHasActiveWork(ticket) { return TicketWorkError("An agent is still working on this ticket.") }
        guard let location = ticketLocation(ticket.id), project(id: work.projectID)?.spaceID == location.spaceID else { return TicketWorkError("The linked project is no longer in this space.") }
        do {
            let context = try ticketContext(ticket.id)
            let controller = controllers[work.sessionID]
            return work.acceptanceIssue(ticket: ticket, currentDigest: context.digest, session: controller?.meta,
                summary: controller.flatMap { TaskCompletionSummary(items: $0.items) }, isBusy: controller?.isBusy ?? false,
                checksRunning: taskVerifications[work.sessionID]?.running == true,
                checksCurrent: taskVerifications[work.sessionID]?.status == .current)
        } catch { return TicketWorkError(error.localizedDescription) }
    }

    func acceptTicketResult(_ id: UUID) async throws {
        guard !acceptingTickets.contains(id), !launchingTickets.contains(id), let initial = ticketLocation(id), let work = initial.ticket.work?.last else {
            throw TicketWorkError("This ticket is not ready to accept a result.")
        }
        acceptingTickets.insert(id)
        defer { acceptingTickets.remove(id) }
        await open(work.sessionID)
        let checks = taskVerification(for: work.sessionID)
        let record = controllers[work.sessionID]?.meta.taskVerification
        if record != nil { await checks.refreshFreshness() }
        guard controllers[work.sessionID]?.meta.taskVerification == record else { throw TicketWorkError("The check result changed. Review it again before accepting.") }
        if let controller = controllers[work.sessionID], let isolated = controller.meta.agentTask?.workspace, let project = project(id: work.projectID) {
            let changes = try await worktreeService.review(isolated, project: project.url)
            guard changes.isEmpty else { throw TicketWorkError("Review and apply or reject the isolated changes before accepting the result.") }
        }
        guard let current = ticketLocation(id), current.ticket.work?.last?.sessionID == work.sessionID else { throw TicketWorkError("The ticket's latest run changed. Review it again.") }
        if let issue = ticketAcceptanceIssue(current.ticket) { throw issue }
        let acceptedAt = Date(), previousStatus = current.ticket.status
        let workIndex = current.ticket.work!.count - 1
        updateSpaceTicket(id, in: current.spaceID) {
            $0.work?[workIndex].acceptedAt = acceptedAt
            $0.status = .done
        }
        guard await save() else {
            if let latest = ticketLocation(id), latest.ticket.work?.last?.acceptedAt == acceptedAt {
                let latestIndex = latest.ticket.work!.count - 1
                updateSpaceTicket(id, in: latest.spaceID) {
                    $0.work?[latestIndex].acceptedAt = nil
                    if $0.status == .done { $0.status = previousStatus }
                }
            }
            throw TicketWorkError("Couldn't save the accepted result. The ticket has been kept open.")
        }
        guard let saved = ticketLocation(id), saved.ticket.work?.last?.acceptedAt == acceptedAt,
              !saved.ticket.archived, saved.ticket.projectID == work.projectID,
              project(id: work.projectID)?.spaceID == saved.spaceID, !ticketHasActiveWork(saved.ticket),
              (try? ticketContext(id).digest) == work.contextDigest else {
            if let latest = ticketLocation(id), latest.ticket.work?.last?.acceptedAt == acceptedAt {
                let latestIndex = latest.ticket.work!.count - 1
                updateSpaceTicket(id, in: latest.spaceID) {
                    $0.work?[latestIndex].acceptedAt = nil
                    if $0.status == .done { $0.status = previousStatus }
                }
                _ = await save()
            }
            throw TicketWorkError("The work changed while accepting. Review the current result.")
        }
    }
}
