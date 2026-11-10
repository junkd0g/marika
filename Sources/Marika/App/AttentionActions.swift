import Foundation
import MarikaCore

extension AppModel {
    func syncAttention(_ controller: SessionController) {
        guard controllers[controller.id] === controller else { return }
        let record: SessionAttention
        let lastUser = controller.items.last { if case .user = $0.content { return $0.parentToolID == nil }; return false }
        if controller.isBusy {
            record = SessionAttention(state: .working, eventID: lastUser?.id ?? "working", date: lastUser?.date ?? controller.meta.updatedAt)
        } else {
            let presentation = AgentTaskPresentation(meta: controller.meta, items: controller.items, phase: controller.phase)
            let summary = TaskCompletionSummary(items: controller.items)
            let end = controller.items.last { item in
                guard item.parentToolID == nil else { return false }
                if case .turnEnd = item.content { return true }
                if case .notice(let notice) = item.content { return notice.level == .error }
                return false
            }
            let state: SessionAttention.State
            switch presentation.state {
            case .completed: state = .completed
            case .failed: state = .failed
            case .stopped: state = .stopped
            default: state = .idle
            }
            record = SessionAttention(state: state, eventID: end?.id ?? lastUser?.id ?? "idle",
                date: summary?.finishedAt ?? end?.date ?? controller.meta.updatedAt,
                detail: presentation.preview, hasChanges: summary?.changedFiles.isEmpty == false)
        }
        guard controller.meta.attention != record,
              let index = workspace.sessions.firstIndex(where: { $0.id == controller.id }) else { return }
        controller.recordAttention(record)
        editSpaceContent { $0.sessions[index] = controller.meta }
    }

    var attentionItems: [AttentionItem] {
        let projectIDs = Set(workspace.projects.map(\.id))
        let linkedTickets = Dictionary(workspace.spaces.flatMap(\.tickets).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return AttentionItem.sorted(workspace.sessions.compactMap { saved in
            guard projectIDs.contains(saved.projectID) else { return nil }
            let controller = controllers[saved.id]
            let meta = controller?.meta ?? saved
            let ticket = meta.agentTask?.ticketID.flatMap { linkedTickets[$0] }
            var evidence = meta.attention
            // Older workspaces already have ticket results or activity history; no transcript scan is needed.
            if evidence == nil, let work = ticket?.work?.first(where: { $0.sessionID == meta.id }), let result = work.result {
                evidence = SessionAttention(state: result.outcome == .completed ? .completed : result.outcome == .failed ? .failed : .stopped,
                    eventID: String(result.finishedAt.timeIntervalSince1970), date: result.finishedAt, detail: result.reply,
                    hasChanges: !result.changedFiles.isEmpty)
            }
            if evidence == nil, let event = project(id: meta.projectID)?.taskActivity?.filter({ $0.sessionID == meta.id && $0.kind != .approval }).max(by: { $0.date < $1.date }) {
                evidence = SessionAttention(state: event.kind == .completed ? .completed : event.kind == .stopped ? .stopped : .failed,
                    eventID: event.id, date: event.date, detail: event.detail)
            }
            return AttentionItem.current(meta: meta, evidence: evidence, phase: controller?.phase ?? .idle,
                approval: controller?.pendingApproval, checksRunning: taskVerifications[meta.id]?.running == true, ticket: ticket)
        })
    }

    func openAttentionItem(_ item: AttentionItem) {
        guard workspace.sessions.contains(where: { $0.id == item.sessionID }) else { return }
        if let spaceID = project(id: item.projectID)?.spaceID { selectSpace(spaceID) }
        if item.kind == .approval || item.kind == .input || (item.kind == .blocked && item.ticketID == nil) {
            openAgentChat(item.sessionID)
        } else if let ticketID = item.ticketID { openTicket(ticketID) }
        else {
            openAgentChat(item.sessionID)
            taskCompletionID = item.sessionID
        }
    }

    func dismissAttentionItem(_ item: AttentionItem) {
        guard item.canDismiss, attentionItems.contains(where: { $0.id == item.id && $0.eventID == item.eventID }),
              let index = workspace.sessions.firstIndex(where: { $0.id == item.sessionID }) else { return }
        if let controller = controllers[item.sessionID] { controller.dismissAttentionEvent(item.eventID) }
        else { editSpaceContent { $0.sessions[index].dismissedAttentionEvent = item.eventID } }
    }
}
