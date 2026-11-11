import MarikaCore
import SwiftUI

struct TicketWorkBadge: View {
    @Environment(AppModel.self) private var model
    let ticket: SpaceTicket
    var body: some View {
        if let work = model.displayedTicketWork(ticket) {
            let status = model.ticketWorkStatus(work)
            Label(status.title, systemImage: status.symbol).font(.system(size: 10, weight: .medium))
                .foregroundStyle(status.color).lineLimit(1)
                .accessibilityLabel("Agent work: " + status.title)
        }
    }
}

struct TicketWorkView: View {
    @Environment(AppModel.self) private var model
    let ticketID: UUID
    var navigate: (@escaping () -> Void) -> Void
    @State private var error: String?
    private var ticket: SpaceTicket? { model.ticketLocation(ticketID)?.ticket }
    private var work: TicketWork? { ticket.flatMap(model.displayedTicketWork) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
        if let source = ticket?.designSource {
            Button("Open linked Design", systemImage: "square.stack.3d.up") {
                navigate {
                    model.openDesign(for: source.projectID)
                    model.designCanvases[source.projectID]?.selection = Set(source.elementIDs)
                    model.designCanvases[source.projectID]?.fitSelection()
                }
            }.buttonStyle(WorkspaceButtonStyle(compact: true))
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let ticket, let work {
                    let controller = model.controllers[work.sessionID]
                    let status = model.ticketWorkStatus(work)
                    HStack {
                        Label(status.title, systemImage: status.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(status.color)
                        Spacer()
                        Text(work.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    if let detail = status.detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack(spacing: 8) {
                        if model.workspace.sessions.contains(where: { $0.id == work.sessionID }) {
                            Button(controller?.pendingApproval != nil ? "Review approval" : "Open agent", systemImage: "bubble.left") {
                                navigate { model.openAgentChat(work.sessionID) }
                            }.buttonStyle(WorkspaceButtonStyle(kind: .secondary, compact: true))
                                .background(SpaceContentMarker(name: "ticket-work-open-agent"))
                        }
                        if controller?.isBusy == true {
                            Button("Stop", systemImage: "stop.fill", role: .destructive) { controller?.interrupt() }
                                .buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
                        }
                    }
                    if let result = work.result {
                        Divider()
                        if let reply = result.reply {
                            Text(reply).font(.system(size: 12)).lineLimit(6).textSelection(.enabled)
                            if reply.count > 300 || reply.components(separatedBy: "\n").count > 6 {
                                DisclosureGroup("Read full result") { Text(reply).font(.system(size: 12)).textSelection(.enabled) }.font(.caption)
                            }
                        }
                        if !result.changedFiles.isEmpty {
                            Text("Changed files").font(.system(size: 11, weight: .semibold))
                            ForEach(result.changedFiles.prefix(10), id: \.self) { Text($0).font(Theme.codeSmall).textSelection(.enabled) }
                            if result.changedFiles.count > 10 { Text("And \(result.changedFiles.count - 10) more").font(.caption).foregroundStyle(.secondary) }
                        }
                        if model.project(id: work.projectID) != nil, model.workspace.sessions.contains(where: { $0.id == work.sessionID }) {
                            Button("Review changes", systemImage: "doc.text.magnifyingglass") {
                                navigate {
                                    if controller?.meta.agentTask?.workspace != nil { Task { await model.openAgentReview(work.sessionID) } }
                                    else if let project = model.project(id: work.projectID) { model.openProject(project); model.switchPanel(.changes) }
                                }
                            }.buttonStyle(WorkspaceButtonStyle(kind: .secondary, compact: true))
                                .background(SpaceContentMarker(name: "ticket-work-changes"))
                        }
                        checks(work, controller: controller)
                    }
                    let previous = (ticket.work ?? []).filter { $0.sessionID != work.sessionID }.reversed()
                    if !previous.isEmpty {
                        Divider()
                        DisclosureGroup("Other runs (\(previous.count))") {
                            ForEach(Array(previous)) { run in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(run.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                    Text(model.ticketWorkStatus(run).title).font(.system(size: 12, weight: .medium))
                                    if let reply = run.result?.reply { Text(reply).font(.caption).textSelection(.enabled) }
                                    if let record = run.result?.verification { savedChecks(record) }
                                    if model.workspace.sessions.contains(where: { $0.id == run.sessionID }) {
                                        Button("Open agent") { navigate { model.openAgentChat(run.sessionID) } }.buttonStyle(.link)
                                    }
                                }.padding(.vertical, 8)
                            }
                        }.font(.system(size: 12))
                    }
                } else if let ticket {
                    ContentUnavailableView("Work starts here", systemImage: "person.badge.plus", description:
                        Text(ticket.projectID == nil ? "Choose a project in Properties, link any useful notes, then start work." : "Start an agent with the ticket description and linked notes. Its progress, changes and checks will stay here."))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }
        if let error { Text(error).font(.caption).foregroundStyle(Theme.attention).textSelection(.enabled) }
        if let ticket, let work { acceptance(ticket, work: work) }
        }
        .task(id: work?.sessionID) { if let work, model.workspace.sessions.contains(where: { $0.id == work.sessionID }) { await model.open(work.sessionID) } }
        .background(SpaceContentMarker(name: "ticket-work-view"))
    }

    @ViewBuilder private func acceptance(_ ticket: SpaceTicket, work: TicketWork) -> some View {
        if work.acceptedAt != nil {
            Divider()
            Label("Result accepted" + (ticket.status == .done ? " · Ticket Done" : ""), systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                .background(SpaceContentMarker(name: "ticket-work-accepted"))
        } else if work.sessionID == ticket.work?.last?.sessionID, work.result != nil {
            Divider()
            let issue = model.ticketAcceptanceIssue(ticket)
            if let issue { Text(issue.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            else if model.controllers[work.sessionID]?.meta.agentTask?.workspace?.status == .ready {
                Text("Review isolated changes before accepting this result.").font(.caption).foregroundStyle(.secondary)
            }
            Button(model.acceptingTickets.contains(ticketID) ? "Accepting…" : "Accept result", systemImage: "checkmark") {
                Task { do { try await model.acceptTicketResult(ticketID); error = nil } catch { self.error = error.localizedDescription } }
            }.buttonStyle(WorkspaceButtonStyle(kind: .primary))
                .disabled(issue != nil || model.acceptingTickets.contains(ticketID))
                .background(SpaceContentMarker(name: "ticket-work-accept"))
        }
    }

    @ViewBuilder private func checks(_ work: TicketWork, controller: SessionController?) -> some View {
        Divider()
        Text("Checks").font(.system(size: 11, weight: .semibold))
        if let controller {
            if controller.meta.taskVerification != nil { TaskVerificationFeedback(session: controller).font(.caption) }
            else { Text("Checks have not been run.").font(.caption).foregroundStyle(.secondary) }
            if let record = controller.meta.taskVerification {
                DisclosureGroup("Test output") { Text(record.output).font(Theme.codeSmall).textSelection(.enabled) }.font(.caption)
            }
            if model.taskVerifications[work.sessionID]?.running == true {
                HStack { ProgressView().controlSize(.mini); Text("Running checks…").font(.caption)
                    Button("Stop checks") { model.taskVerifications[work.sessionID]?.stop() }.buttonStyle(.link) }
            } else {
                Button(controller.meta.taskVerification == nil ? "Run checks" : "Run checks again", systemImage: "play.fill") { model.taskVerification(for: work.sessionID).run() }
                    .buttonStyle(WorkspaceButtonStyle(kind: .secondary, compact: true))
                    .disabled(controller.isBusy || model.project(id: work.projectID)?.runtime != nil || model.taskVerifications[work.sessionID]?.hasUnsavedInputs == true)
                    .background(SpaceContentMarker(name: "ticket-work-run-checks"))
            }
        } else if let record = work.result?.verification { savedChecks(record) }
        else { Text("No saved checks.").font(.caption).foregroundStyle(.secondary) }
    }

    private func savedChecks(_ record: TaskVerificationRecord) -> some View {
        DisclosureGroup("Last checks: " + (record.succeeded == true ? "Passed" : record.succeeded == false ? "Failed" : "Incomplete")) {
            Text(record.command).font(.caption).foregroundStyle(.secondary)
            Text(record.output).font(Theme.codeSmall).textSelection(.enabled)
        }.font(.caption)
    }
}

struct TicketNotesPicker: View {
    @Environment(AppModel.self) private var model
    let ticketID: UUID
    let spaceID: UUID
    var navigate: (@escaping () -> Void) -> Void
    private var notes: [SpaceNote] { model.workspace.spaces.first { $0.id == spaceID }?.notes ?? [] }
    private var selected: Set<UUID> { Set(model.ticket(ticketID, in: spaceID)?.linkedNoteIDs ?? []) }
    var body: some View {
        WorkspaceFormField(title: "Linked notes") {
            Menu {
                ForEach(notes) { note in
                    Button { toggle(note.id) } label: {
                        if selected.contains(note.id) { Label(note.displayTitle, systemImage: "checkmark") }
                        else { Text(note.displayTitle + (note.archived ? " (Archived)" : "")) }
                    }
                }
                if notes.isEmpty { Text("No notes in this space") }
            } label: { Label(selected.isEmpty ? "Link notes" : "\(selected.count) linked", systemImage: "doc.text") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).workspaceControl(height: 36)
                .accessibilityLabel("Link notes to ticket")
                .background(SpaceContentMarker(name: "ticket-linked-notes"))
            ForEach(notes.filter { selected.contains($0.id) }) { note in
                HStack(spacing: 6) {
                    Button(note.displayTitle) { navigate { model.openNote(note.id, in: spaceID) } }
                        .buttonStyle(.link).lineLimit(2).multilineTextAlignment(.leading)
                        .background(SpaceContentMarker(name: "ticket-note-link-" + note.id.uuidString))
                    Spacer(minLength: 0)
                    Button { toggle(note.id) } label: { Image(systemName: "xmark").frame(width: 18, height: 22).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Unlink " + note.displayTitle)
                }.font(.system(size: 11))
            }
        }
    }
    private func toggle(_ id: UUID) {
        model.updateSpaceTicket(ticketID, in: spaceID) { ticket in
            var ids = Set(ticket.linkedNoteIDs ?? [])
            if !ids.insert(id).inserted { ids.remove(id) }
            ticket.linkedNoteIDs = Array(ids)
        }
    }
}

struct TicketWorkStatus {
    let title: String
    let symbol: String
    let color: Color
    var detail: String?
}

extension AppModel {
    func displayedTicketWork(_ ticket: SpaceTicket) -> TicketWork? {
        ticket.work?.last(where: { controllers[$0.sessionID]?.isBusy == true }) ?? ticket.work?.last
    }
    func ticketWorkStatus(_ work: TicketWork) -> TicketWorkStatus {
        let controller = controllers[work.sessionID]
        let meta = controller?.meta ?? workspace.sessions.first { $0.id == work.sessionID }
        if controller?.pendingApproval != nil { return TicketWorkStatus(title: "Needs approval", symbol: "hand.raised.fill", color: Theme.attention, detail: controller?.pendingApproval?.title) }
        if controller?.phase == .waitingForUser { return TicketWorkStatus(title: "Needs input", symbol: "questionmark.bubble", color: Theme.attention, detail: "Open the agent's chat to respond.") }
        if controller?.isBusy == true { return TicketWorkStatus(title: "Working", symbol: "circle.dotted", color: Theme.action, detail: controller?.activity ?? "The agent is working on this ticket.") }
        if work.acceptedAt != nil { return TicketWorkStatus(title: "Accepted", symbol: "checkmark.circle.fill", color: .green) }
        if meta?.agentTask?.workspace?.status == .discarded { return TicketWorkStatus(title: "Blocked", symbol: "exclamationmark.circle", color: Theme.attention, detail: "The agent's workspace was discarded.") }
        if let controller {
            let state = AgentTaskPresentation(meta: controller.meta, items: controller.items, phase: controller.phase)
            switch state.state {
            case .completed:
                if let record = controller.meta.taskVerification, let summary = TaskCompletionSummary(items: controller.items), summary.includes(record), record.succeeded != true {
                    return TicketWorkStatus(title: "Blocked", symbol: "exclamationmark.circle", color: Theme.attention, detail: record.succeeded == false ? "Checks failed. Review the output before accepting this result." : "Checks are incomplete. Run them again before accepting this result.")
                }
                return TicketWorkStatus(title: "Ready to review", symbol: "checkmark.circle", color: Theme.action)
            case .failed, .stopped: return TicketWorkStatus(title: "Blocked", symbol: "exclamationmark.circle", color: Theme.attention, detail: state.preview)
            default: return TicketWorkStatus(title: "Paused", symbol: "pause.circle", color: .secondary, detail: "Open the agent's chat to continue this work.")
            }
        }
        if let result = work.result {
            if let record = result.verification, record.date >= result.finishedAt, record.succeeded != true {
                return TicketWorkStatus(title: "Blocked", symbol: "exclamationmark.circle", color: Theme.attention, detail: "The last checks did not pass. Review the saved output.")
            }
            return TicketWorkStatus(title: result.outcome == .completed ? "Ready to review" : "Blocked", symbol: result.outcome == .completed ? "checkmark.circle" : "exclamationmark.circle", color: result.outcome == .completed ? Theme.action : Theme.attention,
                                    detail: meta == nil ? "The agent chat was removed. Its saved result is preserved below." : nil)
        }
        return TicketWorkStatus(title: "Paused", symbol: "pause.circle", color: .secondary, detail: "Open the agent's chat to resume, or start a new run.")
    }
}
