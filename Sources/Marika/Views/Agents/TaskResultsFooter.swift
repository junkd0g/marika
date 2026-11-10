import MarikaCore
import SwiftUI

/// Direct next steps for an edited workspace, kept with the assistant's response.
struct TaskResultsFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.conversationIsVisible) private var isVisible
    let session: SessionController
    let summary: TaskCompletionSummary
    @State private var showsChecks = false
    @State private var showsOutput = false
    @State private var detectedPreview = false
    private struct MonitorID: Equatable { let record: TaskVerificationRecord?; let visible: Bool }
    private var project: Project? { model.project(for: session.meta) }
    private var checks: TaskVerificationWorkspace? { model.taskVerifications[session.id] }
    private var record: TaskVerificationRecord? { session.meta.taskVerification }
    private var workspace: AgentWorkspace? { session.meta.agentTask?.workspace }
    private var linkedTicket: SpaceTicket? { session.meta.agentTask?.ticketID.flatMap { model.ticketLocation($0)?.ticket } }
    private var hasResults: Bool {
        workspace?.status != .discarded && (!summary.changedFiles.isEmpty || workspace?.status == .ready || linkedTicket != nil)
    }
    private var preview: ProjectPreview? { project.flatMap { model.previews[$0.id] } }
    private var canPreview: Bool { detectedPreview || project?.previewConfiguration != nil || preview != nil }
    private var checksTint: Color {
        if checks?.passed == true { return .green }
        if record != nil && (checks?.status == .outdated || record?.succeeded == false) { return Theme.attention }
        return .secondary
    }

    var body: some View {
        if hasResults, let project {
            VStack(alignment: .leading, spacing: 12) {
                if let ticket = linkedTicket {
                    Button { model.openTicket(ticket.id) } label: { Label(ticket.key + " · " + ticket.displayTitle, systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.action).lineLimit(1)
                        .accessibilityLabel("Open ticket " + ticket.key)
                        .background(ResultMarker(name: "task-results-ticket"))
                }
                if summary.outcome != .completed {
                    Label(summary.outcome == .failed ? "Task failed · partial changes" : "Task stopped · partial changes", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(Theme.attention)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { changes(project); checksButton; previewButton(project); Spacer(minLength: 0); more(project) }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { changes(project); Spacer(minLength: 0); more(project) }
                        checksButton
                        previewButton(project)
                    }
                }
                if workspace?.status == .ready {
                    Text("Changes stay in the agent's workspace until you apply them.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = preview?.error {
                    HStack(alignment: .top) {
                        Text(error).font(.caption).foregroundStyle(Theme.attention)
                        Button("Settings") { model.openPreviewSettings(for: project) }.buttonStyle(.link).font(.caption)
                    }
                }
                if showsChecks { checkDetails(project) }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .background(ResultMarker(name: "task-results"))
            .task(id: MonitorID(record: record, visible: isVisible)) {
                let checks = model.taskVerification(for: session.id)
                if isVisible, record != nil { await checks.monitor() }
            }
            .task(id: project.path) {
                let root = project.url
                detectedPreview = await Task.detached { ProjectPreview.detect(at: root) != nil }.value
            }
            .onChange(of: record) { if record?.succeeded == false { showsOutput = true } }
        }
    }

    private func changes(_ project: Project) -> some View {
        Button {
            if workspace != nil { Task { await model.openAgentReview(session.id) } }
            else { model.switchPanel(.changes) }
        } label: {
            Label(summary.changedFiles.isEmpty ? "View changes" : "\(summary.changedFiles.count) \(summary.changedFiles.count == 1 ? "file" : "files") changed", systemImage: "doc.text")
        }.buttonStyle(ResultActionStyle(emphasized: true))
            .help(workspace == nil ? "Open the project's current changes" : "Review changes before applying them to the project")
            .background(ResultMarker(name: "task-results-changes"))
    }

    private var checksButton: some View {
        Button {
            if record == nil && checks?.running != true {
                showsChecks = true
                model.taskVerification(for: session.id).run()
            } else { showsChecks.toggle() }
        } label: {
            HStack(spacing: 6) {
                if checks?.running == true { ProgressView().controlSize(.mini) }
                else { Image(systemName: checks?.passed == true ? "checkmark.circle.fill" : record == nil ? "play.circle" : "checklist")
                    .foregroundStyle(checksTint) }
                Text(checks?.running == true ? "Running checks…" : record == nil ? "Run checks" : "Checks · " + (checks?.label ?? "Checking…"))
                if record != nil || checks?.running == true { Image(systemName: showsChecks ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)) }
            }
        }.buttonStyle(ResultActionStyle())
            .accessibilityLabel(checks?.running == true ? "Show running checks" : record == nil ? "Run checks" : "Checks: " + (checks?.label ?? "Checking freshness"))
            .background(ResultMarker(name: "task-results-checks"))
    }

    @ViewBuilder private func previewButton(_ project: Project) -> some View {
        if canPreview {
            Button {
                if preview?.state == .running { model.openRunningPreview(for: project) }
                else { model.runPreview(for: project) }
            } label: {
                Label(preview?.state == .starting ? "Starting preview…" : preview?.state == .running ? "Open preview" : preview?.state == .failed ? "Retry preview" : "Preview",
                      systemImage: "play.rectangle")
            }.buttonStyle(ResultActionStyle()).disabled(preview?.state == .starting)
                .help(workspace == nil ? "Open the project preview" : "Preview the project with changes you have already applied")
                .background(ResultMarker(name: "task-results-preview"))
        }
    }

    private func more(_ project: Project) -> some View {
        Menu {
            Button("Task results…") { model.taskCompletionID = session.id }
            Button("Preview settings and logs…") { model.openPreviewSettings(for: project) }
        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 30).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More result actions")
    }

    private func checkDetails(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(checks?.running == true ? "Running checks" : record == nil ? "Checks" : checks?.label ?? "Checking freshness…")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { showsChecks = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Hide check details")
                    .background(ResultMarker(name: "task-results-close-checks"))
            }
            if checks?.hasUnsavedInputs == true { Text("Save your edits before running checks.").font(.caption).foregroundStyle(.secondary) }
            else if let detail = checks?.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if project.runtime != nil { Text("Run this project's checks in its configured runtime.").font(.caption).foregroundStyle(.secondary) }
            if let record {
                Text(record.command + " · " + record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                DisclosureGroup("Test output", isExpanded: $showsOutput) {
                    ScrollView {
                        Text(record.output).font(Theme.codeSmall).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.frame(maxHeight: 180).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7))
                }.font(.system(size: 11))
            } else if checks?.running != true { Text("Run checks to verify these changes.").font(.caption).foregroundStyle(.secondary) }
            if checks?.running == true {
                Button("Stop checks", systemImage: "stop.fill") { checks?.stop() }.buttonStyle(WorkspaceButtonStyle(kind: .destructive, compact: true))
            } else {
                Button(record == nil ? "Run checks" : "Run again", systemImage: "play.fill") { model.taskVerification(for: session.id).run() }
                    .buttonStyle(WorkspaceButtonStyle(kind: .secondary, compact: true))
                    .disabled(project.runtime != nil || checks?.hasUnsavedInputs == true)
                    .background(ResultMarker(name: "task-results-run-checks"))
            }
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .background(ResultMarker(name: "task-results-checks-details"))
    }
}

private struct ResultActionStyle: ButtonStyle {
    var emphasized = false
    func makeBody(configuration: Configuration) -> some View { Appearance(configuration: configuration, emphasized: emphasized) }
    private struct Appearance: View {
        let configuration: Configuration
        let emphasized: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        var body: some View {
            configuration.label.font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(emphasized ? Theme.action : Theme.ink)
                .padding(.horizontal, 11).frame(height: 32)
                .background(emphasized ? Theme.action.opacity(hovered ? 0.14 : 0.08) : hovered ? Theme.selection : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(emphasized ? Theme.action.opacity(0.18) : Theme.hairline) }
                .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.65 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 8)).onHover { hovered = $0 }
        }
    }
}

private struct ResultMarker: View {
    let name: String
    var body: some View {
        #if DEBUG
        DebugViewMarker(name: name)
        #else
        EmptyView()
        #endif
    }
}
