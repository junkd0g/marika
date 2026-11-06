import AppKit
import MarikaCore

extension AppModel {
    var toolEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment.merging(gitEnvironment) { _, captured in captured }
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        var paths = [Bundle.main.resourceURL?.appendingPathComponent("Tools").path].compactMap { $0 }
        #if DEBUG
            paths.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".tools/bin").path)
        #endif
        paths += ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/go/bin"]
        env["PATH"] = (paths + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return env
    }
    func ide(for project: Project, editor: CodeWorkspace) -> IDEWorkspace {
        let key = project.id.uuidString + editor.root.path
        if let existing = ideWorkspaces[key] { return existing }
        let ide = IDEWorkspace(editor: editor, context: ToolContext(root: editor.root, environment: toolEnvironment, runtime: project.runtime), preferences: project.tools?.ide ?? IDEPreferences())
        editor.beforeSave = { [weak ide] document in
            if let ide, ide.preferences.formatOnSave { try await ide.format(document) }
        }
        ideWorkspaces[key] = ide
        return ide
    }
    func openRemoteWorkspace(_ runtime: WorkspaceRuntime, from project: Project) async throws {
        let cache = store.root.appendingPathComponent("remote-workspaces").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let check = try await runtime.run("python3 -c 'import os; print(os.getcwd())'", localRoot: cache, environment: toolEnvironment)
        guard check.succeeded else { throw AgentError.launchFailed(check.errorOutput) }
        addProject(at: cache)
        guard let added = workspace.projects.first(where: { $0.url == cache }) else { return }
        updateProject(added.id) { $0.runtime = runtime; $0.name = runtime.target + ": " + runtime.directory; $0.tools = project.tools }
        editors[added.id] = nil; repositoryEditors[added.id] = nil
        if let refreshed = self.project(id: added.id) { _ = editor(for: refreshed); openProject(refreshed, tab: .code) }
    }
    func openContainer(_ image: String, project: Project) async throws {
        guard let docker = ShellEnvironment.locate("docker", in: toolEnvironment), !image.isEmpty, !image.hasPrefix("-") else { throw AgentError.launchFailed("Provide a Docker image and start Docker.") }
        let name = "marika-dev-" + String(project.id.uuidString.prefix(8)).lowercased()
        let result = try await Command.run(docker, ["run", "-d", "--init", "--name", name, "--label", "app.marika.workspace=true", "-v", project.path + ":/workspace", "-w", "/workspace", image, "sh", "-c", "while sleep 3600; do :; done"], environment: toolEnvironment, timeout: 180)
        guard result.succeeded else { throw AgentError.launchFailed(result.errorOutput) }
        updateProject(project.id) { $0.runtime = WorkspaceRuntime(kind: .container, target: name, directory: "/workspace") }
        for (key, ide) in ideWorkspaces where key.hasPrefix(project.id.uuidString) { await ide.shutdown(); ideWorkspaces[key] = nil }
        if let refreshed = self.project(id: project.id), let editor = editors[project.id] { _ = ide(for: refreshed, editor: editor) }
    }
}
