import Foundation

/// An explicitly marked shell example in an assistant reply. Parsing never executes it.
public struct ChatTerminalCommand: Equatable, Sendable {
    public enum Shell: String, Sendable {
        case sh, bash, zsh
        public var executable: URL { URL(fileURLWithPath: "/bin/" + rawValue) }
    }

    public let script: String
    public let shell: Shell
    public var title: String { String((script.split(separator: "\n").first.map(String.init) ?? "Chat command").prefix(48)) }

    public init?(language: String, text: String) {
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shell: Shell
        switch language {
        case "sh": shell = .sh
        case "bash": shell = .bash
        case "zsh", "shell", "shellscript": shell = .zsh
        case "", "console", "terminal", "shell-session", "sh-session": shell = .zsh
        default: return nil
        }
        var script = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        guard script.utf8.count <= 32_000,
              !script.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9 && $0.value != 10) || (127...159).contains($0.value) }) else { return nil }
        let lines = script.components(separatedBy: "\n")
        let significant = lines.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        guard let first = significant.first else { return nil }
        if first.hasPrefix("$ ") {
            // Console transcripts containing output are not executable command blocks.
            guard significant.allSatisfy({ $0.hasPrefix("$ ") }) else { return nil }
            script = lines.map { $0.hasPrefix("$ ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
        } else if ["", "console", "terminal", "shell-session", "sh-session"].contains(language) { return nil }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.script = script
        self.shell = shell
    }

    public struct Invocation: Sendable {
        public let executable: URL
        public let arguments: [String]
        public let directory: URL
    }

    /// Bind a click to its originating chat, including worktree or remote-runtime context.
    public func invocation(project: Project, session: SessionMeta, environment: [String: String]) throws -> Invocation {
        guard session.projectID == project.id else { throw AgentError.launchFailed("This command belongs to another project.") }
        guard session.agentTask?.workspace?.status != .discarded else {
            throw AgentError.launchFailed("This agent's workspace was discarded. Open a current chat to run commands.")
        }
        if let runtime = project.runtime {
            let command = shell.executable.path + " -lc " + WorkspaceRuntime.quote(script)
            let (executable, arguments) = try runtime.invocation(command, environment: environment)
            return Invocation(executable: executable, arguments: arguments, directory: project.url)
        }
        let directory = session.agentTask?.workspace.map { URL(fileURLWithPath: $0.workingPath) } ?? project.url
        return Invocation(executable: shell.executable, arguments: ["-lc", script], directory: directory)
    }
}
