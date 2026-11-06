import MarikaCore
import SwiftUI

/// What the agent has changed in the project, straight from git.
struct ChangesInspector: View {
    @Environment(AppModel.self) private var model
    let session: SessionController
    let project: Project

    @State private var snapshot = GitSnapshot()
    @State private var selection: GitChange.ID?
    @State private var diff: DiffFile?
    @State private var isLoaded = false
    @State private var isRefreshing = false
    @State private var isLoadingDiff = false
    @State private var refreshRevision = 0
    @State private var diffRevision = 0

    private var git: Git { Git(environment: model.gitEnvironment) }

    /// Edits this session made, for folders that aren't git repositories.
    private var sessionEdits: [DiffFile] {
        var byPath: [String: DiffFile] = [:]
        var order: [String] = []
        for call in session.items.compactMap(\.tool) where call.status == .succeeded {
            for file in call.diff {
                if byPath[file.path] == nil {
                    order.append(file.path)
                    byPath[file.path] = file
                } else {
                    byPath[file.path]?.lines += [DiffLine(kind: .hunk, text: "⋯")] + file.lines
                }
            }
        }
        return order.compactMap { byPath[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !isLoaded {
                ProgressView("Loading changes…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot.isRepository {
                repositoryContent
            } else {
                folderContent
            }
        }
        .task(id: session.changeCount) { await refresh() }
        .task(id: selection) { await loadDiff() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Review") { model.switchPanel(.changes) }.buttonStyle(.link)
                Text("Changes")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh changes")
                    .accessibilityLabel("Refresh changes")
                }
            }
            HStack(spacing: 6) {
                Label(snapshot.branch ?? project.name, systemImage: snapshot.isRepository ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if snapshot.additions + snapshot.deletions > 0 {
                    DiffStat(additions: snapshot.additions, deletions: snapshot.deletions)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var repositoryContent: some View {
        if let error = snapshot.error {
            placeholder("Couldn't load changes", detail: error)
        } else if snapshot.changes.isEmpty {
            placeholder("No changes", detail: "The working tree matches the last commit.")
        } else {
            List(snapshot.changes, selection: $selection) { change in
                ChangeRow(change: change).tag(change.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: selection == nil ? nil : min(CGFloat(snapshot.changes.count) * 28 + 10, 200))

            if isLoadingDiff {
                Divider()
                ProgressView("Loading diff…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff {
                Divider()
                ScrollView {
                    DiffView(file: diff, showsHeader: false, initialLimit: 800)
                        .padding(10)
                }
            }
        }
    }

    @ViewBuilder
    private var folderContent: some View {
        let edits = sessionEdits
        if edits.isEmpty {
            placeholder(
                "No session edits yet",
                detail: "File changes made by your agent will appear here. This folder isn't using git.")
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(edits) { DiffView(file: $0) }
                }
                .padding(10)
            }
        }
    }

    private func placeholder(_ title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: snapshot.isRepository ? "checkmark.circle" : "doc.text")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() async {
        refreshRevision += 1
        let revision = refreshRevision
        isRefreshing = true
        defer { if revision == refreshRevision { isRefreshing = false } }
        let updated = await git.snapshot(at: project.url)
        guard !Task.isCancelled, revision == refreshRevision else { return }
        snapshot = updated
        isLoaded = true
        if !snapshot.changes.contains(where: { $0.id == selection }) {
            selection = snapshot.changes.first?.id
        }
        await loadDiff()
    }

    private func loadDiff() async {
        diffRevision += 1
        let revision = diffRevision
        defer { if revision == diffRevision { isLoadingDiff = false } }
        guard let change = snapshot.changes.first(where: { $0.id == selection }) else {
            diff = nil
            return
        }
        isLoadingDiff = true
        diff = nil
        let updated = await git.diff(for: change, at: project.url)
        // A slower read of the previous file must never replace the current selection.
        guard !Task.isCancelled, revision == diffRevision, selection == change.id else { return }
        diff = updated
    }
}

private struct ChangeRow: View {
    let change: GitChange

    private var color: Color {
        switch change.status {
        case .added, .untracked: Theme.addition
        case .deleted, .conflicted: Theme.deletion
        default: Theme.attention
        }
    }

    private var fileName: String { (change.path as NSString).lastPathComponent }
    private var directory: String { (change.path as NSString).deletingLastPathComponent }

    var body: some View {
        HStack(spacing: 7) {
            Text(change.status.letter)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(fileName)
                .font(.system(size: 12))
                .lineLimit(1)
            if !directory.isEmpty {
                Text(directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            DiffStat(additions: change.additions, deletions: change.deletions)
        }
    }
}
