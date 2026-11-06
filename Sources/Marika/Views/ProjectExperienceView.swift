import MarikaCore
import SwiftUI

struct ProjectExperienceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var section = "Recovery"
    @State private var command = ""
    @State private var error: String?
    @State private var restoring = false
    @State private var pendingRestore: CodeCheckpoint?
    private var current: Project { model.project(id: project.id) ?? project }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section == "Recovery" ? "A way back" : section == "Debug" ? "Understand the failure" : "Review the work").font(.title2.bold())
                    Text(project.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Workspace tools", selection: $section) {
                Text("Checkpoints").tag("Recovery")
                Text("Runtime debugging").tag("Debug")
                Text("Artifacts").tag("Artifacts")
            }.pickerStyle(.segmented)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if section == "Recovery" { recovery } else if section == "Debug" { debugging } else { ProjectArtifactsView(project: project).environment(model) }
        }.font(.system(size: 12)).controlSize(.small).padding(20).frame(width: 880, height: 620)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Run a reproduction, inspect the evidence, and ask an agent to fix and verify it.").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Reproduction command, e.g. go test ./...", text: $command).textFieldStyle(.roundedBorder)
                if model.debugTasks[project.id] != nil {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.debugTasks[project.id]?.cancel() }
                } else {
                    Button("Run") { model.debugCommands[project.id] = command; model.runDebug(command, project: current) }
                        .buttonStyle(.borderedProminent).disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("\(current.editorURL.path) · Stops after 2 minutes").font(.caption).foregroundStyle(.secondary)
            if let error = model.debugErrors[project.id] { Text(error).foregroundStyle(.red).font(.caption) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach((current.debugRuns ?? []).reversed()) { run in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: run.exitCode == 0 && !run.timedOut ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(run.exitCode == 0 && !run.timedOut ? .green : .orange)
                                Text(run.command).font(.headline.monospaced()).lineLimit(2)
                                Spacer()
                                Text(run.timedOut ? "Timed out" : "Exit \(run.exitCode)").font(.caption)
                            }
                            Text(run.output.isEmpty ? "No output" : run.output).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button("Debug with agent") { model.debugWithAgent(run, project: current) }
                                    .disabled(model.workspace.conversation(for: project.id).map { model.controllers[$0.id]?.isBusy == true } ?? true)
                                Button("Run again") { model.runDebug(run.command, project: current) }.disabled(model.debugTasks[project.id] != nil)
                                Spacer()
                                Text(run.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(16).surface()
                    }
                }
            }
        }
    }
}
