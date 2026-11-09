import AppKit
import MarikaCore
import SwiftUI

struct AgentReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionMeta
    @State private var review: AgentChangeReview?
    @State private var error: String?
    @State private var busy = false
    @State private var confirmingDiscard = false
    private var workspace: AgentWorkspace? { model.controllers[session.id]?.meta.agentTask?.workspace ?? session.agentTask?.workspace }
    private var agentIsBusy: Bool { model.controllers[session.id]?.isBusy == true }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Review Agent Changes").font(.system(size: 20, weight: .semibold))
                    Text(session.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    #if DEBUG
                        .background(DebugViewMarker(name: "agent-review-close"))
                    #endif
            }.padding(20)
            Divider()
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.attention).padding(16)
                    #if DEBUG
                        .background(DebugViewMarker(name: "agent-review-error"))
                    #endif
            }
            if let review {
                if review.isEmpty {
                    ContentUnavailableView("No changes to apply", systemImage: "checkmark.circle")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(Array(review.files.enumerated()), id: \.offset) { _, file in
                                DiffView(file: file, initialLimit: 600)
                            }
                        }.padding(20)
                    }
                }
            } else if busy { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
            Divider()
            HStack(spacing: 10) {
                Button("Open Worktree") {
                    if let workspace { NSWorkspace.shared.open(URL(fileURLWithPath: workspace.workingPath)) }
                }
                Button("Refresh") { Task { await refresh() } }.disabled(busy || agentIsBusy)
                Button("Review in Editor") {
                    dismiss()
                    Task { await model.openAgentReview(session.id) }
                }.disabled(agentIsBusy)
                Spacer()
                Button("Discard…", role: .destructive) { confirmingDiscard = true }.disabled(busy || agentIsBusy)
                Button("Apply to Project") { Task { await apply() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy || agentIsBusy || review?.isEmpty != false)
            }.controlSize(.small).padding(16)
        }
        .frame(width: 780, height: 580).background(Theme.canvas)
        .task { await refresh() }
        .confirmationDialog("Discard this agent's worktree and its changes?", isPresented: $confirmingDiscard) {
            Button("Discard Worktree", role: .destructive) { Task { await discard() } }
        } message: { Text("Your project's files will remain unchanged.") }
    }
    private func refresh() async {
        guard let workspace else { return }
        guard !agentIsBusy else { error = "Stop the agent or wait for it to finish before reviewing changes."; return }
        busy = true; error = nil
        defer { busy = false }
        do { review = try await model.worktreeService.review(workspace, project: model.project(for: session)?.url) }
        catch { self.error = error.localizedDescription }
    }
    private func apply() async {
        guard let review, let project = model.project(for: session), !agentIsBusy else { return }
        busy = true; error = nil
        defer { busy = false }
        let controller = AgentReviewWorkspace(model: model, projectID: project.id, sessionID: session.id)
        controller.review = review
        await controller.acceptRemaining()
        if let failure = controller.error { error = failure }
        else { dismiss() }
    }
    private func discard() async {
        guard var workspace, let project = model.project(for: session), !agentIsBusy else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.worktreeService.discard(workspace, project: project.url)
            workspace.status = .discarded
            model.updateAgentWorkspace(workspace, sessionID: session.id)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
