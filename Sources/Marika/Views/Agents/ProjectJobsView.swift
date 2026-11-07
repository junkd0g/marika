import MarikaCore
import SwiftUI

struct ProjectJobsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var onOpenChat: () -> Void = {}
    @State private var editing: ProjectSchedule?
    @State private var error: String?
    private var jobs: [ProjectSchedule] { model.project(id: project.id)?.tools?.schedules ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Work that keeps moving").font(.system(size: 24, weight: .semibold))
                        Text("Give your agents recurring work. Pick a cadence and follow every run in chat.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 10)
                    Button { addJob() } label: { Label("New job", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                        #if DEBUG
                            .background(DebugViewMarker(name: "jobs-create"))
                        #endif
                }
                HStack(spacing: 16) {
                    stat("Scheduled", value: jobs.filter(\.enabled).count, symbol: "calendar")
                    stat("Working", value: jobs.filter { isRunning($0) }.count, symbol: "bolt.fill")
                    stat("Need attention", value: jobs.filter { $0.lastError != nil || needsApproval($0) }.count, symbol: "bell.badge")
                }
                if let error { Text(error).font(.callout).foregroundStyle(Theme.attention) }
                if jobs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                        Text("Your team's next routine").font(.system(size: 17, weight: .semibold))
                        Text("A morning code review, a weekly dependency check, or a daily test report. Each run has its own agent conversation and saved result.")
                            .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                        Button("Create a scheduled job") { addJob() }.buttonStyle(.link)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24).surface(cornerRadius: 14)
                }
                ForEach(jobs) { job in jobCard(job) }
                Label("Jobs run while Marika is open and your Mac is awake. One missed run catches up on reopening. Runs never overlap for the same job.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }
            .padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .sheet(item: $editing) { job in
            ProjectJobEditor(project: project, initial: job) { updated in
                var tools = model.project(id: project.id)?.tools ?? ProjectTools()
                if let index = tools.schedules.firstIndex(where: { $0.id == updated.id }) { tools.schedules[index] = updated }
                else { tools.schedules.append(updated) }
                try model.saveTools(tools, for: project)
            }
        }
        .task(id: jobs.flatMap(\.runs)) {
            for id in jobs.flatMap(\.runs) { await model.open(id) }
        }
        #if DEBUG
            .background(DebugViewMarker(name: "jobs-panel"))
        #endif
    }

    private func stat(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value, format: .number).font(.system(size: 24, weight: .medium, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16).surface(cornerRadius: 12)
    }

    private func jobCard(_ job: ProjectSchedule) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.checkmark").font(.system(size: 19)).foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name).font(.system(size: 14, weight: .semibold))
                    Text(job.agent.shortName + " · " + (job.model ?? "Default model")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(isRunning(job) ? "Working" : (job.enabled ? "Scheduled" : "Paused"))
                    .font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background((isRunning(job) ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
                Menu {
                    Button("Edit job…") { editing = job }
                    Button(job.enabled ? "Pause" : "Resume") { update(job) { $0.enabled.toggle() } }
                    Divider()
                    Button("Delete job", role: .destructive) { delete(job) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Job options")
            }
            Text(job.prompt).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).lineSpacing(3)
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(job.cadence).textSelection(.enabled)
            }
            .font(.system(size: 11, design: job.cron == nil ? .default : .monospaced)).foregroundStyle(.secondary)
            if job.enabled {
                Text("Next · " + ProjectJobEditor.dateLabel(job.nextRun, zoneID: job.timeZoneID))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let lastError = job.lastError { Text(lastError).font(.system(size: 11)).foregroundStyle(Theme.attention) }
            HStack {
                Button { Task { do { try await model.runJobNow(job.id, projectID: project.id) } catch { self.error = error.localizedDescription } } } label: {
                    Label("Run now", systemImage: "play.fill")
                }.disabled(isRunning(job) || model.launchingJobs.contains(job.id))
                Button("Edit") { editing = job }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if let id = job.runs.last {
                    Button(needsApproval(job) ? "Review approval →" : "Open run →") { onOpenChat(); model.openAgentChat(id) }.buttonStyle(.link)
                }
            }
            if !job.runs.isEmpty {
                DisclosureGroup("Recent runs · \(job.runs.count)") {
                    VStack(spacing: 0) {
                        ForEach(job.runs.reversed(), id: \.self) { id in
                            if let session = model.workspace.sessions.first(where: { $0.id == id }) {
                                Button { onOpenChat(); model.openAgentChat(id) } label: {
                                    HStack {
                                        Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        Spacer()
                                        Text(runStatus(id)).foregroundStyle(.secondary)
                                        Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                                    }.font(.system(size: 11)).padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(.top, 6)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(18).floatingPanel(cornerRadius: 14)
    }

    private func isRunning(_ job: ProjectSchedule) -> Bool { job.runs.contains { model.controllers[$0]?.isBusy == true } }
    private func needsApproval(_ job: ProjectSchedule) -> Bool { job.runs.contains { model.controllers[$0]?.pendingApproval != nil } }
    private func runStatus(_ id: UUID) -> String {
        guard let controller = model.controllers[id] else { return "Saved run" }
        if controller.pendingApproval != nil { return "Needs approval" }
        if controller.isBusy { return "Working" }
        if let item = controller.items.last, case .turnEnd(let summary) = item.content {
            switch summary.outcome { case .completed: return "Completed"; case .failed: return "Failed"; case .interrupted: return "Stopped" }
        }
        return "Saved run"
    }
    private func addJob() {
        var job = ProjectSchedule(name: "", prompt: "", agent: .codex, hours: 24)
        job.cron = "0 9 * * 1-5"; job.timeZoneID = TimeZone.current.identifier
        editing = job
    }
    private func update(_ job: ProjectSchedule, change: (inout ProjectSchedule) -> Void) {
        var tools = model.project(id: project.id)?.tools ?? ProjectTools()
        guard let index = tools.schedules.firstIndex(where: { $0.id == job.id }) else { return }
        change(&tools.schedules[index])
        do { try model.saveTools(tools, for: project); error = nil } catch { self.error = error.localizedDescription }
    }
    private func delete(_ job: ProjectSchedule) {
        var tools = model.project(id: project.id)?.tools ?? ProjectTools()
        tools.schedules.removeAll { $0.id == job.id }
        do { try model.saveTools(tools, for: project); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct ProjectJobEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let initial: ProjectSchedule
    let save: (ProjectSchedule) throws -> Void
    @State private var draft: ProjectSchedule
    @State private var usesCron: Bool
    @State private var expression: String
    @State private var zone: String
    @State private var error: String?

    init(project: Project, initial: ProjectSchedule, save: @escaping (ProjectSchedule) throws -> Void) {
        self.project = project; self.initial = initial; self.save = save
        _draft = State(initialValue: initial); _usesCron = State(initialValue: initial.cron != nil)
        _expression = State(initialValue: initial.cron ?? "0 9 * * 1-5")
        _zone = State(initialValue: initial.timeZoneID ?? TimeZone.current.identifier)
    }

    private var candidate: ProjectSchedule {
        var job = draft
        job.name = job.name.trimmingCharacters(in: .whitespacesAndNewlines)
        job.prompt = job.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        job.cron = usesCron ? expression.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        job.timeZoneID = usesCron ? zone.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return job
    }
    private var nextRun: Result<Date, Error> { Result { try candidate.nextOccurrence(after: Date()) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(initial.name.isEmpty ? "New recurring job" : "Edit job").font(.system(size: 20, weight: .semibold))
                    Text(project.name).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    #if DEBUG
                        .background(DebugViewMarker(name: "job-editor-cancel"))
                    #endif
                Button("Save job") {
                    do { try save(candidate); dismiss() } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(candidate.name.isEmpty || candidate.prompt.isEmpty || (try? nextRun.get()) == nil)
                    #if DEBUG
                        .background(DebugViewMarker(name: "job-editor-save"))
                    #endif
            }
            if let error { Text(error).font(.callout).foregroundStyle(Theme.attention) }
            TextField("Job name, e.g. Morning code review", text: $draft.name).textFieldStyle(.plain).jobInput()
            VStack(alignment: .leading, spacing: 7) {
                Text("What should the agent do?").font(.system(size: 12, weight: .medium))
                TextEditor(text: $draft.prompt).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .frame(height: 105).padding(10).surface()
            }
            HStack {
                Picker("Agent", selection: $draft.agent) { ForEach(AgentKind.allCases) { Text($0.shortName).tag($0) } }
                Picker("Model", selection: Binding(get: { draft.model ?? "" }, set: { draft.model = $0.isEmpty ? nil : $0 })) {
                    Text("Agent default").tag("")
                    ForEach(model.capabilities[draft.agent]?.models.filter { $0.id != "default" } ?? []) { Text($0.name).tag($0.id) }
                }
            }
            .onChange(of: draft.agent) { _, _ in draft.model = nil }
            Picker("Schedule", selection: $usesCron) { Text("Cron schedule").tag(true); Text("Fixed interval").tag(false) }.pickerStyle(.segmented)
            if usesCron {
                HStack {
                    TextField("0 9 * * 1-5", text: $expression).font(.system(size: 14, design: .monospaced)).textFieldStyle(.plain).jobInput()
                    Menu("Presets") {
                        Button("Every 15 minutes") { expression = "*/15 * * * *" }
                        Button("Every weekday at 9") { expression = "0 9 * * 1-5" }
                        Button("Every Monday at 10") { expression = "0 10 * * MON" }
                        Button("First of each month") { expression = "0 9 1 * *" }
                    }.fixedSize()
                }
                Text("minute  hour  day  month  weekday").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                TextField("Time zone, e.g. Europe/London", text: $zone).textFieldStyle(.plain).jobInput()
            } else { Stepper("Every \(draft.hours) hours", value: $draft.hours, in: 1...8760) }
            switch nextRun {
            case .success(let date):
                Label("Next run · " + Self.dateLabel(date, zoneID: candidate.timeZoneID), systemImage: "calendar.badge.clock")
                    .font(.callout).foregroundStyle(Color.accentColor)
            case .failure(let error):
                Text(error.localizedDescription).font(.callout).foregroundStyle(Theme.attention)
            }
            Toggle("Enabled", isOn: $draft.enabled).toggleStyle(.switch)
            Text("Each run creates an agent chat with an isolated Git worktree when available. Approvals stay on. Marika must be open; missed runs catch up once. Cron skips missing DST times and runs repeated local times once.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
        }
        .controlSize(.regular).padding(24).frame(width: 560)
    }

    static func dateLabel(_ date: Date, zoneID: String?) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.dateFormat = "EEE, d MMM · HH:mm z"
        return formatter.string(from: date)
    }
}

private extension View {
    func jobInput() -> some View {
        padding(11).background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline) }
    }
}
