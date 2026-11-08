import AppKit
import Darwin
import MarikaCore
import SwiftUI
@preconcurrency import SwiftTerm

@MainActor @Observable final class ProjectTerminal {
    struct Shell: Identifiable {
        let id = UUID()
        let directory: URL
        let name: String
        let view: LocalProcessTerminalView
    }
    var shells: [Shell] = []
    var selected: UUID?

    func add(at directory: URL, name: String, environment: [String: String]) {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 350))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var env = environment
        env["TERM"] = "xterm-256color"
        view.startProcess(executable: "/bin/zsh", args: ["-l"], environment: env.map { $0.key + "=" + $0.value }, currentDirectory: directory.path)
        let shell = Shell(directory: directory, name: name, view: view)
        shells.append(shell)
        selected = shell.id
    }
    var current: Shell? { shells.first { $0.id == selected } }
    func run(_ command: ChatTerminalCommand, invocation: ChatTerminalCommand.Invocation, environment: [String: String]) {
        let view = ChatCommandTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 350))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.feed(text: "$ " + command.script.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n")
        var env = environment
        env["TERM"] = "xterm-256color"
        view.startProcess(executable: invocation.executable.path, args: invocation.arguments,
                          environment: env.map { $0.key + "=" + $0.value }, currentDirectory: invocation.directory.path)
        let shell = Shell(directory: invocation.directory, name: command.title, view: view)
        shells.append(shell)
        selected = shell.id
    }
    func addRemote(arguments: [String], name: String, directory: URL, environment: [String: String]) {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 350))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var env = environment; env["TERM"] = "xterm-256color"
        view.startProcess(executable: "/usr/bin/ssh", args: arguments, environment: env.map { $0.key + "=" + $0.value }, currentDirectory: directory.path)
        let shell = Shell(directory: directory, name: name, view: view)
        shells.append(shell); selected = shell.id
    }
    func close(_ id: UUID) {
        guard let shell = shells.first(where: { $0.id == id }) else { return }
        let pid = shell.view.process.shellPid
        if pid > 0 && shell.view.process.running { kill(-pid, SIGHUP) }
        shell.view.terminate()
        shells.removeAll { $0.id == id }
        if selected == id { selected = shells.last?.id }
    }
    func shutdown() { for id in shells.map(\.id) { close(id) } }
    func output() -> String {
        guard let view = current?.view else { return "" }
        return String(String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).suffix(12000))
    }
    func send(_ command: String) { current?.view.process.send(data: Array((command + "\n").utf8)[...]) }
}

private final class ChatCommandTerminalView: LocalProcessTerminalView {
    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        // SwiftTerm's forkpty backend reports the raw waitpid status.
        let result = exitCode.map { status in
            let signal = status & 0x7f
            return signal == 0 ? " · exit \((status >> 8) & 0xff)" : " · signal \(signal)"
        } ?? ""
        feed(text: "\r\n[Command finished" + result + "]\r\n")
    }
}

struct ProjectTerminalView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var isVisible = true
    private var terminal: ProjectTerminal? { model.terminals[project.id] }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(terminal?.shells ?? []) { shell in
                            Button(shell.name) { terminal?.selected = shell.id }
                                .tint(shell.id == terminal?.selected ? .accentColor : .secondary)
                            Button { terminal?.close(shell.id) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                        }
                    }
                }
                Menu {
                    Button("Project shell") { terminal?.add(at: project.url, name: project.name, environment: model.gitEnvironment) }
                    ForEach(project.repositoryURLs.filter { $0 != project.url }, id: \.path) { url in
                        Button(url.lastPathComponent) { terminal?.add(at: url, name: url.lastPathComponent, environment: model.gitEnvironment) }
                    }
                    ForEach(model.sessions(in: project).filter { $0.agentTask?.workspace?.status != .discarded && $0.agentTask?.workspace != nil }) { session in
                        Button(session.title) {
                            if let path = session.agentTask?.workspace?.workingPath {
                                terminal?.add(at: URL(fileURLWithPath: path), name: session.title, environment: model.gitEnvironment)
                            }
                        }
                    }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("New shell")
                Button("Send output to chat") {
                    guard let text = terminal?.output(), !text.isEmpty, let session = model.selectedSession.flatMap({ model.controllers[$0.id] }) else { return }
                    session.draft += (session.draft.isEmpty ? "" : "\n\n") + "Terminal output\n```\n" + text + "\n```"
                    model.switchPanel(.conversation)
                    model.setSplit(.terminal)
                    model.openAgentChat(session.id)
                }.disabled(terminal?.current == nil)
            }.controlSize(.small).padding(10)
            Divider()
            if let shell = terminal?.current {
                TerminalHost(view: shell.view, isActive: isVisible, directory: shell.directory, roots: project.repositoryURLs) { link, root, path in
                    model.openLocation(path: path, line: link.line, column: link.column, root: root)
                }.id(shell.id)
            } else {
                ContentUnavailableView("Open a shell", systemImage: "terminal", description: Text("Use + to open a project or agent worktree shell."))
            }
        }.task { model.ensureTerminal(for: project) }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView
    let isActive: Bool
    let directory: URL
    let roots: [URL]
    var open: (TerminalFileLink, URL, String) -> Void
    func makeCoordinator() -> TerminalFileNavigation { TerminalFileNavigation(view: view, directory: directory, roots: roots, open: open) }
    func makeNSView(context: Context) -> LocalProcessTerminalView { view }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.roots = roots; context.coordinator.open = open
        context.coordinator.isActive = isActive
        if !isActive, let window = nsView.window, window.firstResponder === nsView { window.makeFirstResponder(nil) }
    }
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: TerminalFileNavigation) { coordinator.invalidate() }
}
