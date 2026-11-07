import AppKit
import MarikaCore
import SwiftUI

@main
struct MarikaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Marika", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    delegate.model = model
                    model.configureUpdater()
                    await model.bootstrap()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refreshAgents() }
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { MarikaCommands(model: model) }

        Window("Marika Updates", id: "updates") {
            UpdatesView().environment(model).frame(width: 620, height: 600)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare binary during development. A bundled app already is one.
        NSApp.setActivationPolicy(.regular)
        if let icon = Theme.appIcon { NSApp.applicationIconImage = icon }
        NSApp.activate()
        #if DEBUG
            DebugDriver.startIfRequested(delegate: self)
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let busy = model.controllers.values.count { $0.isBusy }
        if busy > 0 {
            let alert = NSAlert()
            alert.messageText = busy == 1 ? "An agent is still working" : "\(busy) agents are still working"
            alert.informativeText = "Quitting stops them. Your project conversations will be saved."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        Task { @MainActor in
            guard await model.confirmClosingEditors(model.allEditors) else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            if !(await model.shutdown()) {
                let alert = NSAlert()
                alert.messageText = "Marika couldn't save your changes"
                alert.informativeText = "Return to the app to retry saving, or quit and lose changes that haven't been saved."
                alert.addButton(withTitle: "Return to App")
                alert.addButton(withTitle: "Quit Without Saving")
                if alert.runModal() != .alertSecondButtonReturn {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                await model.shutdown(saveChanges: false)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MarikaCommands: Commands {
    @Bindable var model: AppModel
    @FocusedValue(\.fileNavigator) private var fileNavigator
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                openWindow(id: "updates")
                Task { await model.updates.check() }
            }
            Button("Release Notes…") { openWindow(id: "updates") }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") { model.chooseProject() }
                .keyboardShortcut("o")
            Button("New Space…") { openWindow(id: "main"); model.showSpaceEditor() }
                .disabled(model.workspaceLoadFailed)
            Button("Go to File…") { model.showCode(quickOpen: true) }
                .keyboardShortcut("p")
                .disabled(model.selectedSession == nil)
            Button("Launch Agent…") { model.showAgents(launch: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.spaceProjects.isEmpty)
        }
        CommandGroup(after: .newItem) {
            Button("Move to Trash…") {
                if let editor = fileNavigator, let path = editor.navigatorSelection { editor.pendingTrashPath = path }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(fileNavigator?.supportsTrash != true || fileNavigator?.navigatorSelection == nil || fileNavigator?.trashingPath != nil)
            Button("Command Palette…") { model.showsCommandPalette = true }.keyboardShortcut("k")
            Button("Search Project…") { model.showsProjectSearch = true }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model.selectedSession == nil)
            Button("Search Chat History…") { openWindow(id: "main"); model.showsChatHistorySearch = true }
                .keyboardShortcut("h", modifiers: [.command, .shift]).disabled(model.workspaceLoadFailed)
            Button("Run or Stop Preview") {
                guard let project = model.selectedProject else { return }
                let preview = model.preview(for: project)
                if preview.isActive { preview.stop() } else { model.runPreview() }
            }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.selectedSession == nil)
            Button("Toggle Split View") {
                guard let project = model.selectedProject else { return }
                let saved = model.layout(for: project.id)
                model.setSplit(saved.secondary == nil ? ((model.projectTabs[project.id] ?? .conversation) == .code ? .conversation : .code) : nil)
            }.keyboardShortcut("\\", modifiers: [.command, .option]).disabled(model.selectedSession == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save File") {
                if let editor = model.activeEditor, let document = editor.selectedDocument {
                    Task { await editor.save(document) }
                }
            }
            .keyboardShortcut("s")
            .disabled(model.activeEditor?.selectedDocument.map { !$0.isModified || $0.isSaving || $0.changedOnDisk } ?? true)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in File…") {
                model.activeEditor?.findRequest += 1
            }
            .keyboardShortcut("f")
            .disabled(model.activeEditor?.selectedDocument?.isEditable != true)
        }
        CommandMenu("Navigate") {
            Button("Previous Project Tab") { model.selectAdjacentProjectTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(model.selectedProject == nil)
            Button("Next Project Tab") { model.selectAdjacentProjectTab(1) }
                .keyboardShortcut(.tab, modifiers: .control).disabled(model.selectedProject == nil)
            Button("Close Project Tab") {
                if let project = model.selectedProject { model.closeProjectTab(model.layout(for: project.id).panel) }
            }.disabled(model.selectedProject.map { model.layout(for: $0.id).panel == .conversation } ?? true)
            Divider()
            Button("Previous Space") { model.selectAdjacentSpace(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .option]).disabled(model.workspace.spaces.count < 2)
            Button("Next Space") { model.selectAdjacentSpace(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option]).disabled(model.workspace.spaces.count < 2)
            Menu("Switch Space") {
                ForEach(model.workspace.spaces) { space in
                    Button { model.selectSpace(space.id) } label: {
                        Label(space.name, systemImage: model.selectedSpace.id == space.id ? "checkmark" : space.symbol)
                    }
                }
            }
            Divider()
            ForEach(AppModel.ProjectTab.allCases, id: \.self) { tab in
                Button("Show \(tab.title)") { model.switchPanel(tab) }
                    .keyboardShortcut(KeyEquivalent(Character(tab.shortcut)))
                    .disabled(model.selectedSession == nil)
            }
            Divider()
            Button("Back") { model.activeEditor?.goBack() }
                .keyboardShortcut("[")
                .disabled(model.activeEditor?.canGoBack != true)
            Button("Forward") { model.activeEditor?.goForward() }
                .keyboardShortcut("]")
                .disabled(model.activeEditor?.canGoForward != true)
            Divider()
            Button("Focus Files") { model.showCode(focusFiles: true) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedSession == nil)
            Button(model.activeEditor?.showsNavigator == false ? "Show File List" : "Hide File List") {
                model.activeEditor?.showsNavigator.toggle()
            }
            .keyboardShortcut("\\")
            .disabled(model.activeEditor == nil)
            Divider()
            Button("Previous File") { model.activeEditor?.selectAdjacentDocument(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((model.activeEditor?.documents.count ?? 0) < 2)
            Button("Next File") { model.activeEditor?.selectAdjacentDocument(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((model.activeEditor?.documents.count ?? 0) < 2)
        }
        CommandMenu("Project") {
            Button("Terminal") { model.openTerminal() }
                .keyboardShortcut("`", modifiers: .control).disabled(model.selectedProject == nil)
            Button("Project Settings…") { if let project = model.selectedProject { model.openProjectSettings(project) } }
                .keyboardShortcut(",", modifiers: [.command, .shift]).disabled(model.selectedProject == nil)
            Button("MCP Servers…") { if let project = model.selectedProject { model.openProjectSettings(project, section: "MCP") } }
                .disabled(model.selectedProject == nil)
            if let project = model.selectedProject {
                ForEach(project.tools?.actions ?? []) { action in
                    Button(action.name) { model.openTerminal(command: action.command) }
                }
            }
            Divider()
            Button("Show Agents") { model.showAgents() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.spaceProjects.isEmpty)
            Button("Show Browser") {
                guard let meta = model.selectedSession, let project = model.project(for: meta) else { return }
                _ = model.browser(for: project)
                model.projectTabs[project.id] = .browser
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model.selectedSession == nil)

            Divider()
            Button("Stop Agent") {
                if let id = model.selectedSessionID { model.controllers[id]?.interrupt() }
            }
            .keyboardShortcut(".")
            .disabled(!(model.selectedSessionID.flatMap { model.controllers[$0]?.isBusy } ?? false))

            Divider()

            Button(model.showsInspector ? "Hide Changes" : "Show Changes") { model.showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.selectedSession == nil)
        }
    }
}
