import MarikaCore
import SwiftUI

struct TaskCompletionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @State private var worktreeReview: AgentReviewWorkspace?
    private var session: SessionController? { model.controllers[sessionID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task results").font(.title2.bold())
                    Text(session?.meta.title ?? "Task results").foregroundStyle(.secondary).lineLimit(1)
                    if let ticketID = session?.meta.agentTask?.ticketID, let ticket = model.ticketLocation(ticketID)?.ticket {
                        Button(ticket.key) { navigate { model.openTicket(ticketID) } }.buttonStyle(.link).font(.caption)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .background(DebugCompletionMarker(name: "completion-done"))
            }.padding(20)
            Divider()
            ScrollView {
                if let session, let project = model.project(for: session.meta) {
                    let summary = TaskCompletionSummary(items: session.items)
                    VStack(alignment: .leading, spacing: 18) {
                        if session.isBusy { Label("This agent is working. Review updates when it finishes.", systemImage: "clock") }
                        else if let summary {
                            Label(summary.outcome == .completed ? "Task finished" : summary.outcome == .failed ? "Task failed" : "Task stopped",
                                  systemImage: summary.outcome == .completed ? "checkmark.circle" : "exclamationmark.circle")
                            if let reply = summary.reply { Text(reply).lineLimit(5).textSelection(.enabled).foregroundStyle(.secondary) }
                        }
                        changes(session, project: project, summary: summary)
                        verification(session, project: project, summary: summary)
                        preview(project, isolated: session.meta.agentTask?.workspace != nil)
                    }.padding(20)
                } else { ProgressView().padding(40) }
            }
        }
        .frame(width: 720, height: 640).background(Theme.canvas)
        .task(id: session?.changeCount) {
            await model.open(sessionID)
            guard let session, !session.isBusy, let project = model.project(for: session.meta),
                  let workspace = session.meta.agentTask?.workspace, workspace.status != .discarded else { return }
            let review = AgentReviewWorkspace(model: model, projectID: project.id, sessionID: sessionID)
            worktreeReview = review
            await review.refresh()
        }
        #if DEBUG
            .background(DebugViewMarker(name: "task-completion-view"))
        #endif
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).surface()
    }

    private func changes(_ session: SessionController, project: Project, summary: TaskCompletionSummary?) -> some View {
        let isolated = session.meta.agentTask?.workspace != nil
        let paths = worktreeReview?.review?.files.map(\.path) ?? summary?.changedFiles ?? []
        return section("Changed files") {
            Text(isolated ? "Changes in the isolated worktree must be reviewed and applied before they appear in the project preview." : "Files reported by successful tools in the latest turn. Review Changes shows the project's current diff.")
                .font(.caption).foregroundStyle(.secondary)
            if paths.isEmpty { Text("No file changes reported.").foregroundStyle(.secondary) }
            ForEach(paths, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
            if let error = worktreeReview?.error { Text(error).foregroundStyle(Theme.attention) }
            Button("Review Changes") {
                navigate {
                    if isolated { Task { await model.openAgentReview(session.id) } }
                    else { model.switchPanel(.changes) }
                }
            }.disabled(session.isBusy || session.meta.agentTask?.workspace?.status == .discarded)
                .background(DebugCompletionMarker(name: "completion-review-changes"))
        }
    }

    private func verification(_ session: SessionController, project: Project, summary: TaskCompletionSummary?) -> some View {
        let checks = model.taskVerifications[sessionID]
        return section("Checks") {
            if let record = session.meta.taskVerification {
                TaskVerificationFeedback(session: session)
                Text(record.command + " · " + record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                DisclosureGroup("Test output") { Text(record.output).font(Theme.codeSmall).textSelection(.enabled) }
            } else { Text("Tests not verified. A completed shell command alone does not establish that tests passed.").foregroundStyle(.secondary) }
            if checks?.running == true {
                HStack { ProgressView().controlSize(.small); Text("Running checks…"); Button("Stop Tests") { checks?.stop() } }
            } else {
                Button(session.meta.taskVerification == nil ? "Run Tests" : "Run Again") { model.taskVerification(for: sessionID).run() }
                    .disabled(session.isBusy || project.runtime != nil || checks?.hasUnsavedInputs == true || session.meta.agentTask?.workspace?.status == .discarded)
                    .background(DebugCompletionMarker(name: "completion-run-tests"))
            }
            if project.runtime != nil { Text("Run this project's tests in its configured runtime.").font(.caption).foregroundStyle(.secondary) }
            if let commands = summary?.commands, !commands.isEmpty {
                DisclosureGroup("Agent commands (\(commands.count))") {
                    ForEach(commands) { command in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.title + " · " + command.status.rawValue).font(Theme.codeSmall)
                            if !command.output.isEmpty { Text(String(command.output.suffix(3000))).font(Theme.codeSmall).foregroundStyle(.secondary) }
                        }.textSelection(.enabled).padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func navigate(_ action: @escaping () -> Void) {
        model.taskCompletionAction = action
        dismiss()
    }

    private func preview(_ project: Project, isolated: Bool) -> some View {
        let preview = model.previews[project.id]
        return section("Project preview") {
            PreviewStatusLabel(preview: preview)
            if let error = preview?.error { Text(error).foregroundStyle(Theme.attention) }
            if isolated { Text("Preview uses the main project, including changes you have applied.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(preview?.state == .running ? "Open Preview" : "Start Preview") {
                    navigate {
                        if preview?.state == .running { model.openRunningPreview(for: project) }
                        else { model.runPreview(for: project) }
                    }
                }.disabled(preview?.state == .starting)
                    .background(DebugCompletionMarker(name: "completion-open-preview"))
                Button("Settings and Logs…") { navigate { model.openPreviewSettings(for: project) } }
            }
        }
    }
}

struct TaskCompletionSheet: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        content.sheet(item: Binding<SessionMeta?>(
            get: { model.workspace.sessions.first { $0.id == model.taskCompletionID } },
            set: { if $0 == nil { model.taskCompletionID = nil } }
        ), onDismiss: {
            let action = model.taskCompletionAction
            model.taskCompletionAction = nil
            action?()
        }) { session in TaskCompletionView(sessionID: session.id).environment(model) }
    }
}

private struct DebugCompletionMarker: View {
    let name: String
    var body: some View {
        #if DEBUG
        DebugViewMarker(name: name)
        #else
        EmptyView()
        #endif
    }
}
