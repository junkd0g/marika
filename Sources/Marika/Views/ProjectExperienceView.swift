import MarikaCore
import SwiftUI

struct ProjectExperienceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var section = "Recovery"
    @State private var command = ""
    @State private var selectedDebugRun: UUID?
    @State private var error: String?
    @State private var restoring = false
    @State private var pendingRestore: CodeCheckpoint?
    private var current: Project { model.project(id: project.id) ?? project }
    private var history: [DebugRun] { current.debugRuns ?? [] }
    private var debugRun: DebugRun? { history.first { $0.id == selectedDebugRun } ?? history.last }
    private var debugTask: Task<Void, Never>? { model.projectRuntimeTools[project.id]?.debugTask }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                WorkspaceHeading(title: "Workspace tools", subtitle: project.name)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(WorkspaceButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
            }
            Picker("Workspace tools", selection: $section) {
                Text("Checkpoints").tag("Recovery")
                Text("Runtime debugging").tag("Debug")
                Text("Artifacts").tag("Artifacts")
            }.pickerStyle(.segmented).labelsHidden().controlSize(.regular)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if section == "Recovery" { recovery } else if section == "Debug" { debugging } else { ProjectArtifactsView(project: project).environment(model) }
        }.font(.system(size: 12)).controlSize(.small).padding(24).frame(width: 880, height: 620).background(Theme.canvas)
            .task {
                section = model.experienceSection
                command = model.debugCommands[project.id] ?? ""
                await model.reloadCheckpoints(project.id)
            }
            .confirmationDialog("Restore the code from before this turn?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
                Button("Restore code", role: .destructive) {
                    guard let record = pendingRestore else { return }
                    pendingRestore = nil; restoring = true
                    Task {
                        defer { restoring = false }
                        do { try await model.restoreCheckpoint(record); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } message: { Text("Conversation history stays. Files edited after the turn will block restoration. Git commits and staged changes are not rewound.") }
    }
    private var recovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automatic snapshots before agent turns. Restore saved source files, including edits made by shell commands.").foregroundStyle(.secondary).font(.callout)
            Text("Saved files only · Git-ignored files excluded · Up to 5 MB per file and 100 MB per snapshot").font(.caption).foregroundStyle(.secondary)
            if let error = model.debugErrors[project.id] { Text(error).foregroundStyle(.red).font(.caption) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.checkpointRecords[project.id] ?? []) { record in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: record.restoredAt == nil ? "clock.arrow.circlepath" : "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                Text(record.title).font(.headline).lineLimit(2)
                                Spacer()
                                Text(record.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(record.after == nil ? "Recording changes…" : "\(record.changedPaths.count) changed files · \(record.before.count) protected files")
                                Spacer()
                                Button(record.restoredAt == nil ? "Restore…" : "Restored") { pendingRestore = record }
                                    .disabled(restoring || record.after == nil || record.changedPaths.isEmpty || record.restoredAt != nil)
                            }.font(.caption)
                            if !record.skipped.isEmpty {
                                Text("\(record.skipped.count) large, unreadable, or linked files excluded. Git-ignored files are not captured.").font(.caption).foregroundStyle(.secondary)
                            }
                            if !record.changedPaths.isEmpty {
                                DisclosureGroup("Changed files") {
                                    ForEach(record.changedPaths, id: \.self) { path in
                                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                }.font(.caption)
                            }
                        }.padding(16).surface()
                    }
                    if (model.checkpointRecords[project.id] ?? []).isEmpty {
                        ContentUnavailableView("Your next turn is protected", systemImage: "clock.arrow.circlepath", description: Text("Checkpoints appear when an agent starts work. Unsaved editor drafts remain separate."))
                    }
                }
            }
        }
    }
    private var debugging: some View {
        VStack(alignment: .leading, spacing: 14) {
            commandField
            if let error = model.debugErrors[project.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.deletion).font(.caption).textSelection(.enabled)
            }
            if let debugRun {
                HStack(alignment: .top, spacing: 14) {
                    debugHistory.frame(width: 230)
                    debugDetails(debugRun)
                }
            } else {
                ContentUnavailableView("No debug runs", systemImage: "terminal",
                    description: Text("Run a reproduction command to review its output."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var commandField: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Reproduction command").font(.system(size: 13, weight: .semibold))
                Spacer()
                if debugTask != nil {
                    Label("Running", systemImage: "clock").font(.caption).foregroundStyle(Theme.action)
                }
            }
            HStack(spacing: 10) {
                TextField("e.g. go test ./…", text: $command).textFieldStyle(.workspace)
                    .accessibilityLabel("Reproduction command").font(Theme.code)
                if let debugTask {
                    Button("Stop", systemImage: "stop.fill") { debugTask.cancel() }
                        .buttonStyle(WorkspaceButtonStyle(kind: .destructive, compact: true))
                } else {
                    Button("Run", systemImage: "play.fill") {
                        model.debugCommands[project.id] = command
                        runDebug(command)
                    }.buttonStyle(WorkspaceButtonStyle(kind: .primary, compact: true))
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack {
                Label(current.editorURL.path, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(current.editorURL.path)
                Spacer()
                Text("2 minute timeout").fixedSize()
            }.font(.caption).foregroundStyle(.secondary)
        }.workspaceCard(padding: 13)
    }

    private var debugHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent runs").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(history.reversed()) { run in
                        let status = debugStatus(run)
                        WorkspaceRunRow(title: run.command,
                                        subtitle: status.title + " · " + run.date.formatted(date: .omitted, time: .shortened),
                                        symbol: status.symbol, tint: status.tint, selected: run.id == debugRun?.id) {
                            selectedDebugRun = run.id
                        }
                        #if DEBUG
                        .background(DebugViewMarker(name: "debug-saved-run-" + run.id.uuidString))
                        #endif
                    }
                }
            }
        }.frame(maxHeight: .infinity, alignment: .top).workspaceCard(padding: 10)
    }

    private func debugDetails(_ run: DebugRun) -> some View {
        let status = debugStatus(run)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.command).font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .lineLimit(2).textSelection(.enabled)
                    Text(run.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                WorkspaceStatusBadge(title: status.title, symbol: status.symbol, tint: status.tint)
            }
            HStack(spacing: 8) {
                Button("Run again", systemImage: "arrow.clockwise") { runDebug(run.command) }
                    .disabled(debugTask != nil)
                Button("Debug with agent", systemImage: "sparkles") { model.debugWithAgent(run, project: current) }
                    .disabled(model.workspace.conversation(for: project.id).map { model.controllers[$0.id]?.isBusy == true } ?? true)
            }.buttonStyle(WorkspaceButtonStyle(compact: true))
            WorkspaceRunOutput(output: run.output).id(run.id)
                #if DEBUG
                .background(DebugViewMarker(name: "debug-output-" + run.id.uuidString))
                #endif
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).workspaceCard(padding: 13)
    }

    private func runDebug(_ value: String) {
        selectedDebugRun = nil
        model.runDebug(value, project: current)
    }

    private func debugStatus(_ run: DebugRun) -> (title: String, symbol: String, tint: Color) {
        if run.timedOut { return ("Timed out", "clock.badge.exclamationmark", Theme.attention) }
        if run.exitCode == 0 { return ("Exit 0", "checkmark.circle.fill", Theme.addition) }
        return ("Exit \(run.exitCode)", "xmark.circle.fill", Theme.deletion)
    }
}
