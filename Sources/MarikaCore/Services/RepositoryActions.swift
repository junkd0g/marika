import Foundation

public struct ReviewChange: Identifiable, Sendable {
    public var path: String
    public var staged: Bool
    public var untracked: Bool
    public var id: String { (staged ? "staged/" : "working/") + path }
}
public struct ReviewPatch: Sendable {
    public var change: ReviewChange
    public var text: String
    public var display: DiffFile
    public var hunks: [String]
    public var header: String
}
public struct RepositoryCommit: Identifiable, Sendable {
    public var id: String
    public var author: String
    public var date: String
    public var subject: String
}
public struct MergeVersions: Sendable {
    public var base: String
    public var current: String
    public var incoming: String
    public var working: TextFileSnapshot
}

public actor RepositoryActions {
    private var root: URL
    private var locatedRoot = false
    private let environment: [String: String]
    private let runtime: WorkspaceRuntime?
    public init(root: URL, environment: [String: String], runtime: WorkspaceRuntime? = nil) { self.root = root; self.environment = environment; self.runtime = runtime }
    private var files: any WorkspaceFiles { runtime?.kind == .ssh ? RemoteFiles(runtime: runtime!, cache: root, environment: environment) : ProjectFiles(root: root) }
    private func rawGit(_ arguments: [String], timeout: Double = 90) async throws -> CommandResult {
        try await ToolContext(root: root, environment: environment, runtime: runtime).run("git", arguments: arguments, timeout: timeout)
    }

    private func git(_ args: [String], checked: Bool = true) async throws -> CommandResult {
        if !locatedRoot, runtime == nil {
            let location = try await Command.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", root.path, "rev-parse", "--show-toplevel"], environment: environment)
            guard location.succeeded else { throw AgentError.launchFailed("Open a project inside a Git repository to review changes.") }
            root = URL(fileURLWithPath: location.output.trimmingCharacters(in: .whitespacesAndNewlines))
            locatedRoot = true
        }
        let result = try await rawGit(["--no-pager", "--literal-pathspecs", "-C", runtime?.directory ?? root.path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + args)
        if checked && !result.succeeded { throw AgentError.launchFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput) }
        return result
    }
    public func changes() async throws -> [ReviewChange] {
        let staged = try await git(["diff", "--cached", "--no-renames", "--name-only", "-z"])
        let working = try await git(["diff", "--no-renames", "--name-only", "-z"])
        let untracked = try await git(["ls-files", "--others", "--exclude-standard", "-z"])
        return staged.output.split(separator: "\0").map { ReviewChange(path: String($0), staged: true, untracked: false) } +
            working.output.split(separator: "\0").map { ReviewChange(path: String($0), staged: false, untracked: false) } +
            untracked.output.split(separator: "\0").map { ReviewChange(path: String($0), staged: false, untracked: true) }
    }
    public func patch(_ change: ReviewChange) async throws -> ReviewPatch {
        if change.untracked {
            let fingerprint = try await git(["hash-object", "--no-filters", "--", change.path]).output
            let content = try? await files.read(change.path)
            let display = content.map { DiffFile(path: change.path, newContent: $0.text) } ?? DiffFile(path: change.path, isBinary: true)
            return ReviewPatch(change: change, text: fingerprint, display: display, hunks: [], header: "")
        }
        let result = try await git(["diff"] + (change.staged ? ["--cached"] : []) + ["--binary", "--no-renames", "--no-color", "--no-ext-diff", "--no-textconv", "--", change.path])
        guard result.stdout.count < 20_000_000 else { throw AgentError.launchFailed("This diff is too large. Review it in a terminal.") }
        var header = "", hunks: [String] = []
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            if line.hasPrefix("@@ ") { hunks.append(String(line) + "\n") }
            else if !hunks.isEmpty { hunks[hunks.count - 1] += line + "\n" }
            else { header += line + "\n" }
        }
        let display = DiffParser.parse(result.output, defaultPath: change.path).first ?? DiffFile(path: change.path)
        return ReviewPatch(change: change, text: result.output, display: display, hunks: hunks, header: header)
    }
    public enum Edit: Sendable { case stage, unstage, revert }
    public func edit(_ edit: Edit, patch expected: ReviewPatch, hunk: Int? = nil) async throws {
        let current = try await patch(expected.change)
        guard current.text == expected.text else { throw AgentError.launchFailed("The file changed since this diff was opened. Refresh it before applying the action.") }
        if expected.change.untracked {
            guard hunk == nil, edit == .stage else { throw AgentError.launchFailed("Stage this new file as a whole.") }
            _ = try await git(["add", "--", expected.change.path])
            return
        }
        if edit == .stage && expected.change.staged || edit == .unstage && !expected.change.staged || edit == .revert && expected.change.staged {
            throw AgentError.launchFailed("Choose an action for the displayed staged or working changes.")
        }
        if edit == .stage && hunk == nil {
            _ = try await git(["add", "--", expected.change.path])
            return
        }
        let data: Data
        if let hunk {
            guard current.hunks.indices.contains(hunk), !current.display.isBinary else { throw AgentError.launchFailed("This hunk is unavailable.") }
            // A partial patch cannot change whole-file metadata such as mode or rename state.
            let header = current.header.split(separator: "\n").filter { $0.hasPrefix("diff --git") || $0.hasPrefix("--- ") || $0.hasPrefix("+++ ") }.joined(separator: "\n") + "\n"
            data = Data((header + current.hunks[hunk]).utf8)
        } else { data = Data(current.text.utf8) }
        guard !data.isEmpty else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("marika-review-\(UUID()).patch")
        try data.write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }
        var args = ["apply", "--binary", "--whitespace=nowarn"]
        if edit == .stage || edit == .unstage { args += ["--cached"] }
        if edit == .unstage || edit == .revert { args += ["--reverse"] }
        _ = try await git(args + ["--check", temp.path])
        _ = try await git(args + [temp.path])
    }
    public func commit(_ message: String) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.launchFailed("Enter a commit message.") }
        // Preserve configured commit hooks, signing and author identity for user commits.
        let result = try await rawGit(["-C", runtime?.directory ?? root.path, "commit", "-m", message], timeout: 120)
        guard result.succeeded else { throw AgentError.launchFailed(result.errorOutput + result.output) }
        return result.output
    }
    public func push() async throws -> String {
        let branch = try await git(["branch", "--show-current"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw AgentError.launchFailed("Check out a branch before pushing.") }
        let result = try await rawGit(["-C", runtime?.directory ?? root.path, "push", "--set-upstream", "origin", branch], timeout: 120)
        guard result.succeeded else { throw AgentError.launchFailed(result.errorOutput + result.output) }
        return result.output + result.errorOutput
    }
    public func createPR(title: String, body: String) async throws -> String {
        guard runtime == nil else { throw AgentError.launchFailed("Create remote pull requests with gh in the remote terminal.") }
        guard let gh = ShellEnvironment.locate("gh", in: environment) else { throw AgentError.launchFailed("Install GitHub CLI and sign in with gh auth login.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.launchFailed("Enter a pull request title.") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("marika-pr-\(UUID()).txt")
        try body.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        let result = try await Command.run(gh, ["pr", "create", "--title", title, "--body-file", temp.path], workingDirectory: root, environment: environment, timeout: 120)
        guard result.succeeded else { throw AgentError.launchFailed(result.errorOutput + result.output) }
        return result.output
    }
    public func history(path: String? = nil) async throws -> [RepositoryCommit] {
        let result = try await git(["log", "-60", "--date=short", "--format=%H%x1f%an%x1f%ad%x1f%s%x1e"] + (path.map { ["--", $0] } ?? []))
        return result.output.components(separatedBy: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard fields.count == 4 else { return nil }
            return RepositoryCommit(id: fields[0], author: fields[1], date: fields[2], subject: fields[3])
        }
    }
    public func commitDiff(_ id: String) async throws -> String {
        guard id.count == 40, id.allSatisfy(\.isHexDigit) else { throw AgentError.launchFailed("Invalid commit ID.") }
        return try await git(["show", "--no-ext-diff", "--no-textconv", "--format=fuller", "--stat", "-p", id]).output
    }
    public func branches() async throws -> [String] { try await git(["branch", "--format=%(refname:short)"]).output.components(separatedBy: "\n").filter { !$0.isEmpty } }
    public func graph() async throws -> String { try await git(["log", "--graph", "--oneline", "--decorate", "-50"]).output }
    public func checkout(_ branch: String, create: Bool = false) async throws {
        guard !branch.hasPrefix("-"), !branch.isEmpty else { throw AgentError.launchFailed("Enter a valid branch name.") }
        _ = try await git(["switch"] + (create ? ["-c"] : []) + [branch])
    }
    public func stashes() async throws -> [String] { try await git(["stash", "list"]).output.components(separatedBy: "\n").filter { !$0.isEmpty } }
    public func stash() async throws { _ = try await git(["stash", "push", "-u", "-m", "Marika workspace changes"]) }
    public func applyStash(_ index: Int) async throws { guard index >= 0 else { return }; _ = try await git(["stash", "apply", "stash@{\(index)}"]) }
    public func blame(_ path: String) async throws -> String { try await git(["blame", "--date=short", "--", path]).output }
    public func conflictPaths() async throws -> [String] { try await git(["diff", "--name-only", "--diff-filter=U", "-z"]).output.split(separator: "\0").map(String.init) }
    public func conflict(_ path: String) async throws -> MergeVersions {
        guard try await conflictPaths().contains(path) else { throw AgentError.launchFailed("This file has no unresolved merge conflict.") }
        let base = try await git(["show", ":1:" + path], checked: false).output
        let current = try await git(["show", ":2:" + path], checked: false).output
        let incoming = try await git(["show", ":3:" + path], checked: false).output
        let working = try await files.read(path)
        return MergeVersions(base: base, current: current, incoming: incoming, working: working)
    }
    public func resolve(_ versions: MergeVersions, text: String) async throws {
        guard !text.contains("<<<<<<< "), !text.contains("\n=======\n"), !text.contains("\n>>>>>>> ") else { throw AgentError.launchFailed("Remove conflict markers before marking this file resolved.") }
        _ = try await files.write(text, replacing: versions.working, overwrite: false)
        _ = try await git(["add", "--", versions.working.path])
    }
}
