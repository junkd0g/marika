import MarikaCore
import SwiftUI

struct TaskSheets: ViewModifier {
    @Bindable var model: AppModel
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { model.taskQueueProjectID.flatMap(model.project(id:)) }, set: { if $0 == nil { model.taskQueueProjectID = nil } })) { project in
            TaskQueueView(project: project).environment(model)
        }.sheet(item: Binding(get: { model.taskActivityProjectID.flatMap(model.project(id:)) }, set: { if $0 == nil { model.taskActivityProjectID = nil } })) { project in
            TaskActivityView(project: project).environment(model)
        }
    }
}

struct TaskQueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    private var queue: AgentTaskQueue { model.project(id: project.id)?.taskQueue ?? AgentTaskQueue() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Task queue").font(.title2.bold())
                    Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(queue.pendingCount) pending · \(queue.items.count { $0.state == .failed }) failed · \(queue.isPaused ? "Paused" : "Starts when a slot is available")").foregroundStyle(.secondary)
                }
                Spacer()
                Button(queue.isPaused ? "Resume queue" : "Pause queue") { model.setTaskQueuePaused(!queue.isPaused, projectID: project.id) }.disabled(queue.items.isEmpty)
                Button("Done") { dismiss() }
            }
            Text("Queue work from New Agent. Up to four agents can work in this project. Pausing affects future starts; running agents continue. Saved queues reopen paused after restart.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if queue.items.isEmpty {
                ContentUnavailableView("No queued tasks", systemImage: "list.bullet.clipboard", description: Text("Choose Queue task in the New Agent form to submit work without waiting for a free slot."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(queue.items.filter { $0.state != .launched && $0.state != .cancelled }) { item in card(item) }
                        let history = queue.items.filter { $0.state == .launched || $0.state == .cancelled }
                        if !history.isEmpty {
                            DisclosureGroup("Recent starts and cancellations (\(history.count))") {
                                ForEach(history.reversed()) { item in card(item) }
                            }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.padding(22).frame(width: 690, height: 570).background(Theme.canvas)
    }
    private func card(_ item: QueuedAgentTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(item.title).font(.headline).lineLimit(2)
                Spacer()
                Text(item.state == .launched ? "Started" : item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.agent.shortName + " · " + item.settings.mode.title(for: item.agent) + " · " + (item.isolated ? "Isolated when Git is available" : "Shared files"))
                .font(.caption).foregroundStyle(.secondary)
            Text(item.prompt).lineLimit(3).textSelection(.enabled)
            if let error = item.error { Text(error).foregroundStyle(Theme.attention).textSelection(.enabled) }
            HStack {
                if item.state == .queued {
                    Button("Move up", systemImage: "arrow.up") { model.updateTaskQueue(project.id) { $0.move(item.id, offset: -1) } }
                    Button("Move down", systemImage: "arrow.down") { model.updateTaskQueue(project.id) { $0.move(item.id, offset: 1) } }
                }
                if item.state == .failed { Button("Requeue") { model.updateTaskQueue(project.id) { $0.retry(item.id) } } }
                if item.state == .queued || item.state == .failed {
                    Button("Cancel task", role: .destructive) { model.updateTaskQueue(project.id) { $0.cancel(item.id) } }
                }
                Spacer()
                if let id = item.sessionID, model.workspace.sessions.contains(where: { $0.id == id }) {
                    Button("Open task") { dismiss(); model.selectedAgentTaskIDs[project.id] = id; model.showAgents(for: project) }
                }
            }.controlSize(.small)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
    }
}

struct TaskActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var unreadOnly = false
    private var events: [TaskActivity] { (model.project(id: project.id)?.taskActivity ?? []).reversed() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Task activity").font(.title2.bold())
                    Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Mark all read") { model.markTaskActivityRead(nil, projectID: project.id) }.disabled(!events.contains { !$0.isRead })
                Button("Done") { dismiss() }
            }
            Picker("Activity", selection: $unreadOnly) { Text("All").tag(false); Text("Unread").tag(true) }.pickerStyle(.segmented)
            let visible = events.filter { !unreadOnly || !$0.isRead }
            if visible.isEmpty {
                ContentUnavailableView("You're up to date", systemImage: "bell", description: Text("Approvals, outcomes and queue failures are saved here, even while Marika is active."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visible) { event in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    if !event.isRead { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                                    Text(event.kind.title).font(.headline)
                                    Spacer()
                                    Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(event.taskTitle).textSelection(.enabled)
                                if let detail = event.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                HStack {
                                    if !event.isRead { Button("Mark read") { model.markTaskActivityRead(event.id, projectID: project.id) } }
                                    Spacer()
                                    if event.queueID != nil || model.workspace.sessions.contains(where: { $0.id == event.sessionID }) {
                                        Button(event.queueID != nil ? "View queue" : event.kind == .approval ? "Open chat" : "Open task") { model.openTaskActivity(event.id, projectID: project.id) }
                                    } else { Text("Chat no longer available").font(.caption).foregroundStyle(.secondary) }
                                }.controlSize(.small)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
                        }
                    }
                }
            }
        }.padding(22).frame(width: 650, height: 540).background(Theme.canvas)
    }
}
