import AppKit
import MarikaCore
import SwiftUI

struct ProjectSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var query = ""
    @State private var caseSensitive = false
    @State private var regularExpression = false
    @State private var replacement = ""
    @State private var replacements: [ProjectReplacement] = []
    @State private var matches: [ProjectSearchMatch] = []
    @State private var searching = false
    @State private var selection: String?
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search in \(project.name)…", text: $query).textFieldStyle(.plain)
                    .font(.system(size: 16)).focused($focused).onSubmit(openSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Toggle("Match case", isOn: $caseSensitive).toggleStyle(.button).controlSize(.small)
                Toggle(".*", isOn: $regularExpression).toggleStyle(.button).controlSize(.small).help("Regular expression")
                if searching { ProgressView().controlSize(.small) }
            }.padding(18)
            HStack {
                TextField("Replace with…", text: $replacement).textFieldStyle(.roundedBorder)
                Button("Preview replacement") {
                    Task {
                        do {
                            let files: any WorkspaceFiles = project.runtime?.kind == .ssh ? RemoteFiles(runtime: project.runtime!, cache: project.editorURL, environment: model.toolEnvironment) : ProjectFiles(root: project.editorURL)
                            replacements = try await ProjectSearch.replacements(query, replacement: replacement, caseSensitive: caseSensitive, regularExpression: regularExpression, files: files)
                            error = "\(replacements.count) files will change. Apply creates editor drafts for review."
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(query.isEmpty)
                if !replacements.isEmpty {
                    Button("Apply to drafts") {
                        Task {
                            let editor = model.editor(for: project)
                            for change in replacements {
                                await editor.open(change.snapshot.path, focus: false)
                                guard let document = editor.documents.first(where: { $0.path == change.snapshot.path }), document.text == change.snapshot.text else { error = "A matching file changed. Preview again."; return }
                            }
                            for change in replacements { editor.documents.first(where: { $0.path == change.snapshot.path })?.text = change.updated }
                            replacements = []; dismiss(); model.showCode()
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }.controlSize(.small).padding(.horizontal, 18).padding(.bottom, 12)
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18) }
            Divider()
            List(matches, selection: $selection) { match in
                Button { open(match) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(match.path, systemImage: FileVisuals.symbol(match.path)).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("Line \(match.line)").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(match.preview).font(Theme.codeSmall).lineLimit(2).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).tag(match.id)
            }
            .listStyle(.plain).onKeyPress(.return) { openSelected(); return .handled }
            .overlay {
                if matches.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Search project contents" : searching ? "Searching…" : "No matches",
                        systemImage: "doc.text.magnifyingglass", description: Text(error ?? "Find text across your project's files."))
                }
            }
            Divider()
            HStack {
                Text(matches.count == 500 ? "500+ matches · refine your search" : "\(matches.count) matches")
                Spacer(); Text("↑↓ choose · Return open · Esc close")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 700, height: 490).background(Theme.canvas)
        .onAppear { focused = true }.onExitCommand { dismiss() }
        .task(id: query + "|" + String(caseSensitive) + String(regularExpression)) {
            guard !query.isEmpty else { matches = []; searching = false; return }
            searching = true; error = nil
            do {
                try await Task.sleep(for: .milliseconds(160))
                let files: (any WorkspaceFiles)? = project.runtime?.kind == .ssh ? RemoteFiles(runtime: project.runtime!, cache: project.editorURL, environment: model.toolEnvironment) : nil
                let results = try await ProjectSearch.search(query, root: project.editorURL, caseSensitive: caseSensitive, regularExpression: regularExpression, files: files)
                guard !Task.isCancelled else { return }
                matches = results; selection = results.first?.id; searching = false
            } catch is CancellationError {} catch { self.error = error.localizedDescription; searching = false }
        }
    }
    private func move(_ offset: Int) {
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == selection } ?? 0
        selection = matches[max(0, min(matches.count - 1, index + offset))].id
    }
    private func openSelected() { if let match = matches.first(where: { $0.id == selection }) ?? matches.first { open(match) } }
    private func open(_ match: ProjectSearchMatch) { dismiss(); model.openSearchMatch(match) }
}

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool
    private struct Action: Identifiable {
        let id: String, title: String, symbol: String, shortcut: String
        let run: () -> Void
    }
    private var actions: [Action] {
        var result = [Action(id: "open", title: "Open Project…", symbol: "folder.badge.plus", shortcut: "⌘O", run: model.chooseProject)]
        result.append(Action(id: "chat-history", title: "Search Chat History…", symbol: "text.magnifyingglass", shortcut: "⇧⌘H", run: { model.showsChatHistorySearch = true }))
        result.append(Action(id: "new-space", title: "New Space…", symbol: "square.stack.3d.up", shortcut: "", run: { model.showSpaceEditor() }))
        result += model.workspace.spaces.map { space in
            Action(id: "space-" + space.id.uuidString, title: "Switch to space: " + space.name, symbol: space.symbol, shortcut: "", run: { model.selectSpace(space.id) })
        }
        if let project = model.selectedProject {
            result += [
                Action(id: "files", title: "Go to File…", symbol: "doc.text.magnifyingglass", shortcut: "⌘P", run: { model.showCode(quickOpen: true) }),
                Action(id: "search", title: "Search Project…", symbol: "magnifyingglass", shortcut: "⇧⌘F", run: { model.showsProjectSearch = true }),
                Action(id: "preview", title: model.previews[project.id]?.isActive == true ? "Stop Preview" : "Run Project Preview", symbol: "play.fill", shortcut: "⇧⌘R", run: {
                    let preview = model.preview(for: project)
                    if preview.isActive { preview.stop() } else { model.runPreview() }
                }),
                Action(id: "logs", title: "Preview Settings and Logs", symbol: "terminal", shortcut: "", run: { model.openPreviewSettings(for: project) }),
                Action(id: "agent", title: "Launch Agent…", symbol: "person.badge.plus", shortcut: "⇧⌘N", run: { model.showAgents(launch: true) }),
                Action(id: "split", title: "Split with Code", symbol: "rectangle.split.2x1", shortcut: "⌥⌘\\", run: { model.setSplit(.code) }),
                Action(id: "unsplit", title: "Close Split View", symbol: "rectangle", shortcut: "", run: { model.setSplit(nil) }),
            ]
            result += ProjectPanel.allCases.map { panel in
                Action(id: panel.rawValue, title: "Show " + panel.rawValue, symbol: "rectangle.on.rectangle", shortcut: "⌘" + panel.shortcut,
                       run: { model.switchPanel(panel) })
            }
        }
        result += model.workspace.projects.map { project in
            Action(id: project.id.uuidString, title: "Switch to " + project.name, symbol: "folder", shortcut: "", run: { model.openProject(project) })
        }
        return result
    }
    private var matches: [Action] {
        let words = query.split(separator: " ").map(String.init)
        return actions.filter { action in words.allSatisfy { action.title.localizedStandardContains($0) } }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("What would you like to do?", text: $query).textFieldStyle(.plain)
                    .font(.system(size: 16)).focused($focused).onSubmit(perform)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
            }.padding(18)
            Divider()
            List(matches, selection: $selection) { action in
                Button { choose(action) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol).frame(width: 20).foregroundStyle(.secondary)
                        Text(action.title); Spacer()
                        Text(action.shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).tag(action.id)
            }.listStyle(.plain).onKeyPress(.return) { perform(); return .handled }
            Divider()
            Text("↑↓ choose · Return run · Esc close").font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }.frame(width: 580, height: 430).background(Theme.canvas)
        .onAppear { focused = true; selection = matches.first?.id }
        .onChange(of: query) { _, _ in selection = matches.first?.id }
        .onExitCommand { dismiss() }
    }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == selection } ?? 0
        selection = matches[max(0, min(matches.count - 1, index + delta))].id
    }
    private func perform() { if let action = matches.first(where: { $0.id == selection }) ?? matches.first { choose(action) } }
    private func choose(_ action: Action) { model.pendingPaletteAction = action.run; dismiss() }
}

struct PreviewConsoleView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var command = ""
    @State private var address = ""
    let preview: ProjectPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Project Preview").font(.system(size: 20, weight: .semibold))
                Spacer(); Text(preview.state.rawValue.capitalized).foregroundStyle(.secondary)
                Button { model.previewProjectID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            TextField("Run command, e.g. npm run dev", text: $command).textFieldStyle(.roundedBorder)
            TextField("Preview URL, e.g. http://localhost:3000", text: $address).textFieldStyle(.roundedBorder)
            HStack {
                Button(preview.isActive ? "Stop" : "Run Preview") {
                    if preview.isActive { preview.stop() }
                    else {
                        model.savePreviewConfiguration(PreviewConfiguration(command: command, address: address), for: project)
                        model.runPreview(for: model.project(id: project.id))
                    }
                }.buttonStyle(.borderedProminent).disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let url = preview.address {
                    Button("Open Preview") { model.browser(for: project).navigate(url.absoluteString); model.switchPanel(.browser) }
                }
                Spacer()
                Button("Copy Logs") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(preview.logs, forType: .string) }
            }
            if let error = preview.error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.attention) }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(preview.logs.isEmpty ? "Server output will appear here." : preview.logs)
                        .font(Theme.codeSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }.padding(12).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: preview.logs) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }.padding(22).frame(width: 670, height: 470)
        .onAppear {
            let config = project.previewConfiguration ?? ProjectPreview.detect(at: project.url)
            command = config?.command ?? ""; address = config?.address ?? "http://localhost:3000"
        }
    }
}
