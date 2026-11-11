import MarikaCore
import SwiftUI

struct ContainerRecoveryRequest: Identifiable {
    let id = UUID()
    let resource: ContainerResource
    let target: ContainerTarget
    let scope: String
    let rollback: Bool
}

struct ContainerRecoveryView: View {
    let workspace: ContainerWorkspace
    let request: ContainerRecoveryRequest
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [ContainerRevision] = []
    @State private var selection: Int?
    @State private var review: ContainerRecoveryReview?
    @State private var loading = false
    @State private var error: String?
    private var current: Bool { workspace.scope == request.scope && workspace.target == request.target }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(review?.title ?? (request.rollback ? "Deployment history" : "Review job run")).font(.title2.weight(.semibold))
            Text(request.target.name + " · namespace " + request.resource.namespace).font(.headline).textSelection(.enabled)
            if loading { HStack { ProgressView().controlSize(.small); Text("Preparing review…").font(.callout) } }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            if let review {
                Text(review.explanation).font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summary("Current", review.before)
                        summary(request.rollback ? "Selected revision" : "New job", review.after)
                    }
                }
                Text("Container environment values are omitted from this summary. The complete reviewed template is used.").font(.caption).foregroundStyle(.secondary)
            } else if request.rollback {
                if revisions.isEmpty && !loading { ContentUnavailableView("No retained revisions", systemImage: "clock.arrow.circlepath", description: Text("This Deployment has no history available for rollback.")) }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(revisions) { revision in
                            Button { selection = revision.revision } label: {
                                HStack {
                                    Image(systemName: selection == revision.revision ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Revision \(revision.revision)" + (revision.revision == request.resource.revision ? " · current" : "")).font(.headline)
                                        Text(revision.images).font(.caption).lineLimit(2)
                                    }
                                    Spacer()
                                }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).disabled(revision.revision == request.resource.revision)
                            #if DEBUG
                            .background(DebugViewMarker(name: "container-revision-\(revision.revision)"))
                            #endif
                        }
                    }
                }
            }
            if !current { Text("The context changed. Close this review and start again.").font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let review {
                    Button(request.rollback ? "Confirm rollback" : "Run new job") {
                        guard current else { return }
                        workspace.submit(ContainerOperationPrompt(title: review.title, detail: review.explanation, scope: request.scope, operation: .recover(review)))
                        dismiss()
                    }.buttonStyle(WorkspaceButtonStyle(kind: .primary)).disabled(!current || loading || workspace.isBusy)
                    #if DEBUG
                    .background(DebugViewMarker(name: "container-recovery-confirm"))
                    #endif
                } else if request.rollback {
                    Button("Review revision") { Task { await prepareRevision() } }.buttonStyle(WorkspaceButtonStyle(kind: .primary)).disabled(selection == nil || loading || !current)
                        #if DEBUG
                        .background(DebugViewMarker(name: "container-revision-review"))
                        #endif
                }
            }
        }.padding(24).frame(width: 680, height: 560)
        .task {
            loading = true
            do {
                if request.rollback { revisions = try await workspace.cli.revisions(request.resource, target: request.target) }
                else { review = try await workspace.cli.prepareRetry(request.resource, target: request.target) }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            loading = false
        }
        #if DEBUG
        .background(DebugViewMarker(name: "container-recovery-review"))
        #endif
    }
    private func prepareRevision() async {
        guard let revision = revisions.first(where: { $0.revision == selection }), current else { return }
        loading = true; error = nil
        do { review = try await workspace.cli.prepareRollback(request.resource, target: request.target, revision: revision) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    private func summary(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
