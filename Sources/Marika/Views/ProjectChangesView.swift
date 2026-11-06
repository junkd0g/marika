import SwiftUI
import MarikaCore

struct ProjectChangesView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var repository: RepositoryActions?
    @State private var changes: [ReviewChange] = []
    @State private var selected: String?
    @State private var patch: ReviewPatch?
    @State private var error: String?
    @State private var busy = false
    @State private var didFail = false
    @State private var pullRequestURL: URL?
    @State private var commitMessage = ""
    @State private var comment = ""
    @State private var commentLine: Int?
    @State private var revertHunk: Int?
    @State private var confirmRevert = false
    @State private var confirmPush = false
    @State private var showPR = false
    @State private var prBody = ""
    @State private var prTitle = ""
    @State private var showsHistory = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes").font(.title2.bold())
                Text(project.editorURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("History & branches") { showsHistory = true }
                Button("Refresh") { Task { await refresh() } }
                Button("Terminal") { model.openTerminal() }
            }.padding(16)
            if let error { Text(error).font(.caption).foregroundStyle(didFail ? .red : .secondary).textSelection(.enabled).padding(.horizontal) }
            if let pullRequestURL { Link("Open pull request", destination: pullRequestURL).padding(.horizontal) }
            HStack(alignment: .top, spacing: 0) {
                List(changes, selection: $selected) { change in
                    VStack(alignment: .leading) {
                        Text(change.path).lineLimit(1).truncationMode(.middle)
                        Text(change.staged ? "Staged" : change.untracked ? "New file" : "Working changes").font(.caption).foregroundStyle(.secondary)
                    }.tag(change.id)
                }.frame(minWidth: 140, idealWidth: 210, maxWidth: 250)
                Divider()
                if let patch {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(patch.change.path).font(.headline).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(patch.change.staged ? "Unstage file" : "Stage file") { Task { await edit(patch.change.staged ? .unstage : .stage) } }
                            if !patch.change.staged && !patch.change.untracked {
                                Button("Revert…", role: .destructive) { revertHunk = nil; confirmRevert = true }
                            }
                        }
                        GeometryReader { geometry in
                        ScrollView([.vertical, .horizontal]) {
                            VStack(alignment: .leading, spacing: 12) {
                                if patch.hunks.isEmpty {
                                    if patch.display.isBinary { Text("Binary file").foregroundStyle(.secondary) }
                                    else { diffLines(patch.display) }
                                }
                                else {
                                    ForEach(Array(patch.hunks.enumerated()), id: \.offset) { index, hunk in
                                        HStack {
                                            Text(hunk.components(separatedBy: "\n").first ?? "Changed lines").font(.caption.monospaced()).foregroundStyle(.secondary)
                                            Button(patch.change.staged ? "Unstage" : "Stage") { Task { await edit(patch.change.staged ? .unstage : .stage, hunk: index) } }.controlSize(.small)
                                            #if DEBUG
                                                .background(DebugViewMarker(name: "git-hunk-stage-" + String(index)))
                                            #endif
                                            if !patch.change.staged {
                                                Button("Revert…", role: .destructive) { revertHunk = index; confirmRevert = true }.controlSize(.small)
                                            }
                                        }
                                        let file = DiffParser.parse(patch.header + hunk, defaultPath: patch.change.path).first ?? patch.display
                                        diffLines(file)
                                    }
                                }
                            }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                        }
                        }
                        if let line = commentLine, line > 0 {
                            HStack {
                                TextField("Feedback on line \(line)", text: $comment)
                                Button("Add to chat") { addComment(line: line, path: patch.change.path) }.disabled(comment.isEmpty)
                            }
                        } else { Text("Click a line number to leave feedback.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(12)
                } else { ContentUnavailableView("Select a change", systemImage: "arrow.triangle.branch") }
            }
            Divider()
            HStack {
                TextField("Commit message", text: $commitMessage)
                Button("Commit staged") { Task { if await perform({ try await repository?.commit(commitMessage) }) { commitMessage = "" } } }
                    .disabled(commitMessage.isEmpty || !changes.contains(where: \.staged))
                Button("Push…") { confirmPush = true }
                Button("Create PR…") { showPR = true }
            }.padding(12)
        }.disabled(busy)
        .task(id: project.editorURL) { selected = nil; patch = nil; repository = RepositoryActions(root: project.editorURL, environment: model.gitEnvironment, runtime: project.runtime); await refresh() }
        .task(id: selected) { await load() }
        .confirmationDialog("Revert the displayed changes?", isPresented: $confirmRevert) {
            Button("Revert", role: .destructive) {
                let hunk = revertHunk
                Task { await edit(.revert, hunk: hunk); commentLine = nil }
            }
        }
        .confirmationDialog("Push this branch to origin?", isPresented: $confirmPush) {
            Button("Push branch") { Task { await perform { try await repository?.push() } } }
        }
        .sheet(isPresented: $showPR) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Create pull request").font(.title2)
                TextField("Title", text: $prTitle)
                TextEditor(text: $prBody).frame(height: 180)
                HStack {
                    Button("Cancel") { showPR = false }
                    Spacer()
                    Button("Create pull request") { showPR = false; Task { await perform { try await repository?.createPR(title: prTitle, body: prBody) } } }.disabled(prTitle.isEmpty)
                }
            }.padding(20).frame(width: 550)
        }
        .sheet(isPresented: $showsHistory) { RepositoryHistoryView(project: project).environment(model) }
    }
    private func diffLines(_ file: DiffFile) -> some View {
        ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
            HStack(alignment: .top, spacing: 8) {
                if let number = line.newNumber ?? line.oldNumber {
                    Button(String(number)) { commentLine = number }.buttonStyle(.plain)
                        .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ").frame(width: 10)
                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
            }.font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                .background(line.kind == .addition ? Color.green.opacity(0.12) : line.kind == .deletion ? Color.red.opacity(0.12) : .clear)
        }
    }

    private func addComment(line: Int, path: String) {
        guard let meta = model.selectedSession, let controller = model.controllers[meta.id] else { return }
        controller.draft += (controller.draft.isEmpty ? "" : "\n\n") + "Review feedback for \(path):\(line)\n\(comment)"
        comment = ""
        model.switchPanel(.conversation)
        model.setSplit(.changes)
        model.openAgentChat(meta.id)
    }
    private func refresh() async {
        do {
            changes = try await repository?.changes() ?? []
            if !changes.contains(where: { $0.id == selected }) { selected = changes.first?.id }
            await load()
        } catch { self.error = error.localizedDescription }
    }
    private func load() async {
        guard let change = changes.first(where: { $0.id == selected }) else { patch = nil; return }
        patch = nil
        commentLine = nil
        do {
            let value = try await repository?.patch(change)
            if selected == change.id { patch = value }
        } catch { self.error = error.localizedDescription }
    }
    private func edit(_ operation: RepositoryActions.Edit, hunk: Int? = nil) async {
        guard let patch else { return }
        await perform { try await repository?.edit(operation, patch: patch, hunk: hunk); return "" }
        if operation == .revert { await model.editors[project.id]?.refresh() }
    }
    @discardableResult
    private func perform(_ operation: () async throws -> String?) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            error = try await operation(); didFail = false
            if let message = error?.trimmingCharacters(in: .whitespacesAndNewlines), message.hasPrefix("https://") { pullRequestURL = URL(string: message) }
            await refresh(); return true
        }
        catch { self.error = error.localizedDescription; didFail = true; return false }
    }
}
