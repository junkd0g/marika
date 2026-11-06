import Foundation

/// Turns a raw tool call into something a person can scan.
enum ToolDescriber {
    struct Description {
        var kind: ToolKind
        var title: String
        var detail: String
    }

    static func describe(name: String, input: JSONValue, workingDirectory: String) -> Description {
        func path(_ key: String = "file_path") -> String {
            relative(input[key]?.string ?? "", to: workingDirectory)
        }
        switch name {
        case "Bash":
            return Description(kind: .shell, title: "Run", detail: firstLine(input["command"]?.string ?? ""))
        case "BashOutput", "TaskOutput":
            return Description(kind: .shell, title: "Check output", detail: input["bash_id"]?.string ?? "")
        case "KillShell", "KillBash", "TaskStop":
            return Description(kind: .shell, title: "Stop process", detail: input["shell_id"]?.string ?? "")
        case "Read":
            return Description(kind: .read, title: "Read", detail: path())
        case "Write":
            return Description(kind: .write, title: "Write", detail: path())
        case "Edit", "MultiEdit":
            return Description(kind: .edit, title: "Edit", detail: path())
        case "NotebookEdit":
            return Description(kind: .edit, title: "Edit", detail: path("notebook_path"))
        case "Glob":
            return Description(kind: .search, title: "Find files", detail: input["pattern"]?.string ?? "")
        case "Grep":
            return Description(kind: .search, title: "Search", detail: input["pattern"]?.string ?? "")
        case "ToolSearch":
            return Description(kind: .search, title: "Load tools", detail: input["query"]?.string ?? "")
        case "WebFetch":
            return Description(kind: .web, title: "Fetch", detail: input["url"]?.string ?? "")
        case "WebSearch":
            return Description(kind: .web, title: "Web search", detail: input["query"]?.string ?? "")
        case "Task", "Agent":
            return Description(kind: .subagent, title: "Agent", detail: input["description"]?.string ?? "")
        case "TodoWrite":
            return Description(kind: .todo, title: "Update plan", detail: "")
        case "TaskCreate":
            return Description(kind: .todo, title: "Add task", detail: input["subject"]?.string ?? "")
        case "TaskUpdate":
            return Description(kind: .todo, title: "Update task", detail: input["status"]?.string ?? "")
        case "TaskList", "TaskGet":
            return Description(kind: .todo, title: "Check tasks", detail: "")
        case "Skill":
            return Description(kind: .skill, title: "Skill", detail: input["skill"]?.string ?? "")
        case "AskUserQuestion":
            return Description(kind: .question, title: "Asked", detail: input["questions"]?[0]?["question"]?.string ?? "")
        case "ExitPlanMode":
            return Description(kind: .plan, title: "Proposed a plan", detail: "")
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                return Description(
                    kind: .mcp, title: parts.first ?? name,
                    detail: parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " "))
            }
            return Description(kind: .other, title: name, detail: summary(of: input))
        }
    }

    /// What an edit will do, for showing before it is approved.
    static func previewDiff(name: String, input: JSONValue, workingDirectory: String) -> [DiffFile] {
        let path = relative(input["file_path"]?.string ?? "", to: workingDirectory)
        switch name {
        case "Write":
            return [DiffFile(path: path, newContent: input["content"]?.string ?? "")]
        case "Edit":
            return [
                DiffFile(
                    path: path, replacing: input["old_string"]?.string ?? "", with: input["new_string"]?.string ?? "")
            ]
        case "MultiEdit":
            let lines = (input["edits"]?.array ?? []).flatMap { edit in
                DiffFile(
                    path: path, replacing: edit["old_string"]?.string ?? "", with: edit["new_string"]?.string ?? ""
                ).lines
            }
            return [DiffFile(path: path, lines: lines)]
        default:
            return []
        }
    }

    /// Shortens a path inside the project. Agents report resolved paths, and on macOS a project
    /// under /tmp or /var really lives in /private, so both spellings are checked.
    static func relative(_ path: String, to base: String) -> String {
        guard !base.isEmpty else { return path }
        for root in [base, FilePath.resolved(base)] {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix), path.count > prefix.count {
                return String(path.dropFirst(prefix.count))
            }
        }
        let home = NSHomeDirectory() + "/"
        return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func summary(of input: JSONValue) -> String {
        guard let object = input.object else { return "" }
        for key in ["description", "prompt", "query", "command", "path", "name", "url"] {
            if let value = object[key]?.string, !value.isEmpty { return firstLine(value) }
        }
        return object.values.compactMap(\.string).first.map(firstLine) ?? ""
    }
}
