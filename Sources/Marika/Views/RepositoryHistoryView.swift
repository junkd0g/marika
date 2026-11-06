import MarikaCore
import SwiftUI

struct RepositoryHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var commits: [RepositoryCommit] = []
    @State private var branches: [String] = []
    @State private var stashes: [String] = []
    @State private var conflicts: [String] = []
    @State private var text = ""
    @State private var error = ""
    @State private var branch = ""
    @State private var merge: MergeVersions?
    @State private var result = ""
    @State private var busy = false
    @State private var pane = "History"
    @State private var filePath = ""
    private var repository: RepositoryActions { RepositoryActions(root: project.editorURL, environment: model.gitEnvironment, runtime: project.runtime) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Repository").font(.title2.bold()); Text(project.editorURL.lastPathComponent).foregroundStyle(.secondary); Spacer(); Button("Done") { dismiss() } }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Picker("View", selection: $pane) { Text("History").tag("History"); Text("Graph").tag("Graph"); Text("Blame").tag("Blame") }.pickerStyle(.segmented).frame(width: 250)
                TextField("File path (optional)", text: $filePath)
                Button("Load") { run { if pane == "Graph" { text = try await repository.graph() } else if pane == "Blame" { text = try await repository.blame(filePath) } else { commits = try await repository.history(path: filePath.isEmpty ? nil : filePath) } } }
            }.controlSize(.small)
            HStack {
                Menu("Switch branch") { ForEach(branches, id: \.self) { name in Button(name) { run { try await repository.checkout(name) } } } }
                TextField("New branch", text: $branch).frame(width: 170)
                Button("Create") { run { try await repository.checkout(branch, create: true) } }.disabled(branch.isEmpty)
                Button("Stash changes") { run { try await repository.stash() } }
                Menu("Apply stash") { ForEach(Array(stashes.enumerated()), id: \.offset) { index, title in Button(title) { run { try await repository.applyStash(index) } } } }
                Menu("Resolve conflicts") { ForEach(conflicts, id: \.self) { path in Button(path) { run { merge = try await repository.conflict(path); result = merge?.working.text ?? "" } } } }
            }.controlSize(.small)
            if let merge {
                HStack {
                    Text(merge.working.path).font(.headline)
                    Spacer()
                    Button("Use current") { result = merge.current }
                    Button("Use incoming") { result = merge.incoming }
                    Button("Mark resolved") { run { try await repository.resolve(merge, text: result); self.merge = nil } }.buttonStyle(.borderedProminent)
                }
                HSplitView {
                    ScrollView { Text(merge.current).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    ScrollView { Text(merge.incoming).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.frame(height: 180)
                Text("Result — edit the combined file below").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $result).font(.system(size: 12, design: .monospaced))
            } else if pane != "History" {
                ScrollView([.horizontal, .vertical]) { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            } else {
                HSplitView {
                    List(commits) { commit in
                        Button { run { text = try await repository.commitDiff(commit.id) } } label: {
                            VStack(alignment: .leading, spacing: 4) { Text(commit.subject).font(.system(size: 12, weight: .medium)); Text(commit.date + " · " + commit.author + " · " + commit.id.prefix(7)).font(.caption2).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                    }.frame(minWidth: 200, idealWidth: 280)
                    ScrollView([.horizontal, .vertical]) { Text(text.isEmpty ? "Select a commit to inspect its changes." : text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                }
            }
        }.padding(20).frame(width: 920, height: 640).disabled(busy).task { await refresh() }
    }
    private func refresh() async {
        do { commits = try await repository.history(path: filePath.isEmpty ? nil : filePath); branches = try await repository.branches(); stashes = try await repository.stashes(); conflicts = try await repository.conflictPaths() }
        catch { self.error = error.localizedDescription }
    }
    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await action(); await refresh(); for editor in model.repositoryEditors[project.id]?.values ?? [:].values { await editor.refresh() } } catch { self.error = error.localizedDescription } }
    }
}
