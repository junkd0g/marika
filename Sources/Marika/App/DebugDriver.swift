#if DEBUG
    import AppKit
    import MarikaCore
    import PDFKit
    import SwiftUI

    /// Runs a scripted session through the real UI so a change can be checked end to end. Debug
    /// builds only. Set MARIKA_DRIVER to a JSON array of steps, and MARIKA_DATA to keep test
    /// state away from your own sessions. See scripts/smoke.sh.
    @MainActor
    enum DebugDriver {
        static let openSettingsRequest = Notification.Name("MarikaDebugOpenSettings")
        static var agentReferences: [String: UUID] = [:]

        static func startIfRequested(delegate: AppDelegate) {
            guard let path = DebugFixtureSettings.value("MARIKA_DRIVER") else { return }
            Task {
                do {
                    let steps = try JSONValue(parsing: Data(contentsOf: URL(fileURLWithPath: path)))
                    while delegate.model?.isReady != true { try await pause(0.05) }
                    for step in steps.array ?? [] {
                        log("→ \(step["op"]?.string ?? "?")")
                        try await run(step, delegate.model!)
                    }
                } catch {
                    log("FAILED: \(error)")
                    await delegate.model?.shutdown(saveChanges: false)
                    exit(1)
                }
            }
        }

        static func log(_ message: String) {
            let data = Data("[driver] \(message)\n".utf8)
            FileHandle.standardError.write(data)
            if let path = DebugFixtureSettings.value("MARIKA_DRIVER_LOG") {
                if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
                if let file = FileHandle(forWritingAtPath: path) {
                    defer { try? file.close() }
                    _ = try? file.seekToEnd()
                    try? file.write(contentsOf: data)
                }
            }
        }

        static func pause(_ seconds: Double) async throws {
            try await Task.sleep(for: .seconds(seconds))
        }

        static func current(_ model: AppModel) async throws -> SessionController {
            guard let id = model.selectedSessionID else { throw DriverError("no session selected") }
            await model.open(id)
            guard let session = model.controllers[id] else { throw DriverError("session did not open") }
            return session
        }

        struct DriverError: Error, CustomStringConvertible {
            var description: String
            init(_ description: String) { self.description = description }
        }

        @MainActor final class WindowTransition { var finished = false }

        static func run(_ step: JSONValue, _ model: AppModel) async throws {
            if try await runInterfaceStep(step, model) { return }
            if try await runAgentStep(step, model) { return }
            if try await runBrowserAndServicesStep(step, model) { return }
            if try await runDesignStep(step, model) { return }
            if try await runWorkspaceStep(step, model) { return }
            if try await runEditorStep(step, model) { return }
            throw DriverError("unknown step: \(step)")
        }

        static func testMarkdown(_ step: JSONValue, _ model: AppModel) async throws {
            guard let project = model.selectedProject else { throw DriverError("No project") }
            model.showsInspector = false
            model.selectProjectTab(.code)
            let editor = model.editor(for: project)
            await editor.loadDirectory("")
            try await pause(0.4)
            try await run(["op": "codeClickRow", "path": "README.md"], model)
            try await pause(0.6)
            guard let document = editor.selectedDocument, document.path == "README.md", document.isMarkdown,
                  document.markdownPresentation == .preview else { throw DriverError("Markdown file did not open in Preview on a single click") }
            let original = document.text
            guard let content = window()?.contentView,
                  marker(in: content, named: "markdown-preview") != nil else { throw DriverError("Rendered Markdown view missing") }
            if let folder = step["directory"]?.string { try snapshot(to: folder + "/markdown-preview.png", title: nil) }
            try await run(["op": "clickMarker", "name": "markdown-mode-edit"], model)
            guard let field = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }),
                  document.markdownPresentation == .source, field.editorActive else { throw DriverError("Edit mode did not activate the source editor") }
            let identity = ObjectIdentifier(field)
            field.insertText("\n\n## Live update\n\nThis paragraph came from the editor.\n", replacementRange: NSRange(location: (field.string as NSString).length, length: 0))
            try await pause(0.25)
            guard document.isModified, document.text.contains("Live update") else { throw DriverError("Source editing did not update the Markdown document") }
            try await run(["op": "clickMarker", "name": "markdown-mode-split"], model)
            try await pause(0.3)
            guard document.markdownPresentation == .split,
                  let retained = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }),
                  ObjectIdentifier(retained) == identity else { throw DriverError("Switching preview mode recreated the source editor") }
            if let folder = step["directory"]?.string { try snapshot(to: folder + "/markdown-split.png", title: nil) }
            field.undoManager?.undo()
            try await pause(0.2)
            guard document.text == original else { throw DriverError("Preview mode lost the editor undo history") }
            field.undoManager?.redo()
            try await pause(0.2)
            guard document.text.contains("Live update"), await editor.save(document) else { throw DriverError("Markdown edits did not save") }
            guard try String(contentsOf: project.url.appendingPathComponent(document.path), encoding: .utf8) == document.text else { throw DriverError("Saved Markdown differs from the source") }
            try await run(["op": "clickMarker", "name": "markdown-mode-preview"], model)
            guard (window()?.firstResponder as? CodeEditingTextView)?.documentID != document.id else { throw DriverError("Preview left the hidden source editor focused") }
            editor.findRequest += 1
            try await pause(0.3)
            guard document.markdownPresentation == .source, field.enclosingScrollView?.isFindBarVisible == true else { throw DriverError("Find did not open the Markdown source and search bar") }
            await editor.open("notes.txt")
            guard editor.selectedDocument?.isMarkdown == false else { throw DriverError("Plain text was treated as Markdown") }
            editor.selectDocument(document.id)
            try await run(["op": "clickMarker", "name": "markdown-mode-split"], model)
            NSApp.appearance = NSAppearance(named: .aqua)
            window()?.setContentSize(NSSize(width: 1020, height: 820))
            try await pause(0.3)
            if let folder = step["directory"]?.string { try snapshot(to: folder + "/markdown-compact.png", title: nil) }
            log("Markdown passed: single-click Preview, native editing, live Split, retained editor identity and undo, save, Find and compact layout")
        }

        static func testProjectChat(_ step: JSONValue, _ model: AppModel) async throws {
            guard let project = model.selectedProject, let main = model.workspace.conversation(for: project.id) else { throw DriverError("No project chat") }
            model.agentFactoryOverride = { _ in DebugTaskAgent(seconds: 0.35) }
            model.showsInspector = false
            NSApp.activate()
            await model.open(main.id)
            let reviewer = try await model.launchAgent(in: project, agent: .codex, settings: AgentSettings(),
                prompt: "Review the API changes and suggest the next tests.", isolated: false)
            let tester = try await model.launchAgent(in: project, agent: .claude, settings: AgentSettings(),
                prompt: "Check the GraphQL and gRPC test coverage.", isolated: false)
            model.rename(reviewer.id, to: "API reviewer")
            model.rename(tester.id, to: "Test engineer")
            model.openAgentChat(main.id)
            try await pause(1)
            guard model.chatUnreadCount(reviewer.id) == 1, model.chatUnreadCount(tester.id) == 1 else {
                throw DriverError("Background agent replies were not marked unread")
            }
            try await run(["op": "clickMarker", "name": .string("chat-agent-" + reviewer.id.uuidString)], model)
            // Headless macOS can deny foreground activation; simulate the visible-read signal
            // separately while still verifying the actual native navigation click.
            if !NSApp.isActive { model.markChatRead(reviewer.id) }
            guard model.selectedSessionID == reviewer.id, model.chatUnreadCount(reviewer.id) == 0 else {
                if let folder = step["directory"]?.string { try snapshot(to: folder + "/chat-click.png", title: nil) }
                throw DriverError("Agent click: selected=\(model.selectedSessionID == reviewer.id) unread=\(model.chatUnreadCount(reviewer.id)) active=\(NSApp.isActive) visible=\(model.visibleChatSessionIDs.contains(reviewer.id))")
            }
            reviewer.draft = "Unsent follow-up stays here"
            model.openAgentChat(main.id)
            guard let source = model.controllers[main.id] else { throw DriverError("Main chat not loaded") }
            let mention = "@" + ProjectChat.handle(for: reviewer.meta) + " What should we test next?"
            source.draft = "@codex"
            try await pause(0.2)
            guard let content = window()?.contentView,
                  let prompt = textViews(in: content).first(where: { $0 is PromptTextView }) else { throw DriverError("Chat composer missing") }
            prompt.doCommand(by: #selector(NSResponder.insertTab(_:)))
            guard source.draft == "@" + ProjectChat.handle(for: reviewer.meta) + " " else { throw DriverError("Mention autocomplete did not choose the project agent") }
            source.draft = mention
            try await pause(0.2)
            window()?.makeFirstResponder(prompt)
            try await run(["op": "key", "code": 36], model)
            try await pause(0.3)
            guard source.draft.isEmpty, reviewer.draft == "Unsent follow-up stays here",
                  model.selectedSessionID == reviewer.id,
                  reviewer.items.contains(where: { if case .user(let text, _) = $0.content { return text == "What should we test next?" }; return false }) else {
                throw DriverError("Mention routing lost a draft or sent to the wrong agent")
            }
            model.selectProjectTab(.code)
            model.selectProjectTab(.conversation)
            guard model.selectedSessionID == reviewer.id, model.workspace.conversation(for: project.id)?.id == main.id else {
                throw DriverError("Chat selection changed when switching tabs")
            }
            try await pause(0.7)
            model.markChatRead(reviewer.id)
            if let folder = step["directory"]?.string { try snapshot(to: folder + "/chat-dark.png", title: nil) }

            let otherURL = project.url.deletingLastPathComponent().appendingPathComponent("OtherProject")
            try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
            model.addProject(at: otherURL)
            guard ProjectChat.agents(in: model.selectedProject!.id, sessions: model.workspace.sessions).isEmpty else {
                throw DriverError("An agent leaked into another project")
            }
            model.openProject(project)
            guard model.selectedSessionID == reviewer.id else { throw DriverError("Returning to the project lost the selected DM") }

            var job = ProjectSchedule(name: "Morning code review", prompt: "Review the code and report risks with file references.", agent: .codex, hours: 24)
            job.cron = "0 9 * * MON-FRI"; job.timeZoneID = "Europe/London"
            var tools = model.project(id: project.id)?.tools ?? ProjectTools()
            tools.schedules.append(job)
            try model.saveTools(tools, for: project)
            let scheduledTime = model.project(id: project.id)!.tools!.schedules[0].nextRun
            try await model.runJobNow(job.id, projectID: project.id)
            do {
                try await model.runJobNow(job.id, projectID: project.id)
                throw DriverError("A job launched overlapping agents")
            } catch is AgentError { }
            guard let live = model.project(id: project.id)?.tools?.schedules.first, live.runs.count == 1,
                  live.nextRun == scheduledTime else { throw DriverError("Run now changed cadence or created duplicate runs") }
            try await pause(0.9)
            model.updateProject(project.id) { current in current.tools?.schedules[0].nextRun = .distantPast }
            await model.runSchedules()
            await model.runSchedules()
            guard model.project(id: project.id)?.tools?.schedules.first?.runs.count == 2 else {
                throw DriverError("Missed scheduled job did not catch up exactly once")
            }
            try await pause(0.9)
            try await run(["op": "clickMarker", "name": "chat-open-jobs"], model)
            if let folder = step["directory"]?.string { try snapshot(to: folder + "/jobs-dark.png", title: nil) }
            try await run(["op": "clickMarker", "name": "jobs-create"], model)
            if let folder = step["directory"]?.string { try snapshot(to: folder + "/job-editor.png", title: nil, sheet: true) }
            try await run(["op": "clickMarker", "name": "job-editor-cancel"], model)
            try await run(["op": "clickMarker", "name": "chat-open-jobs"], model)
            NSApp.appearance = NSAppearance(named: .aqua)
            window()?.setContentSize(NSSize(width: 860, height: 760))
            try await pause(0.5)
            if let folder = step["directory"]?.string { try snapshot(to: folder + "/chat-compact.png", title: nil) }
            guard await model.save() else { throw DriverError("Chat and jobs did not save") }
            log("Project chat passed: native agent selection, unread replies, mention delivery, drafts, tab/project isolation, cron run now, overlap prevention and one missed-run catch-up")
        }

        static func decision(_ step: JSONValue, _ request: ApprovalRequest) -> ApprovalDecision {
            switch step["decision"]?.string {
            case "deny": .deny
            case "answers": answers(request)
            case "plan": .approvePlan(then: .acceptEdits)
            case "feedback": .denyWithFeedback(step["text"]?.string ?? "")
            default: .allow()
            }
        }

        private static func answers(_ request: ApprovalRequest) -> ApprovalDecision {
            guard case .questions(let questions) = request.kind else { return .allow() }
            return .answers(
                Dictionary(uniqueKeysWithValues: questions.map { ($0.id, [$0.options.first?.label ?? "yes"]) }))
        }

        static func waitFor(_ what: String, _ model: AppModel, timeout: Double, approving: Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let session = try await current(model)
                if approving, let request = session.pendingApproval { session.answer(request, with: .allow()) }
                switch what {
                case "approval": if session.pendingApproval != nil { return }
                case "idle": if !session.isBusy, session.hasStarted { return }
                case "agents": if model.statuses[session.meta.agent]?.readiness == .ready { return }
                default: break
                }
                try await pause(0.05)
            }
            throw DriverError("timed out waiting for \(what)")
        }

        static func testNavigationLinks(_ step: JSONValue, _ model: AppModel) async throws {
            guard let project = model.selectedProject else { throw DriverError("No project") }
            model.showCode()
            let editor = model.editor(for: project)
            await editor.open("main.go"); editor.focusEditor(); try await pause(0.4)
            guard let document = editor.selectedDocument, let content = window()?.contentView,
                  let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }),
                  let assistance = view.inlineAssistant else { throw DriverError("No editor assistance") }
            view.applyAssistanceText(view.string + "\n// unsaved navigation test\n", selection: NSRange(location: 0, length: 0), action: "Test draft")
            let offset = (view.string as NSString).range(of: "Greet").location + 2
            view.setSelectedRange(NSRange(location: offset, length: 0))
            assistance.requestNavigation(at: offset)
            for _ in 0..<300 { if assistance.isNavigationVisible { break }; try await pause(0.05) }
            guard assistance.isNavigationVisible, assistance.navigation.locations.first?.path == "helpers.go", editor.selectedDocumentID == document.id,
                  document.isModified else { throw DriverError("Definition peek did not preserve the source draft") }
            if let folder = step["directory"]?.string { try await run(["op": "editorPopoverShot", "name": "code-navigation-preview", "path": .string(folder + "/definition-peek.png")], model) }
            assistance.dismiss()
            let screen = view.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: nil)
            let point = view.window!.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .command, timestamp: 0,
                windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            view.mouseDown(with: click)
            for _ in 0..<200 { if editor.selectedDocument?.path == "helpers.go" { break }; try await pause(0.05) }
            guard editor.selectedDocument?.path == "helpers.go" else { throw DriverError("Command-click did not open the definition") }
            editor.goBack(); try await pause(0.2)
            guard editor.selectedDocumentID == document.id, document.text.contains("unsaved navigation test") else { throw DriverError("Back navigation lost the source or draft") }
            assistance.requestNavigation(at: offset, references: true)
            for _ in 0..<200 { if assistance.isNavigationVisible { break }; try await pause(0.05) }
            guard assistance.navigation.locations.count >= 2 else { throw DriverError("Reference preview did not return both source locations") }
            assistance.dismiss()
            model.openTerminal(); try await pause(0.8)
            guard let terminalView = model.projectRuntimeTools[project.id]?.terminal?.current?.view, let terminalWindow = terminalView.window else { throw DriverError("No terminal view") }
            terminalView.feed(text: "\u{1B}[2J\u{1B}[Hhelpers.go:4:2: example compiler error\r\n")
            try await pause(0.2)
            let rowHeight = terminalView.getOptimalFrameSize().height / CGFloat(terminalView.getTerminal().rows)
            let cellWidth = terminalView.font.advancement(forGlyph: terminalView.font.glyph(withName: "W")).width
            let location = terminalView.convert(NSPoint(x: cellWidth * 3.5, y: terminalView.bounds.maxY - rowHeight * 0.5), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: terminalWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                NSApp.postEvent(event, atStart: false)
            }
            for _ in 0..<100 { if model.layout(for: project.id).panel == .code && editor.selectedDocument?.path == "helpers.go" { break }; try await pause(0.05) }
            guard model.layout(for: project.id).panel == .code, editor.selectedDocument?.path == "helpers.go", editor.selectedDocument?.line == 4 else { throw DriverError("Clicking terminal output did not open the exact source line") }
            log("Native definition preview, command-click, reference results, draft-preserving history, and terminal file links passed")
        }

        static func testMCPOAuth(_ step: JSONValue, _ model: AppModel) async throws {
            guard let project = model.selectedProject, let address = step["url"]?.string, let folder = step["directory"]?.string else { throw DriverError("OAuth fixture missing") }
            model.mcpAccounts = MCPAccounts(credentials: MCPCredentials(vault: DebugMCPVault()))
            model.mcpAccounts.openAuthorizationURL = { url in
                let (_, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DriverError("OAuth callback did not complete") }
            }
            var tools = project.tools ?? ProjectTools()
            tools.mcpConfig = String(decoding: try JSONValue.object(["mcpServers": ["authorized": ["url": .string(address)]]]).serialized(), as: UTF8.self)
            try model.saveTools(tools, for: project)
            model.openProjectSettings(project, section: "MCP"); try await pause(0.4)
            try await run(["op": "clickMarker", "name": "mcp-sign-in-authorized"], model)
            for _ in 0..<240 {
                if NSApp.windows.contains(where: { $0.contentView.flatMap { marker(in: $0, named: "mcp-connected-authorized") } != nil }) { break }
                try await pause(0.05)
            }
            guard !model.mcpAccounts.signedIn.isEmpty, NSApp.windows.contains(where: { $0.contentView.flatMap { marker(in: $0, named: "mcp-connected-authorized") } != nil }) else {
                throw DriverError("OAuth UI failed: " + model.mcpAccounts.errors.values.joined(separator: ", "))
            }
            try await run(["op": "captureMarker", "name": "mcp-connections", "path": .string(folder + "/mcp-signed-in.png")], model)
            try await run(["op": "clickMarker", "name": "project-tools-save"], model)
            guard let saved = model.project(id: project.id)?.tools?.mcpConfig, !saved.contains("fixture-access"), !saved.contains("fixture-refresh"), saved.contains("marikaOAuthID") else { throw DriverError("OAuth credentials leaked into project settings") }
            log("Native MCP browser sign-in, discovery, authorized connection, and secret-free project settings passed")
        }

        static func testMCPManager(_ step: JSONValue, _ model: AppModel) async throws {
            guard let project = model.selectedProject, let fixture = step["fixture"]?.string,
                  let directory = step["directory"]?.string else { throw DriverError("MCP test fixture missing") }
            var tools = project.tools ?? ProjectTools()
            let config: JSONValue = ["mcpServers": ["local_tools": ["command": "/usr/bin/python3", "args": [.string(fixture), "stdio", .string(directory + "/requests.jsonl")], "startup_timeout_sec": 25]]]
            tools.mcpConfig = String(decoding: try config.serialized(), as: UTF8.self)
            try model.saveTools(tools, for: project)
            model.openProjectSettings(project, section: "MCP"); try await pause(0.5)
            try await run(["op": "clickMarker", "name": "mcp-toggle-local_tools"], model)
            try await run(["op": "clickMarker", "name": "project-tools-save"], model)
            let disabled = try ProjectMCP.servers(model.project(id: project.id)!.tools!.mcpConfig)
            guard disabled["local_tools"]?["disabled"]?.bool == true else { throw DriverError("MCP disabled state did not persist") }
            model.openProjectSettings(project, section: "MCP"); try await pause(0.4)
            try await run(["op": "clickMarker", "name": "mcp-toggle-local_tools"], model)
            try await run(["op": "clickMarker", "name": "mcp-test-local_tools"], model)
            for _ in 0..<100 {
                if NSApp.windows.contains(where: { $0.contentView.flatMap { marker(in: $0, named: "mcp-connected-local_tools") } != nil }) { break }
                try await pause(0.05)
            }
            guard NSApp.windows.contains(where: { $0.contentView.flatMap { marker(in: $0, named: "mcp-connected-local_tools") } != nil }) else { throw DriverError("MCP UI did not show a successful connection") }
            try await run(["op": "captureMarker", "name": "mcp-connections", "path": .string(directory + "/mcp-manager.png")], model)
            try await run(["op": "clickMarker", "name": "mcp-edit-local_tools"], model)
            try await run(["op": "captureMarker", "name": "mcp-server-editor", "path": .string(directory + "/mcp-edit.png")], model)
            guard let sheet = NSApp.windows.first(where: { $0.contentView.flatMap { marker(in: $0, named: "mcp-server-editor") } != nil }),
                  let content = sheet.contentView, let field = textField(in: content, placeholder: "Server name") else { throw DriverError("MCP name field missing") }
            sheet.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { throw DriverError("MCP name editor missing") }
            editor.selectAll(nil); editor.insertText("project_tools", replacementRange: editor.selectedRange())
            sheet.makeFirstResponder(nil); try await pause(0.15)
            try await run(["op": "clickMarker", "name": "mcp-save-server"], model)
            try await run(["op": "clickMarker", "name": "project-tools-save"], model)
            let saved = try ProjectMCP.servers(model.project(id: project.id)!.tools!.mcpConfig)
            guard saved["local_tools"] == nil, saved["project_tools"]?["startup_timeout_sec"]?.int == 25,
                  saved["project_tools"]?["disabled"]?.bool != true else { throw DriverError("MCP edit lost the name, options, or enabled state") }
            model.openProjectSettings(project, section: "MCP"); try await pause(0.3)
            try await run(["op": "clickMarker", "name": "mcp-add-server"], model)
            guard NSApp.windows.contains(where: { $0.contentView.flatMap { marker(in: $0, named: "mcp-server-editor") } != nil }) else { throw DriverError("Add server did not open the editor") }
            log("Native MCP manager, per-project toggle persistence, connection discovery, rename, option preservation and add-server form passed")
        }

        static func testInlineReview(_ step: JSONValue, _ model: AppModel) async throws {
            guard let project = model.selectedProject else { throw DriverError("No project") }
            model.agentFactoryOverride = { _ in DebugTaskAgent(seconds: 0.2) }
            let agent = try await model.launchAgent(in: project, agent: .codex, settings: AgentSettings(), prompt: "Refine the calculator implementation", isolated: true)
            for _ in 0..<200 { if !agent.isBusy { break }; try await pause(0.05) }
            guard let workspace = agent.meta.agentTask?.workspace else { throw DriverError("No isolated workspace") }
            let path = project.url.appendingPathComponent("calc.go")
            let original = try String(contentsOf: path, encoding: .utf8)
            let changed = original.replacingOccurrences(of: "return a + b", with: "sum := a + b\n    return sum").replacingOccurrences(of: "return \"original\"", with: "return \"proposed\"")
            try changed.write(to: URL(fileURLWithPath: workspace.workingPath).appendingPathComponent("calc.go"), atomically: true, encoding: .utf8)
            let editor = model.editor(for: project)
            await editor.open("calc.go")
            guard let document = editor.selectedDocument else { throw DriverError("No code document") }
            document.text = original + "// unsaved user work\n"
            await model.openAgentReview(agent.id)
            guard let review = model.agentReviews[project.id], review.hunks.count == 2 else { throw DriverError("Expected two independent review hunks") }
            try await pause(0.3)
            let first = review.hunks[0]
            await review.decide(.accept, hunk: first)
            guard review.error?.contains("Save or discard") == true, document.isModified,
                  try String(contentsOf: path, encoding: .utf8) == original else { throw DriverError("An unsaved draft was not protected") }
            document.text = original
            await review.refresh(); try await pause(0.2)
            if let folder = step["directory"]?.string { try snapshot(to: folder + "/review-dark.png", title: nil) }
            guard let window = window(), let content = window.contentView,
                  let tests = marker(in: content, named: "agent-review-tests") else { throw DriverError("Test action missing from review") }
            try click(tests, in: window); try await pause(0.3)
            for _ in 0..<400 { if !review.testsRunning { break }; try await pause(0.05) }
            guard review.testResult?.succeeded == true else { throw DriverError("Review tests failed: " + (review.testError ?? review.testResult?.output ?? "No result")) }
            guard let nextHunk = review.hunks.first else { throw DriverError("No first hunk") }
            let acceptID = nextHunk.id
            try await run(["op": "clickMarker", "name": .string("agent-review-accept-" + acceptID)], model)
            for _ in 0..<100 { if review.hunks.count == 1 && !review.busy { break }; try await pause(0.05) }
            let partial = try String(contentsOf: path, encoding: .utf8)
            guard review.hunks.count == 1, partial.contains("sum := a + b"), partial.contains("return \"original\"") else { throw DriverError("Accepting one hunk applied the wrong changes: " + (review.error ?? "")) }
            if let folder = step["directory"]?.string { try snapshot(to: folder + "/review-partial.png", title: nil) }
            guard let remaining = review.hunks.first else { throw DriverError("No remaining hunk") }
            try await run(["op": "clickMarker", "name": .string("agent-review-reject-" + remaining.id)], model)
            for _ in 0..<100 { if review.hunks.isEmpty && !review.busy { break }; try await pause(0.05) }
            guard review.hunks.isEmpty, review.accepted == 1, review.rejected == 1 else { throw DriverError("Review decisions were not retained") }
            let isolated = try String(contentsOf: URL(fileURLWithPath: workspace.workingPath).appendingPathComponent("calc.go"), encoding: .utf8)
            guard isolated == partial else { throw DriverError("Rejected hunk remained in agent worktree") }
            await review.refresh()
            guard review.hunks.isEmpty else { throw DriverError("Resolved changes reappeared on refresh") }
            review.feedback = "Keep the Label result unchanged and preserve the public API."
            review.beginFeedback(remaining)
            await review.sendFeedback()
            guard agent.items.contains(where: { item in
                if case .user(let text, _) = item.content { return text.contains("Keep the Label result unchanged") && text.contains("calc.go") }
                return false
            }) else { throw DriverError("Feedback was not sent to the reviewed agent") }
            for _ in 0..<200 { if !agent.isBusy { break }; try await pause(0.05) }
            await review.refresh()
            guard review.hunks.isEmpty else { throw DriverError("Feedback reset the review baseline") }
            review.close()
            guard !review.isOpen, document.text == partial else { throw DriverError("Returning to the editor lost the accepted changes") }
            log("Native inline diff, draft protection, package tests, per-hunk accept/reject, refresh persistence, and targeted agent feedback passed")
        }

        static func testInlineAssistance(_ step: JSONValue, _ model: AppModel) async throws {
            guard let project = model.selectedProject else { throw DriverError("No project") }
            model.showCode()
            let editor = model.editor(for: project)
            await editor.open("main.go"); editor.focusEditor(); try await pause(0.3)
            guard let document = editor.selectedDocument, let content = window()?.contentView,
                  let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }),
                  let assistant = view.inlineAssistant else { throw DriverError("Inline assistance did not mount") }
            let ide = model.ide(for: project, editor: editor), original = view.string
            await ide.synchronize(document)
            let token = (view.string as NSString).range(of: "Println")
            guard token.location != NSNotFound else { throw DriverError("Missing completion fixture") }
            view.setSelectedRange(token)
            view.insertText("Pr", replacementRange: token)
            let beforeCompletion = view.string
            for _ in 0..<300 { if assistant.isCompletionVisible { break }; try await pause(0.05) }
            guard assistant.isCompletionVisible, window()?.firstResponder === view,
                  let item = assistant.list.completions.firstIndex(where: { $0.label.hasPrefix("Printf") }) else {
                throw DriverError("Automatic Go completion did not appear: " + assistant.list.completions.map(\.label).joined(separator: ", "))
            }
            assistant.list.selected = item
            if let folder = step["directory"]?.string {
                try await run(["op": "editorPopoverShot", "name": "code-assist-list", "path": .string(folder + "/autocomplete.png")], model)
            }
            guard let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window()?.windowNumber ?? 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else { throw DriverError("No Tab event") }
            view.keyDown(with: tab)
            for _ in 0..<100 { if view.string.contains("fmt.Printf") { break }; try await pause(0.05) }
            guard view.string.contains("fmt.Printf"), !view.string.contains("PrPrintf") else { throw DriverError("Completion did not replace the prefix") }
            view.undoManager?.undo(); try await pause(0.15)
            guard view.string == beforeCompletion else { throw DriverError("Completion undo lost the typed prefix; expected \(beforeCompletion.debugDescription), got \(view.string.debugDescription)") }
            assistant.dismiss()
            view.applyAssistanceText(original, selection: NSRange(location: 0, length: 0), action: "Restore fixture")
            await ide.synchronize(document)
            let hoverOffset = (original as NSString).range(of: "func greet").location + 6
            let hover = try await ide.hover(in: document, text: original, offset: hoverOffset)
            guard hover?.text.contains("greet") == true else { throw DriverError("The Go server returned no hover documentation") }
            try await pause(0.35)
            assistant.requestHover(at: hoverOffset)
            for _ in 0..<200 { if assistant.isInformationVisible { break }; try await pause(0.05) }
            guard assistant.isInformationVisible, assistant.info.text.contains("greet") else { throw DriverError("Go hover card missing: \(assistant.info.text)") }
            if let folder = step["directory"]?.string {
                try await run(["op": "editorPopoverShot", "name": "code-assist-information", "path": .string(folder + "/hover.png")], model)
            }
            assistant.dismiss()
            let call = (original as NSString).range(of: "greet(\"Marika\")")
            // gopls intentionally hides signature help inside string literals.
            view.setSelectedRange(NSRange(location: call.location + 5, length: 0))
            try await pause(0.2)
            assistant.requestSignature(delay: false)
            for _ in 0..<200 { if assistant.isInformationVisible { break }; try await pause(0.05) }
            guard assistant.info.kind == .signature, assistant.info.signature?.label.contains("greet") == true else { throw DriverError("Function signature missing") }
            if let folder = step["directory"]?.string {
                try await run(["op": "editorPopoverShot", "name": "code-assist-information", "path": .string(folder + "/signature.png")], model)
            }
            assistant.dismiss()
            let unused = "package main\n\nfunc main() {\n    fmt.Println(\"Hello\")\n}\n"
            view.applyAssistanceText(unused, selection: NSRange(location: (unused as NSString).range(of: "fmt").location, length: 0), action: "Quick fix fixture")
            await ide.synchronize(document)
            for _ in 0..<300 { if ide.diagnostics[document.path]?.contains(where: { $0["message"]?.string?.contains("undefined: fmt") == true }) == true { break }; try await pause(0.05) }
            assistant.requestFixes()
            for _ in 0..<200 { if !assistant.list.loading { break }; try await pause(0.05) }
            guard let fix = assistant.list.fixes.first else { throw DriverError("No real Go quick fix: " + assistant.list.text) }
            if let folder = step["directory"]?.string {
                try await run(["op": "editorPopoverShot", "name": "code-assist-list", "path": .string(folder + "/quick-fixes.png")], model)
                try snapshot(to: folder + "/diagnostic-editor.png", title: nil)
            }
            try await run(["op": "clickMarker", "name": "code-assist-choice-0"], model)
            for _ in 0..<200 { if view.string != unused { break }; try await pause(0.05) }
            guard view.string != unused else { throw DriverError("Quick fix was not applied to the editor draft") }
            var staleApplied = false
            do {
                try await ide.apply(fix, in: document) { _ in staleApplied = true }
                throw DriverError("Stale quick fix was accepted")
            } catch is AgentError { }
            guard !staleApplied else { throw DriverError("Stale action changed the document") }
            view.undoManager?.undo(); try await pause(0.15)
            guard view.string == unused else { throw DriverError("Quick fix could not be undone") }
            assistant.dismiss()
            view.applyAssistanceText(original, selection: NSRange(location: 0, length: 0), action: "Restore fixture")
            log("Real Go autocomplete with Tab and undo, hover docs, signatures, inline quick fixes, and stale-action protection passed")
        }

        static func testProjectTabs(_ step: JSONValue, _ model: AppModel) async throws {
            guard let project = model.selectedProject, let sourceID = model.selectedSessionID,
                  let other = model.workspace.projects.first(where: { $0.id != project.id }), let main = window() else {
                throw DriverError("Two fixture projects are required")
            }
            guard model.layout(for: project.id).openTabs == [.conversation] else { throw DriverError("A new project should start with Chat only") }
            model.agentFactoryOverride = { _ in DebugTaskAgent(seconds: 60) }
            let source = try await current(model)
            source.send(UserInput(text: "Project tabs fixture."))
            for _ in 0..<60 { if source.isBusy { break }; try await pause(0.05) }
            source.draft = "Keep this chat draft when closing tools."
            let editor = model.editor(for: project)
            await editor.open("README.md")
            guard let document = editor.selectedDocument else { throw DriverError("Fixture file did not open") }
            document.text += "\nUnsaved tab test.\n"
            let draft = document.text

            main.setContentSize(NSSize(width: 900, height: 600))
            model.showsInspector = true
            try await pause(0.3)
            guard let root = main.contentView, let header = marker(in: root, named: "workspace-header"),
                  let addView = marker(in: root, named: "workspace-new-view"), abs(header.bounds.height - WorkspaceHeader.height) < 1,
                  header.convert(header.bounds, to: nil).contains(addView.convert(addView.bounds, to: nil)),
                  marker(in: root, named: "workspace-view-shortcuts") == nil else {
                throw DriverError("Single-row navigation is missing or clipped")
            }
            if let directory = step["directory"]?.string {
                try snapshot(to: directory + "/project-views-narrow-inspector.png", title: nil)
            }
            try await run(["op": "shortcut", "key": "2", "exactMenu": true], model)
            try await run(["op": "shortcut", "key": "0", "exactMenu": true], model)
            try await run(["op": "shortcut", "key": "2", "exactMenu": true], model)
            model.showsInspector = false
            main.setContentSize(NSSize(width: 1240, height: 820))
            try await pause(0.3)
            guard model.layout(for: project.id).openTabs == [.conversation, .code, .research] else { throw DriverError("Opening an existing tool duplicated its tab") }
            try await run(["op": "projectTabClick", "tab": "research"], model)
            try await pause(0.2)
            try await run(["op": "clickMarker", "name": "workspace-close-code"], model)
            guard model.layout(for: project.id).panel == .research,
                  model.layout(for: project.id).openTabs == [.conversation, .research], document.text == draft, document.isModified else {
                throw DriverError("Closing an inactive Code tab changed the selection or lost the file draft")
            }
            try await run(["op": "shortcut", "key": "2", "exactMenu": true], model)
            try await pause(0.2)
            guard editor.selectedDocument?.id == document.id else { throw DriverError("Reopening Code lost the open editor") }
            try await run(["op": "clickMarker", "name": "workspace-close-code"], model)
            guard model.layout(for: project.id).panel == .research else { throw DriverError("Closing the active tab did not select its neighbor") }
            try await run(["op": "shortcut", "key": "4", "exactMenu": true], model)
            try await pause(0.2)
            try await run(["op": "clickMarker", "name": "workspace-close-agents"], model)
            guard source.isBusy else { throw DriverError("Closing Agents interrupted its running agent") }
            try await run(["op": "shortcut", "key": "3", "exactMenu": true], model)
            model.setSplit(.code)
            try await pause(0.2)
            guard model.layout(for: project.id).openTabs.contains(.code) else { throw DriverError("Split tools must have a tab") }
            try await run(["op": "clickMarker", "name": "workspace-close-code"], model)
            guard model.layout(for: project.id).panel == .browser, model.layout(for: project.id).secondary == nil else { throw DriverError("Closing a split tab left an inaccessible pane") }
            try await run(["op": "clickMarker", "name": "workspace-close-browser"], model)
            model.showCode()
            model.moveProjectTab(.code, offset: -1)
            guard model.layout(for: project.id).openTabs == [.conversation, .code, .research] else { throw DriverError("Tab order was not updated") }
            model.closeOtherProjectTabs(keeping: .code)
            guard model.layout(for: project.id).openTabs == [.conversation, .code] else { throw DriverError("Close Other Tabs did not keep Chat and the chosen tab") }
            try await pause(0.2)
            try await run(["op": "projectTabClick", "tab": "conversation"], model)
            try await pause(0.2)
            guard model.selectedSessionID == sourceID, source.draft == "Keep this chat draft when closing tools." else { throw DriverError("Tool tabs changed the project's chat or draft") }
            model.openProject(other)
            guard model.layout(for: other.id).openTabs == [.conversation] else { throw DriverError("Projects shared their tool tabs") }
            model.switchPanel(.browser)
            model.openProject(project)
            guard model.layout(for: project.id).openTabs == [.conversation, .code],
                  editor.documents.contains(where: { $0.id == document.id && $0.text == draft && $0.isModified }), source.isBusy else { throw DriverError("Project switching lost tabs or active work") }
            source.interrupt()
            model.switchPanel(.stats)
            if let directory = step["directory"]?.string {
                NSApp.appearance = NSAppearance(named: .darkAqua)
                main.setContentSize(NSSize(width: 1240, height: 820))
                try await pause(0.3)
                try snapshot(to: directory + "/project-tabs-dark.png", title: nil)
                NSApp.appearance = NSAppearance(named: .aqua)
                main.setContentSize(NSSize(width: 900, height: 600))
                try await pause(0.3)
                try snapshot(to: directory + "/project-tabs-light-compact.png", title: nil)
            }
            guard await model.save() else { throw DriverError("Project tabs could not be saved") }
            log("Project tabs: single-row navigation at narrow widths, open/reuse, native select/close, split cleanup, running agent and unsaved editor preservation, ordering and per-project state passed")
        }

        static func editSpaceUI(name: String, color: String, editing id: UUID? = nil, model: AppModel) async throws {
            guard let main = window() else { throw DriverError("No main window") }
            main.makeKeyAndOrderFront(nil)
            main.contentView?.layoutSubtreeIfNeeded()
            if let id { model.showSpaceEditor(id); try await pause(0.3) }
            else { try await run(["op": "clickMarker", "name": "space-create"], model) }
            for _ in 0..<40 where main.attachedSheet == nil { try await pause(0.05) }
            guard let sheet = main.attachedSheet, let root = sheet.contentView,
                  let field = textField(in: root, placeholder: "e.g. Product, Personal, Research") else { throw DriverError("Space editor did not open") }
            sheet.makeFirstResponder(field)
            guard let input = field.currentEditor() as? NSTextView else { throw DriverError("Space name is not editable") }
            input.insertText(name, replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
            try await run(["op": "clickMarker", "name": .string("space-color-" + color)], model)
            try await run(["op": "clickMarker", "name": "space-editor-save"], model)
            for _ in 0..<60 { if main.attachedSheet == nil { break }; try await pause(0.05) }
            guard main.attachedSheet == nil else { throw DriverError("Space editor did not save and close") }
        }

        static func testSpaces(_ step: JSONValue, _ model: AppModel) async throws {
            guard let original = model.selectedProject, let source = model.selectedSession,
                  let other = model.workspace.projects.first(where: { $0.id != original.id }),
                  let main = window(), let root = main.contentView else { throw DriverError("Two fixture projects are required") }
            let personal = model.selectedSpace.id, originalSessions = model.workspace.sessions.count
            let editor = model.editor(for: original)
            await editor.open("README.md")
            guard let document = editor.selectedDocument else { throw DriverError("Fixture document did not open") }
            document.text += "\nUnsent editor work.\n"
            let edited = document.text
            model.agentFactoryOverride = { _ in DebugTaskAgent(seconds: 60) }
            await model.open(source.id)
            guard let controller = model.controllers[source.id] else { throw DriverError("Fixture controller did not open") }
            controller.send(UserInput(text: "Space-switching fixture."))
            for _ in 0..<60 { if controller.isBusy { break }; try await pause(0.05) }
            controller.draft = "Keep this Personal draft."
            try await editSpaceUI(name: "Work", color: "teal", model: model)
            guard let work = model.workspace.spaces.first(where: { $0.name == "Work" }), work.color == .teal,
                  model.selectedSpace.id == work.id, model.selectedSessionID == nil,
                  marker(in: root, named: "space-empty") != nil else { throw DriverError("New empty space did not become active") }
            guard controller.isBusy, document.isModified, document.text == edited else { throw DriverError("Creating a space interrupted work") }
            guard model.moveProject(other.id, toSpace: work.id) else { throw DriverError("Project did not move to Work") }
            try await pause(0.2)
            try await run(["op": "projectClick", "name": .string(other.name)], model)
            for _ in 0..<60 { if model.selectedProject?.id == other.id { break }; try await pause(0.05) }
            guard let otherSessionID = model.selectedSessionID, model.selectedProject?.id == other.id else {
                throw DriverError("Moved project's row did not open its conversation")
            }
            await model.open(otherSessionID)
            model.controllers[otherSessionID]?.draft = "Keep this Work draft."
            guard model.spaceProjects.map(\.id) == [other.id],
                  marker(in: root, named: "project-row-" + original.id.uuidString) == nil else { throw DriverError("Space leaked another space's project row") }
            try await run(["op": "spaceSwitch", "name": "Personal"], model)
            guard model.selectedSessionID == source.id, controller.draft == "Keep this Personal draft.",
                  controller.isBusy, editor.documents.contains(where: { $0.id == document.id && $0.text == edited && $0.isModified })
            else { throw DriverError("Switching spaces lost the selected chat, draft, agent, or editor buffer") }
            try await run(["op": "spaceSwitch", "name": "Work"], model)
            guard model.selectedProject?.id == other.id,
                  model.selectedSessionID.flatMap({ model.controllers[$0]?.draft }) == "Keep this Work draft." else { throw DriverError("Work did not restore its own conversation") }
            try await editSpaceUI(name: "Studio", color: "violet", editing: work.id, model: model)
            guard model.selectedSpace.name == "Studio", model.selectedSpace.color == .violet,
                  model.spaceProjects.map(\.id) == [other.id] else { throw DriverError("Editing space appearance changed its projects") }
            model.reorderSpace(work.id, offset: -1)
            guard model.workspace.spaces.first?.id == work.id, model.selectedSpace.id == work.id else { throw DriverError("Reordering changed the active space") }
            model.reorderSpace(work.id, offset: 1)

            func menuItem(_ menu: NSMenu, title: String) -> NSMenuItem? {
                menu.delegate?.menuNeedsUpdate?(menu); menu.update()
                for item in menu.items {
                    if item.title == title { return item }
                    if let submenu = item.submenu, let found = menuItem(submenu, title: title) { return found }
                }
                return nil
            }
            for (title, expected) in [("Previous Space", personal), ("Next Space", work.id)] {
                guard let menu = NSApp.mainMenu, let item = menuItem(menu, title: title),
                      item.keyEquivalentModifierMask == [.control, .option], let action = item.action,
                      NSApp.sendAction(action, to: item.target, from: item) else { throw DriverError("Space navigation menu missing") }
                try await pause(0.2)
                guard model.selectedSpace.id == expected else { throw DriverError("Space navigation menu chose the wrong space") }
            }
            try await editSpaceUI(name: "Temporary", color: "rose", model: model)
            let temporary = model.selectedSpace.id
            model.deleteSpace(temporary, movingProjectsTo: work.id)
            try await pause(0.2)
            guard model.workspace.spaces.count == 2, model.selectedSpace.id == work.id,
                  model.workspace.projects.count == 2, model.workspace.sessions.count == originalSessions,
                  controller.isBusy else { throw DriverError("Deleting a space lost projects, chats, or running agents") }
            controller.interrupt()
            if let directory = step["directory"]?.string {
                try snapshot(to: directory + "/spaces-dark.png", title: nil)
                NSApp.appearance = NSAppearance(named: .aqua)
                main.setContentSize(NSSize(width: 900, height: 600))
                try await pause(0.3)
                try snapshot(to: directory + "/spaces-light-compact.png", title: nil)
            }
            guard await model.save() else { throw DriverError("Spaces could not be saved") }
            log("Spaces: native creation, editing and switching; scoped projects; menu navigation; live agent and draft preservation; reorder, delete and save passed")
        }

        static func testChatHistoryUpdates(_ step: JSONValue, _ model: AppModel) async throws {
            let directory = step["directory"]?.string ?? NSTemporaryDirectory()
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            guard let source = model.selectedSession,
                  let target = model.workspace.sessions.first(where: { $0.projectID != source.projectID }),
                  let rootWindow = window(), let root = rootWindow.contentView else { throw DriverError("Two fixture projects are required") }
            await model.open(source.id)
            model.controllers[source.id]?.draft = "Preserve this unsent project draft."
            let items = (0..<180).map { index in
                TranscriptItem(id: "history-\(index)", date: Date(timeIntervalSince1970: Double(1_700_000_000 + index)),
                    content: .assistant(text: index == 1 ? "History needle: the old routing decision was to preserve drafts." : "Ordinary message \(index)."))
            }
            try await model.store.saveTranscript(items, for: target.id)
            let before = model.controllers.count
            try await run(["op": "clickMarker", "name": "chat-open-history-search"], model)
            guard let sheet = rootWindow.attachedSheet, let content = sheet.contentView,
                  let field = textField(in: content, placeholder: "Search all conversations…") else { throw DriverError("History search sheet missing") }
            sheet.makeFirstResponder(field)
            guard let input = field.currentEditor() as? NSTextView else { throw DriverError("Search field is not editable") }
            input.insertText("history needle", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
            for _ in 0..<100 {
                if marker(in: content, named: "chat-history-result-history-1") != nil { break }
                try await pause(0.05)
            }
            guard model.controllers.count == before,
                  let result = marker(in: content, named: "chat-history-result-history-1") else { throw DriverError("Search did not find saved history without loading agents") }
            try snapshot(to: directory + "/history-results.png", title: nil, sheet: true)
            try click(result, in: sheet)
            for _ in 0..<100 {
                if model.selectedSessionID == target.id, marker(in: root, named: "chat-history-target") != nil { break }
                try await pause(0.05)
            }
            try await pause(0.4)
            guard model.selectedSessionID == target.id, model.chatHistoryFocus?.itemID == "history-1",
                  model.selectedSpace.id == model.project(for: target)?.spaceID,
                  let destination = marker(in: root, named: "chat-history-target"),
                  let clip = destination.enclosingScrollView?.contentView else { throw DriverError("Search did not reveal the older message") }
            let rect = destination.convert(destination.bounds, to: nil)
            let viewport = clip.convert(clip.bounds, to: nil)
            guard rect.intersects(viewport) else { throw DriverError("The matching message is outside the viewport: \(rect), viewport \(viewport)") }
            guard model.controllers[source.id]?.draft == "Preserve this unsent project draft." else { throw DriverError("Search changed another chat's draft") }
            try snapshot(to: directory + "/history-destination.png", title: nil)
            try await run(["op": "clickMarker", "name": "transcript-latest"], model)
            guard model.chatHistoryFocus == nil else { throw DriverError("Latest did not leave history navigation") }
            // Verify the native menu and its shortcut binding here. The actual shifted
            // key is also checked in the foreground app; headless NSMenu key dispatch
            // otherwise routes a synthetic H event to the system Hide command.
            guard let historyMenu = NSApp.mainMenu,
                  let history = findMenuItem(historyMenu, title: "Search Chat History…"),
                  history.keyEquivalent.lowercased() == "h", history.keyEquivalentModifierMask == [.command, .shift],
                  let historyAction = history.action, NSApp.sendAction(historyAction, to: history.target, from: history)
            else { throw DriverError("History menu or shortcut binding is missing") }
            for _ in 0..<60 { if rootWindow.attachedSheet != nil { break }; try await pause(0.05) }
            guard rootWindow.attachedSheet != nil else {
                throw DriverError("History menu did not open search; presented=\(model.showsChatHistorySearch), window=\(rootWindow.title)")
            }
            try await run(["op": "key", "code": 53], model)
            try await pause(0.2)

            func findMenuItem(_ menu: NSMenu, title: String) -> NSMenuItem? {
                menu.delegate?.menuNeedsUpdate?(menu); menu.update()
                for item in menu.items {
                    if item.title == title { return item }
                    if let submenu = item.submenu, let found = findMenuItem(submenu, title: title) { return found }
                }
                return nil
            }
            guard let menu = NSApp.mainMenu, let notes = findMenuItem(menu, title: "Release Notes…"), let action = notes.action,
                  NSApp.sendAction(action, to: notes.target, from: notes) else { throw DriverError("Release Notes menu item missing") }
            for _ in 0..<60 {
                if NSApp.windows.contains(where: { $0.isVisible && $0.title == "Marika Updates" && $0.contentView.flatMap { marker(in: $0, named: "app-updates") } != nil }) { break }
                try await pause(0.05)
            }
            guard let updatesWindow = NSApp.windows.first(where: { $0.isVisible && $0.title == "Marika Updates" && $0.contentView.flatMap { marker(in: $0, named: "app-updates") } != nil }) else {
                throw DriverError("Updates window did not open")
            }
            updatesWindow.makeKeyAndOrderFront(nil)
            if !updatesWindow.isKeyWindow { updatesWindow.becomeKey() }
            try await pause(0.3)
            let release = PublishedRelease(version: ReleaseVersion("9.0.0")!, title: "UI fixture release",
                notes: "# A newer Marika\n\n- Search messages across projects.\n- Preserve native window controls.",
                url: URL(string: "https://github.com/junkd0g/marika/releases/tag/v9.0.0")!)
            model.updates.releaseOverride = { release }
            try await run(["op": "clickMarker", "name": "updates-check"], model)
            for _ in 0..<60 { if model.updates.status == .available { break }; try await pause(0.05) }
            guard model.updates.status == .available, model.updates.release == release else {
                throw DriverError("Update check did not show the available release: status=\(model.updates.status.rawValue), version=\(model.updates.installedVersion), window=\(updatesWindow.title)")
            }
            try snapshot(to: directory + "/updates-available.png", title: "Marika Updates")
            model.updates.releaseOverride = { nil }
            await model.updates.check()
            guard model.updates.status == .noReleases, model.updates.release == nil else { throw DriverError("No-release state is incorrect") }
            model.updates.releaseOverride = { throw URLError(.notConnectedToInternet) }
            await model.updates.check()
            guard model.updates.status == .failed, model.updates.errorMessage != nil else { throw DriverError("Update error is hidden") }
            try snapshot(to: directory + "/updates-error.png", title: "Marika Updates")
            model.updates.releaseOverride = nil
            if step["liveUpdates"]?.bool == true {
                await model.updates.check()
                guard model.updates.status != .failed else { throw DriverError("GitHub update check failed: " + (model.updates.errorMessage ?? "unknown")) }
                try snapshot(to: directory + "/updates-live.png", title: "Marika Updates")
                log("GitHub release check: " + model.updates.status.rawValue)
            } else { log("Live GitHub release check skipped; enable MARIKA_LIVE_UPDATES=1 to run it") }
            updatesWindow.close()
            log("Chat history and updates passed: cross-project local search, exact old-message jump, draft preservation, Latest, menu and shortcut binding, installed version, release notes and update states")
        }

        static func window() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        }

        static func browserMCPCall(_ request: JSONValue, browser: BrowserWorkspace, sessionID: UUID? = nil) async throws -> JSONValue {
            let executable = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("MarikaBrowserMCP")
            let config = try await browser.agentConfiguration(executable: executable, sessionID: sessionID)
            let process = LineProcess(executable: executable, arguments: [], environment: config.environment, workingDirectory: browser.root)
            try process.start()
            defer { process.terminate() }
            let timeout = Task { try? await Task.sleep(for: .seconds(35)); if !Task.isCancelled { process.terminate() } }
            defer { timeout.cancel() }
            process.write(try JSONValue.object(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2024-11-05"]]).serialized())
            process.write(try JSONValue.object(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": request]).serialized())
            process.closeInput()
            for await output in process.output {
                if case .line(let data) = output, let reply = try? JSONValue(parsing: data), reply["id"]?.int == 2 {
                    return reply["result"] ?? [:]
                }
            }
            throw DriverError("browser MCP helper exited without replying")
        }


        static func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for child in view.subviews {
                if let field = searchField(in: child) { return field }
            }
            return nil
        }

        static func textField(in view: NSView, placeholder: String) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
            for child in view.subviews {
                if let field = textField(in: child, placeholder: placeholder) { return field }
            }
            return nil
        }

        static func marker(in view: NSView, named name: String) -> NSView? {
            if view.identifier?.rawValue == name, !view.isHiddenOrHasHiddenAncestor,
               view.bounds.width > 1, view.bounds.height > 1 { return view }
            for child in view.subviews {
                if let marker = marker(in: child, named: name) { return marker }
            }
            return nil
        }

        static func click(_ view: NSView, in window: NSWindow, fractionX: CGFloat = 0.5) throws {
            let point = view.convert(NSPoint(x: view.bounds.width * fractionX, y: view.bounds.midY), to: nil)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime + 0.02, windowNumber: window.windowNumber,
                      context: nil, eventNumber: 2, clickCount: 1, pressure: 0)
            else { throw DriverError("could not create click") }
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
        }

        static func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }

        static func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }

        static func resolveAgentReferences(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text) where text.hasPrefix("$"):
                agentReferences[String(text.dropFirst())].map { .string($0.uuidString) } ?? value
            case .array(let array): .array(array.map(resolveAgentReferences))
            case .object(let object): .object(object.mapValues(resolveAgentReferences))
            default: value
            }
        }

        static func pdfView(in view: NSView) -> PDFView? {
            if let pdf = view as? PDFView { return pdf }
            return view.subviews.lazy.compactMap { pdfView(in: $0) }.first
        }

        static func snapshot(to path: String, title: String?, sheet: Bool = false) throws {
            let target = title.flatMap { title in NSApp.windows.first { title.isEmpty ? $0.title.isEmpty : $0.title.contains(title) } } ?? window()
            let capture = sheet ? target?.attachedSheet : target
            guard let view = capture?.contentView?.superview ?? capture?.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { throw DriverError("no window to capture: \(NSApp.windows.map { "\($0.title) visible=\($0.isVisible) main=\($0.canBecomeMain) bounds=\($0.contentView?.bounds ?? .zero)" })") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw DriverError("could not encode the snapshot")
            }
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    struct DebugViewMarker: NSViewRepresentable {
        let name: String
        func makeNSView(context: Context) -> NSView {
            let view = MarkerView()
            view.identifier = NSUserInterfaceItemIdentifier(name)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { view.identifier = NSUserInterfaceItemIdentifier(name) }
        private final class MarkerView: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }

    private actor DebugMCPVault: MCPCredentialVault {
        var values: [String: MCPOAuthCredential] = [:]
        func read(_ key: String) -> MCPOAuthCredential? { values[key] }
        func write(_ credential: MCPOAuthCredential?, key: String) { values[key] = credential }
    }

    actor DebugTaskAgent: AgentSession {
        nonisolated let events: AsyncStream<AgentEvent>
        private let sink: AsyncStream<AgentEvent>.Continuation
        private let seconds: Double
        private var work: Task<Void, Never>?
        private var active = false

        init(seconds: Double) {
            let stream = AsyncStream<AgentEvent>.makeStream()
            events = stream.stream
            sink = stream.continuation
            self.seconds = seconds
        }

        func send(_ input: UserInput) async throws {
            active = true
            sink.yield(.conversationStarted(id: UUID().uuidString, model: "debug-agent"))
            sink.yield(.activity("Checking project files"))
            work = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                sink.yield(.textFinished(id: UUID().uuidString, text: "Completed: \(input.text)", parentToolID: nil))
                sink.yield(.turnFinished(TurnSummary(outcome: .completed)))
                sink.yield(.phaseChanged(.idle))
                active = false
            }
        }
        func interrupt() async {
            work?.cancel()
            active = false
            sink.yield(.turnFinished(TurnSummary(outcome: .interrupted)))
            sink.yield(.phaseChanged(.idle))
        }
        func hasActiveTurn() async -> Bool { active }
        func answer(requestID: String, decision: ApprovalDecision) async {}
        func update(settings: AgentSettings) async {}
        func shutdown() async { work?.cancel(); active = false; sink.finish() }
    }
#endif
