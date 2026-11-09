import MarikaCore
import SwiftUI

struct AgentTaskDetailView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let sessionID: UUID
    @State private var review: AgentReviewWorkspace?
    private var controller: SessionController? { model.controllers[sessionID] }
    private var meta: SessionMeta? { controller?.meta ?? model.workspace.sessions.first { $0.id == sessionID } }
    private var items: [TranscriptItem] { controller?.items ?? [] }
    private var artifacts: [ProjectArtifact] { (model.project(id: project.id)?.artifacts ?? []).filter { $0.sessionID == sessionID } }

    var body: some View {
        if let meta {
            let state = AgentTaskPresentation(meta: meta, items: items, phase: controller?.phase ?? .idle,
                approval: controller?.pendingApproval, activity: controller?.activity)
            let overview = AgentTaskOverview(meta: meta, items: items, phase: controller?.phase ?? .idle,
                approval: controller?.pendingApproval, activity: controller?.activity)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button("All agents", systemImage: "chevron.left") { model.selectedAgentTaskIDs[project.id] = nil }
                    Spacer()
                    Button(controller?.pendingApproval == nil ? "Open chat" : "Review approval") { model.openAgentChat(sessionID) }
                    if controller?.isBusy == true { Button("Stop", role: .destructive) { controller?.interrupt() } }
                }.controlSize(.small).padding(18)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(meta.title).font(.title2.bold()).textSelection(.enabled)
                            Label(state.state.rawValue, systemImage: state.state.isActive ? "circle.dotted" : "circle.fill").foregroundStyle(state.state.color)
                            Text(meta.agent.shortName + " · " + (meta.agentTask?.workspace == nil ? "Shared project files" : "Isolated worktree"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let next = meta.queuedAgent { Text("\(next.shortName) takes over after this turn.").font(.caption).foregroundStyle(.secondary) }
                            if let task = meta.agentTask { DisclosureGroup("Task instructions") { Text(task.prompt).textSelection(.enabled).padding(.top, 8) } }
                        }
                        section("Current activity", symbol: "waveform.path") {
                            Text(overview.activeStep ?? (state.state.isActive ? "Waiting for the next activity update." : state.preview ?? "No activity reported."))
                                .textSelection(.enabled)
                        }
                        section("Blockers", symbol: "exclamationmark.bubble") {
                            if overview.blockers.isEmpty { Text("No current blockers reported.").foregroundStyle(.secondary) }
                            ForEach(Array(overview.blockers.enumerated()), id: \.offset) { _, text in Text(text).foregroundStyle(Theme.attention).textSelection(.enabled) }
                        }
                        section("Plan", symbol: "checklist") {
                            if let plan = meta.taskPlan, !plan.isEmpty {
                                Text("Latest plan reported by the agent").font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(plan.enumerated()), id: \.offset) { _, item in
                                    Label(item.text, systemImage: item.status == .completed ? "checkmark.circle.fill" : item.status == .inProgress ? "circle.dotted" : "circle")
                                        .foregroundStyle(item.status == .completed ? Color.secondary : Color.primary)
                                }
                            } else if let plan = artifacts.last(where: { $0.kind == .plan }) {
                                MarkdownView(text: plan.body).environment(\.projectRoot, taskRoot(meta))
                            } else { Text("No plan published yet. Progress steps appear when the agent reports a plan.").foregroundStyle(.secondary) }
                        }
                        changes(meta, overview: overview)
                        verification(meta, overview: overview)
                        section("Deliverables", symbol: "doc.on.doc") {
                            if artifacts.isEmpty, !(model.project(id: project.id)?.research?.contains(where: { $0.sessionID == sessionID && $0.report != nil }) ?? false) {
                                Text("No deliverables published yet.").foregroundStyle(.secondary)
                            }
                            ForEach(artifacts) { artifact in
                                DisclosureGroup(artifact.title + " · " + artifact.kind.rawValue) {
                                    MarkdownView(text: artifact.body).environment(\.projectRoot, taskRoot(meta)).textSelection(.enabled).padding(.top, 10)
                                }
                            }
                            ForEach((model.project(id: project.id)?.research ?? []).filter { $0.sessionID == sessionID && $0.report != nil }) { run in
                                Button("Research: " + run.question) { model.selectedResearchIDs[project.id] = run.id; model.switchPanel(.research) }
                            }
                            if !artifacts.isEmpty { Button("Review plans and artifacts") { model.showExperience("Artifacts", project: project) } }
                        }
                    }.padding(22).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
                }
            }.background(Theme.canvas)
            .task(id: "\(controller?.phase ?? .idle)-\(controller?.changeCount ?? 0)") {
                await model.open(sessionID)
                if controller?.isBusy == true { review = nil }
                if let workspace = controller?.meta.agentTask?.workspace, workspace.status != .discarded, controller?.isBusy != true {
                    let value = AgentReviewWorkspace(model: model, projectID: project.id, sessionID: sessionID)
                    review = value; await value.refresh()
                }
            }
        } else {
            ContentUnavailableView("Task unavailable", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    private func taskRoot(_ meta: SessionMeta) -> URL { meta.agentTask?.workspace.map { URL(fileURLWithPath: $0.workingPath) } ?? project.url }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).surface()
    }
    private func changes(_ meta: SessionMeta, overview: AgentTaskOverview) -> some View {
        let paths = review?.review?.files.map(\.path) ?? overview.changedFiles
        return section("Changed files", symbol: "arrow.triangle.branch") {
            Text(review?.review != nil ? "Current isolated worktree review" : meta.agentTask?.workspace == nil ? "File edits reported by successful tools in this chat." : "Reported tool edits; open review for the complete worktree diff.")
                .font(.caption).foregroundStyle(.secondary)
            if paths.isEmpty { Text("No changed files available.").foregroundStyle(.secondary) }
            ForEach(paths, id: \.self) { path in Text(path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
            if let error = review?.error { Text(error).foregroundStyle(Theme.attention) }
            if let workspace = meta.agentTask?.workspace, workspace.status == .ready || workspace.status == .reviewed {
                Button("Review changes") { Task { await model.openAgentReview(sessionID) } }.disabled(controller?.isBusy == true)
            }
        }
    }
    private func verification(_ meta: SessionMeta, overview: AgentTaskOverview) -> some View {
        let checks = model.taskVerifications[sessionID]
        let scope = ReviewTestScope.resolve(paths: [], root: taskRoot(meta))
        let title = scope.framework + " · " + scope.title
        return section("Verification", symbol: "checkmark.shield") {
            HStack {
                Text(checks?.running == true ? "Running tests…" : title).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                if checks?.running == true { ProgressView().controlSize(.mini); Button("Stop tests") { checks?.stop() } }
                else { Button(meta.taskVerification == nil ? "Run tests" : "Run Again") { model.taskVerification(for: sessionID).run() }.disabled(checks?.hasUnsavedInputs == true || controller == nil || controller?.isBusy == true || meta.agentTask?.workspace?.status == .discarded || project.runtime != nil) }
            }
            if let result = meta.taskVerification {
                TaskVerificationFeedback(sessionID: sessionID)
                Text("\(result.command) · \(result.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Test output") { SelectableMessageText(result.output, markdown: false, font: .monospacedSystemFont(ofSize: 11, weight: .regular)) }
            } else { Text("No tests run from this task page yet.").foregroundStyle(.secondary) }
            if !overview.commands.isEmpty {
                DisclosureGroup("Commands observed in the agent transcript") {
                    ForEach(overview.commands) { call in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(call.title).font(.caption.monospaced()).textSelection(.enabled)
                            Text(call.status.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                            if !call.output.isEmpty { Text(String(call.output.suffix(3000))).font(.caption.monospaced()).textSelection(.enabled) }
                        }.padding(.vertical, 6)
                    }
                }
                Text("Command completion alone does not establish that tests passed.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
