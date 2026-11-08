import Foundation
import Testing
@testable import MarikaCore

struct ChatTerminalCommandTests {
    @Test func shellExamplesKeepQuotesUnicodeAndMultilineSyntax() throws {
        let script = "printf '%s\\n' \"hello 🦊\"\ncat <<'EOF'\n$ this is heredoc text\nEOF"
        let bash = try #require(ChatTerminalCommand(language: " Bash ", text: script))
        #expect(bash.script == script && bash.shell == .bash)
        #expect(ChatTerminalCommand(language: "sh", text: "pwd")?.shell == .sh)
        #expect(ChatTerminalCommand(language: "shell", text: "pwd")?.shell == .zsh)
    }

    @Test func consolePromptsAreRemovedWithoutExecutingExampleOutput() {
        for language in ["bash", "console", "terminal", "shell-session", ""] {
            #expect(ChatTerminalCommand(language: language, text: "$ pwd\n$ printf done")?.script == "pwd\nprintf done")
            #expect(ChatTerminalCommand(language: language, text: "$ pwd\n/Users/example/project") == nil)
        }
        #expect(ChatTerminalCommand(language: "console", text: "Build finished successfully") == nil)
    }

    @Test func sourceCodeOutputAndEmptyBlocksDoNotBecomeCommands() {
        for language in ["swift", "python", "json", "output", "text", "powershell", ""] {
            #expect(ChatTerminalCommand(language: language, text: "print(42)") == nil)
        }
        #expect(ChatTerminalCommand(language: "bash", text: " \n\t") == nil)
        #expect(ChatTerminalCommand(language: "bash", text: "# Run the tests\n# Then inspect the result") == nil)
    }

    @Test func terminalControlBytesAndOversizedCommandsAreNotRunnable() {
        for script in ["echo ok\u{1b}[2K", "echo ok\0ignored", "echo ok\u{7}", "echo ok\rhidden", String(repeating: "x", count: 32_001)] {
            #expect(ChatTerminalCommand(language: "bash", text: script) == nil)
        }
        #expect(ChatTerminalCommand(language: "bash", text: "printf ok\r\npwd")?.script == "printf ok\npwd")
    }

    @Test func commandsBelongToTheirChatAndUseItsWorktree() throws {
        let project = Project(path: "/project")
        var session = SessionMeta(projectID: project.id, agent: .codex)
        let command = try #require(ChatTerminalCommand(language: "bash", text: "pwd"))
        let main = try command.invocation(project: project, session: session, environment: [:])
        #expect(main.directory.path == "/project" && main.executable.path == "/bin/bash")
        session.agentTask = AgentTask(prompt: "Task")
        session.agentTask?.workspace = AgentWorkspace(rootPath: "/worktree", workingPath: "/worktree/package", branch: "task", baseCommit: "abc")
        #expect(try command.invocation(project: project, session: session, environment: [:]).directory.path == "/worktree/package")
        session.agentTask?.workspace?.status = .discarded
        #expect(throws: AgentError.self) { try command.invocation(project: project, session: session, environment: [:]) }
        #expect(throws: AgentError.self) { try command.invocation(project: Project(path: "/other"), session: session, environment: [:]) }
    }

    @Test func remoteCommandsUseTheRemoteRuntimeRatherThanTheLocalCache() throws {
        var project = Project(path: "/local-cache")
        project.runtime = WorkspaceRuntime(kind: .ssh, target: "demo-host", directory: "/srv/my project")
        let session = SessionMeta(projectID: project.id, agent: .codex)
        let command = try #require(ChatTerminalCommand(language: "sh", text: "printf '%s' \"remote\""))
        let invocation = try command.invocation(project: project, session: session, environment: [:])
        #expect(invocation.executable.path == "/usr/bin/ssh")
        #expect(invocation.directory.path == "/local-cache")
        #expect(invocation.arguments.contains("demo-host"))
        #expect(invocation.arguments.last?.contains("cd '/srv/my project'") == true)
        #expect(invocation.arguments.last?.contains("/bin/sh -lc ") == true)
        project.runtime?.target = "-invalid-host"
        #expect(throws: AgentError.self) { try command.invocation(project: project, session: session, environment: [:]) }
    }

    @Test func creatingAnInvocationHasNoSideEffectsAndExecutionPreservesTheWholeBlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(path: root.path)
        let session = SessionMeta(projectID: project.id, agent: .codex)
        let script = "cat <<'EOF' > result.txt\nhello 'quoted' 🦊\n$ literal prompt\nEOF\npwd"
        let command = try #require(ChatTerminalCommand(language: "bash", text: script))
        let invocation = try command.invocation(project: project, session: session, environment: [:])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("result.txt").path))
        #expect(invocation.arguments == ["-lc", script])
        let result = try await Command.run(invocation.executable, invocation.arguments, workingDirectory: invocation.directory, timeout: 5)
        #expect(result.succeeded)
        #expect(URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        #expect(try String(contentsOf: root.appendingPathComponent("result.txt"), encoding: .utf8) == "hello 'quoted' 🦊\n$ literal prompt\n")
    }
}
