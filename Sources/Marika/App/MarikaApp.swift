import AppKit
import MarikaCore
import SwiftUI
import UserNotifications

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
                    delegate.openPendingTaskActivity()
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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor var model: AppModel?
    private var pendingActivity: (UUID, String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // UserNotifications requires an app bundle; a bare SwiftPM executable has no
        // bundle proxy and can raise an Objective-C exception before the UI opens.
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
        // Needed when running the bare binary during development. A bundled app already is one.
        NSApp.setActivationPolicy(.regular)
        if let icon = Theme.appIcon { NSApp.applicationIconImage = icon }
        NSApp.activate()
        #if DEBUG
            DebugDriver.startIfRequested(delegate: self)
        #endif
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let project = response.notification.request.content.userInfo["projectID"] as? String,
              let projectID = UUID(uuidString: project), let eventID = response.notification.request.content.userInfo["eventID"] as? String else { return }
        await MainActor.run { self.pendingActivity = (projectID, eventID); self.openPendingTaskActivity() }
    }

    func openPendingTaskActivity() {
        guard let model, model.isReady, let (projectID, eventID) = pendingActivity else { return }
        pendingActivity = nil
        model.openTaskActivity(eventID, projectID: projectID)
        NSApp.activate()
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
        CommandGroup(replacing: .help) {
            Button("Getting Started…") {
                openWindow(id: "main")
                model.showWelcome()
            }
            .disabled(!model.isReady || model.workspaceLoadFailed)
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
            Button(model.activeBrowser == nil ? "Find in File…" : "Find in Page…") {
                if let browser = model.activeBrowser { browser.findRequest = UUID() }
                else { model.activeEditor?.findRequest += 1 }
            }
            .keyboardShortcut("f")
            .disabled(model.activeBrowser?.selectedPage?.url == nil && model.activeEditor?.selectedDocument?.isEditable != true)
        }
        CommandMenu("Browser") {
            Group {
                Button("New Browser Tab") { model.activeBrowser?.newTab() }.keyboardShortcut("t")
                Button("Close Browser Tab") {
                    if let browser = model.activeBrowser, let page = browser.selectedPage { browser.close(page) }
                }.keyboardShortcut("w")
                Button("Reopen Closed Browser Tab") { model.activeBrowser?.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(model.activeBrowser?.closedTabs.isEmpty != false)
                Divider()
                Button("Open Location…") { model.activeBrowser?.addressFocusRequest = UUID() }.keyboardShortcut("l")
                Button("Reload Page") { model.activeBrowser?.selectedPage?.reload() }.keyboardShortcut("r")
                Button("Stop Loading") { model.activeBrowser?.selectedPage?.webView.stopLoading() }
                    .keyboardShortcut(.escape, modifiers: []).disabled(model.activeBrowser?.selectedPage?.isLoading != true)
                Divider()
                Button("Previous Browser Tab") { model.activeBrowser?.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Browser Tab") { model.activeBrowser?.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Divider()
                Button("Bookmark This Page") { model.activeBrowser?.toggleBookmark() }.keyboardShortcut("d")
                Button("Show Browser History") { model.activeBrowser?.showsHistory.toggle() }.keyboardShortcut("y")
                Divider()
                Button("Zoom In") { model.activeBrowser?.selectedPage?.changeZoom(0.1) }.keyboardShortcut("+")
                Button("Zoom Out") { model.activeBrowser?.selectedPage?.changeZoom(-0.1) }.keyboardShortcut("-")
                Button("Actual Size") { model.activeBrowser?.selectedPage?.zoom = 1 }
            }.disabled(model.activeBrowser == nil)
        }
        CommandMenu("Navigate") {
            Button("Needs Attention") { openWindow(id: "main"); model.openSpaceSection(.attention) }
                .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!model.isReady || model.workspaceLoadFailed)
            Divider()
            Button(model.activeBrowser == nil ? "Previous Project Tab" : "Previous Browser Tab") {
                if let browser = model.activeBrowser { browser.selectAdjacentTab(-1) }
                else { model.selectAdjacentProjectTab(-1) }
            }
                .keyboardShortcut(.tab, modifiers: [.control, .shift]).disabled(model.selectedProject == nil)
            Button(model.activeBrowser == nil ? "Next Project Tab" : "Next Browser Tab") {
                if let browser = model.activeBrowser { browser.selectAdjacentTab(1) }
                else { model.selectAdjacentProjectTab(1) }
            }
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
            Button("Back") {
                if let browser = model.activeBrowser { browser.selectedPage?.webView.goBack() }
                else { model.activeEditor?.goBack() }
            }
                .keyboardShortcut("[")
                .disabled(model.activeBrowser.map { $0.selectedPage?.canGoBack != true } ?? (model.activeEditor?.canGoBack != true))
            Button("Forward") {
                if let browser = model.activeBrowser { browser.selectedPage?.webView.goForward() }
                else { model.activeEditor?.goForward() }
            }
                .keyboardShortcut("]")
                .disabled(model.activeBrowser.map { $0.selectedPage?.canGoForward != true } ?? (model.activeEditor?.canGoForward != true))
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
                .disabled(model.activeBrowser != nil || (model.activeEditor?.documents.count ?? 0) < 2)
            Button("Next File") { model.activeEditor?.selectAdjacentDocument(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.activeBrowser != nil || (model.activeEditor?.documents.count ?? 0) < 2)
        }
        CommandMenu("Project") {
            Button("Terminal") { model.openTerminal() }
                .keyboardShortcut("`", modifiers: .control).disabled(model.selectedProject == nil)
            Button("Project Settings…") { if let project = model.selectedProject { model.openProjectSettings(project) } }
                .keyboardShortcut(",", modifiers: [.command, .shift]).disabled(model.selectedProject == nil)
            Button("Connections…") { if let project = model.selectedProject { model.openProjectSettings(project, section: "MCP") } }
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
