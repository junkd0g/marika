import Foundation
import Darwin

public struct AgentChangeReview: Sendable {
    public let patch: Data
    public let files: [DiffFile]
    public let hunks: [AgentReviewHunk]
    public let baseCommit: String
    public let projectRoot: String?
    public let projectFiles: [String: AgentReviewFileState]
    public var isEmpty: Bool { patch.isEmpty }
}

public struct AgentWorktreeError: LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Worktrees keep agent edits out of the user's working files until an explicit Apply.
public actor AgentWorktrees {
    private let directory: URL
    private let environment: [String: String]
    public init(directory: URL, environment: [String: String]) {
        var parent = directory.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            suffix.append(parent.lastPathComponent); parent.deleteLastPathComponent()
        }
        self.directory = suffix.reversed().reduce(parent.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        self.environment = environment
    }

    private func git(_ args: [String], at root: URL, overrides: [String: String] = [:]) async throws -> CommandResult {
        try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["--literal-pathspecs", "-c", "core.hooksPath=/dev/null", "-c", "core.quotepath=false", "-C", root.path] + args,
                              environment: environment.merging(overrides) { _, value in value }, timeout: 45)
    }
    private func checked(_ args: [String], at root: URL, overrides: [String: String] = [:]) async throws -> CommandResult {
        let result = try await git(args, at: root, overrides: overrides)
        guard result.succeeded else { throw AgentWorktreeError(message: result.errorOutput.isEmpty ? result.output : result.errorOutput) }
        return result
    }

    public func create(for project: URL, id: UUID) async throws -> AgentWorkspace? {
        let source = project.standardizedFileURL.resolvingSymlinksInPath()
        let top = try await git(["rev-parse", "--show-toplevel"], at: source)
        guard top.succeeded else { return nil }
        let root = URL(fileURLWithPath: top.output.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.resolvingSymlinksInPath()
        guard source.path == root.path || source.path.hasPrefix(root.path + "/") else { throw AgentWorktreeError(message: "Project is outside its Git repository.") }
        let head = try await git(["rev-parse", "--verify", "HEAD"], at: root)
        guard head.succeeded else { throw AgentWorktreeError(message: "Create the repository's first commit before launching an isolated agent.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(id.uuidString.lowercased())
        let branch = "marika/" + id.uuidString.lowercased()
        _ = try await checked(["worktree", "add", "-b", branch, target.path, "HEAD"], at: root)
        do {
            // Start from the user's current files, including uncommitted edits, without
            // making a commit or touching the index in their original checkout.
            let patch = try await checked(["diff", "--no-ext-diff", "--binary", "HEAD"], at: root)
            if !patch.stdout.isEmpty { try await applyPatch(patch.stdout, at: target, check: false) }
            let untracked = try await checked(["ls-files", "--others", "--exclude-standard", "-z"], at: root)
            let paths = untracked.output.split(separator: "\0").map(String.init)
            guard paths.count < 10_000 else { throw AgentWorktreeError(message: "Too many untracked files to snapshot. Add generated folders to .gitignore first.") }
            for path in paths {
                let from = root.appendingPathComponent(path)
                let resolved = from.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/") else { continue }
                let to = target.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: to.path) { try FileManager.default.copyItem(at: from, to: to) }
            }
            _ = try await checked(["add", "-A"], at: target)
            let dirty = try await checked(["status", "--porcelain"], at: target)
            if !dirty.output.isEmpty {
                _ = try await checked(["-c", "user.name=Marika", "-c", "user.email=agent@marika.local", "-c", "commit.gpgsign=false", "commit", "-m", "Marika project snapshot"], at: target)
            }
            let base = try await checked(["rev-parse", "HEAD"], at: target).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let relative = source.path == root.path ? "" : String(source.path.dropFirst(root.path.count + 1))
            return AgentWorkspace(rootPath: target.path, workingPath: target.appendingPathComponent(relative).path,
                                  branch: branch, baseCommit: base)
        } catch {
            _ = try? await git(["worktree", "remove", "--force", target.path], at: root)
            _ = try? await git(["branch", "-D", branch], at: root)
            throw error
        }
    }

    private func validate(_ workspace: AgentWorkspace) throws -> URL {
        let root = URL(fileURLWithPath: workspace.rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().path == directory.path,
              UUID(uuidString: root.lastPathComponent) != nil,
              workspace.branch == "marika/" + root.lastPathComponent else {
            throw AgentWorktreeError(message: "This worktree is not managed by Marika.")
        }
        return root
    }

    public func review(_ workspace: AgentWorkspace, project: URL? = nil) async throws -> AgentChangeReview {
        let lock = try reviewLock(workspace)
        defer { flock(lock, LOCK_UN); close(lock) }
        return try await snapshot(workspace, project: project)
    }

    private func snapshot(_ workspace: AgentWorkspace, project: URL?) async throws -> AgentChangeReview {
        guard workspace.status != .discarded else { throw AgentWorktreeError(message: "This worktree was discarded.") }
        let root = try validate(workspace)
        let base = try await reviewBase(workspace, at: root)
        _ = try await checked(["add", "-A"], at: root)
        let args = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--no-color", "--cached"]
        let result = try await checked(args + ["--binary", base, "--"], at: root)
        guard result.stdout.count < 20 * 1024 * 1024 else { throw AgentWorktreeError(message: "These changes are too large to review in the app. Open the worktree in Finder.") }
        let paths = try await checked(args + ["--name-only", "-z", base, "--"], at: root).output.split(separator: "\0").map(String.init)
        let hunks = try AgentReviewPatch.hunks(result.stdout, paths: paths)
        let projectRoot: URL?
        if let project { projectRoot = try await repositoryRoot(project) } else { projectRoot = nil }
        var states: [String: AgentReviewFileState] = [:]
        if let projectRoot { for path in paths { states[path] = try AgentReviewFileState.capture(path, root: projectRoot) } }
        let files: [DiffFile] = paths.compactMap { path -> DiffFile? in
            let parts = hunks.filter { $0.path == path }
            guard var file = parts.first?.display else { return nil }
            file.lines = parts.enumerated().flatMap { index, part in
                (index == 0 ? [] : [DiffLine(kind: .hunk, text: "⋯")]) + part.display.lines
            }
            return file
        }
        return AgentChangeReview(patch: result.stdout, files: files, hunks: hunks, baseCommit: base,
            projectRoot: projectRoot?.path, projectFiles: states)
    }

    @discardableResult
    public func apply(_ review: AgentChangeReview, workspace: AgentWorkspace, to project: URL) async throws -> String {
        let lock = try reviewLock(workspace)
        defer { flock(lock, LOCK_UN); close(lock) }
        let latest = try await snapshot(workspace, project: project)
        guard latest.patch == review.patch else { throw AgentWorktreeError(message: "The agent's files changed. Refresh the review before applying.") }
        guard !review.isEmpty else { throw AgentWorktreeError(message: "There are no changes to apply.") }
        let top = try await checked(["rev-parse", "--show-toplevel"], at: project)
        let root = URL(fileURLWithPath: top.output.trimmingCharacters(in: .whitespacesAndNewlines))
        try validateProjectFiles(review, at: root, paths: Array(review.projectFiles.keys))
        try await applyPatch(review.patch, at: root, check: true)
        let isolated = try validate(workspace)
        // Record the reviewed state in the agent's branch. The user's branch and
        // index are untouched; subsequent turns can be reviewed as a new delta.
        let status = try await checked(["status", "--porcelain"], at: isolated)
        if !status.output.isEmpty {
            _ = try await checked(["-c", "user.name=Marika", "-c", "user.email=agent@marika.local", "-c", "commit.gpgsign=false",
                                   "commit", "-m", "Reviewed agent changes"], at: isolated)
        }
        let base = try await checked(["rev-parse", "HEAD"], at: isolated).output.trimmingCharacters(in: .whitespacesAndNewlines)
        try await applyPatch(review.patch, at: root, check: false)
        _ = try await checked(["update-ref", reviewRef(workspace), base], at: isolated)
        return base
    }

    public enum Decision: Sendable { case accept, reject }

    public func decide(_ decision: Decision, hunkID: String, review: AgentChangeReview, workspace: AgentWorkspace, project: URL) async throws -> AgentChangeReview {
        let lock = try reviewLock(workspace)
        defer { flock(lock, LOCK_UN); close(lock) }
        let latest = try await snapshot(workspace, project: project)
        guard latest.patch == review.patch, latest.baseCommit == review.baseCommit,
              let hunk = latest.hunks.first(where: { $0.id == hunkID }) else {
            throw AgentWorktreeError(message: "The agent modified this proposal. Refresh before deciding on this hunk.")
        }
        let isolated = try validate(workspace)
        if decision == .reject {
            try await applyPatch(hunk.patch, at: isolated, check: true, reverse: true)
            try await applyPatch(hunk.patch, at: isolated, check: false, reverse: true)
        } else {
            let root = try await repositoryRoot(project)
            guard review.projectRoot == root.path else { throw AgentWorktreeError(message: "Refresh this review before applying a change.") }
            try validateProjectFiles(review, at: root, paths: [hunk.path])
            try await applyPatch(hunk.patch, at: root, check: true)
            let base = try await advancing(latest.baseCommit, with: hunk.patch, at: isolated)
            try validateProjectFiles(review, at: root, paths: [hunk.path])
            try await applyPatch(hunk.patch, at: root, check: false)
            _ = try await checked(["update-ref", reviewRef(workspace), base], at: isolated)
        }
        return try await snapshot(workspace, project: project)
    }

    private func repositoryRoot(_ project: URL) async throws -> URL {
        let top = try await checked(["rev-parse", "--show-toplevel"], at: project)
        return URL(fileURLWithPath: top.output.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func reviewRef(_ workspace: AgentWorkspace) -> String { "refs/marika/reviews/" + URL(fileURLWithPath: workspace.rootPath).lastPathComponent }
    private func reviewBase(_ workspace: AgentWorkspace, at root: URL) async throws -> String {
        let saved = try await git(["rev-parse", "--verify", reviewRef(workspace)], at: root)
        let base = saved.succeeded ? saved.output.trimmingCharacters(in: .whitespacesAndNewlines) : workspace.baseCommit
        guard [40, 64].contains(base.count), base.allSatisfy(\.isHexDigit) else { throw AgentWorktreeError(message: "Invalid review baseline.") }
        return base
    }

    private func reviewLock(_ workspace: AgentWorkspace) throws -> Int32 {
        _ = try validate(workspace)
        let path = directory.appendingPathComponent(".review-" + URL(fileURLWithPath: workspace.rootPath).lastPathComponent + ".lock").path
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AgentWorktreeError(message: "Couldn't open the review lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw AgentWorktreeError(message: "Another review action is in progress. Try again when it finishes.")
        }
        return descriptor
    }

    private func validateProjectFiles(_ review: AgentChangeReview, at root: URL, paths: [String]) throws {
        for path in paths {
            if let expected = review.projectFiles[path], try AgentReviewFileState.capture(path, root: root) != expected {
                throw AgentWorktreeError(message: "\(path) changed in your project. Refresh the review before accepting it.")
            }
        }
    }

    private func advancing(_ base: String, with patch: Data, at root: URL) async throws -> String {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("marika-review-index-\(UUID())")
        let file = index.appendingPathExtension("patch")
        defer { try? FileManager.default.removeItem(at: index); try? FileManager.default.removeItem(at: file) }
        let env = ["GIT_INDEX_FILE": index.path]
        _ = try await checked(["read-tree", base], at: root, overrides: env)
        try patch.write(to: file, options: .atomic)
        _ = try await checked(["apply", "--cached", "--binary", "--whitespace=nowarn", file.path], at: root, overrides: env)
        let tree = try await checked(["write-tree"], at: root, overrides: env).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await checked(["-c", "user.name=Marika", "-c", "user.email=agent@marika.local", "-c", "commit.gpgsign=false",
            "commit-tree", tree, "-p", base, "-m", "Accept reviewed agent change"], at: root).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyPatch(_ patch: Data, at root: URL, check: Bool, reverse: Bool = false) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("marika-\(UUID()).patch")
        try patch.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await git(["apply", "--binary", "--whitespace=nowarn"] + (check ? ["--check"] : []) + (reverse ? ["--reverse"] : []) + [file.path], at: root)
        guard result.succeeded else { throw AgentWorktreeError(message: "Changes could not be applied safely. Your project files were kept.\n" + result.errorOutput) }
    }

    public func discard(_ workspace: AgentWorkspace, project: URL) async throws {
        let lock = try reviewLock(workspace)
        defer { flock(lock, LOCK_UN); close(lock) }
        let root = try validate(workspace)
        _ = try await git(["update-ref", "-d", reviewRef(workspace)], at: root)
        _ = try await checked(["worktree", "remove", "--force", root.path], at: project)
        _ = try await checked(["branch", "-D", workspace.branch], at: project)
    }
}
