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
        private static var agentReferences: [String: UUID] = [:]

        static func startIfRequested(delegate: AppDelegate) {
            guard let path = ProcessInfo.processInfo.environment["MARIKA_DRIVER"] else { return }
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

        private static func log(_ message: String) {
            FileHandle.standardError.write(Data("[driver] \(message)\n".utf8))
        }

        private static func pause(_ seconds: Double) async throws {
            try await Task.sleep(for: .seconds(seconds))
        }

        private static func current(_ model: AppModel) async throws -> SessionController {
            guard let id = model.selectedSessionID else { throw DriverError("no session selected") }
            await model.open(id)
            guard let session = model.controllers[id] else { throw DriverError("session did not open") }
            return session
        }

        private struct DriverError: Error, CustomStringConvertible {
            var description: String
            init(_ description: String) { self.description = description }
        }

        @MainActor private final class WindowTransition { var finished = false }

        private static func run(_ step: JSONValue, _ model: AppModel) async throws {
            switch step["op"]?.string {
            case "wait":
                try await pause(step["seconds"]?.double ?? 1)
            case "open":
                model.addProject(at: URL(fileURLWithPath: step["path"]?.string ?? ""))
            case "agent":
                let session = try await current(model)
                model.setAgent(AgentKind(rawValue: step["agent"]?.string ?? "") ?? .claude, for: session.id)
            case "settings":
                let session = try await current(model)
                var settings = session.meta.settings
                if let value = step["model"]?.string { settings.model = value }
                if let value = step["effort"]?.string { settings.effort = value }
                if let value = step["serviceTier"] { settings.serviceTier = value.string }
                if let value = step["mode"]?.string, let mode = ApprovalMode(rawValue: value) { settings.mode = mode }
                session.update(settings: settings)
            case "split":
                let panel = ProjectPanel.allCases.first { $0.rawValue.lowercased() == step["panel"]?.string?.lowercased() }
                model.setSplit(panel, stacked: step["stacked"]?.bool)
                if let project = model.selectedProject, let fraction = step["fraction"]?.double {
                    var layout = model.layout(for: project.id); layout.splitFraction = fraction
                    model.updateLayout(layout, for: project.id)
                }
            case "toolSection":
                guard let sheet = window()?.attachedSheet, let content = sheet.contentView,
                      let picker = marker(in: content, named: "project-tool-sections") else { throw DriverError("Project settings not open") }
                try click(picker, in: sheet, fractionX: (CGFloat(step["index"]?.int ?? 0) + 0.5) / 4)
                try await pause(0.2)
            case "gitStageHunk":
                guard let window = window(), let view = window.contentView,
                      let button = marker(in: view, named: "git-hunk-stage-0") else { throw DriverError("Hunk action not found") }
                try click(button, in: window)
                try await pause(0.5)
            case "terminalTest":
                guard let project = model.selectedProject else { throw DriverError("No project") }
                model.openTerminal(command: "printf 'MARIKA_TERMINAL_OK\\n'; pwd")
                try await pause(1)
                guard let output = model.terminals[project.id]?.output(), output.contains("MARIKA_TERMINAL_OK"), output.contains(project.url.lastPathComponent) else { throw DriverError("Interactive terminal output missing") }
                log("Interactive terminal passed")
            case "toolSettingsTest":
                guard let project = model.selectedProject else { throw DriverError("No project") }
                var tools = ProjectTools()
                tools.setupCommand = "printf ready > .setup-ready"
                tools.skills = [ProjectSkill(name: "Tests", instructions: "Always explain test evidence.")]
                tools.actions = [ProjectAction(name: "Status", command: "git status --short")]
                var schedule = ProjectSchedule(name: "Review", prompt: "Inspect the project", agent: .codex, hours: 24)
                schedule.nextRun = Date.distantPast
                tools.schedules = [schedule]
                try model.saveTools(tools, for: project)
                await model.runSchedules()
                await model.runSchedules()
                guard let saved = model.project(id: project.id)?.tools?.schedules.first,
                      saved.runs.count == 1, let id = saved.runs.first,
                      let workspace = model.controllers[id]?.meta.agentTask?.workspace,
                      FileManager.default.fileExists(atPath: workspace.workingPath + "/.setup-ready") else { throw DriverError("Schedule duplicated or worktree setup failed") }
                log("Scheduled run and worktree setup passed")
                model.projectSettingsID = project.id
            case "scanReview":
                guard let caller = model.selectedSession, let project = model.selectedProject else { throw DriverError("No project") }
                let measured = await model.performAgentTool(["name": "project_scan_stats"], callerID: caller.id, projectID: project.id)
                guard let scan = model.project(id: project.id)?.scans?.last else { throw DriverError(measured["content"]?[0]?["text"]?.string ?? "No scan") }
                let review = step["review"] ?? [:]
                let published = await model.performAgentTool(["name": "project_publish_scan_review", "arguments": ["scanID": .string(scan.id.uuidString), "review": .string(String(decoding: try review.serialized(), as: UTF8.self))]], callerID: caller.id, projectID: project.id)
                if published["isError"]?.bool == true { throw DriverError(published["content"]?[0]?["text"]?.string ?? "Review rejected") }
            case "statsGenerate":
                guard let window = window(), let content = window.contentView,
                      let button = marker(in: content, named: "stats-run-review") else { throw DriverError("Review button not found") }
                try click(button, in: window)
                try await pause(0.3)
                guard let project = model.selectedProject, let id = model.project(id: project.id)?.statsAgentID else { throw DriverError("Review agent missing") }
                for _ in 0..<240 where model.controllers[id]?.isBusy == true {
                    if let session = model.controllers[id], let approval = session.pendingApproval {
                        if approval.toolKind == .mcp && approval.input["serverName"]?.string == "marika_browser"
                            && (approval.title.contains("project_scan_stats") || approval.title.contains("project_publish_scan_review")) {
                            session.answer(approval, with: .allow())
                        } else { throw DriverError("Review needs input: " + approval.title) }
                    }
                    try await pause(1)
                }
                guard let scan = model.project(id: project.id)?.scans?.last, let review = scan.review else { throw DriverError("No code review was published") }
                log("review findings=\(review.findings.count) sourceLines=\(scan.inventory?.sourceLines ?? 0)")
            case "researchSection":
                model.switchPanel(.research)
                try await pause(0.2)
                guard let window = window(), let root = window.contentView,
                      let picker = marker(in: root, named: "research-sections") else { throw DriverError("Research sections not found") }
                try click(picker, in: window, fractionX: (CGFloat(step["index"]?.int ?? 0) + 0.5) / 3)
                try await pause(0.2)
            case "designToolsTest":
                let session = try await current(model)
                guard let project = model.selectedProject, let design = step["design"]?.string else { throw DriverError("Design fixture missing") }
                let read = await model.performAgentTool(["name": "project_get_design"], callerID: session.id, projectID: project.id)
                let snapshot = try JSONValue(parsing: Data((read["content"]?[0]?["text"]?.string ?? "").utf8))
                let revision = snapshot["baseRevision"] ?? .null
                let published = await model.performAgentTool(["name": "project_publish_design", "arguments": ["design": .string(design), "baseRevision": revision]], callerID: session.id, projectID: project.id)
                guard published["isError"]?.bool != true, let document = model.project(id: project.id)?.design,
                      !document.nodes.isEmpty, !(document.connections ?? []).isEmpty else {
                    throw DriverError("Design tool did not publish shapes and connections: \(published)")
                }
                let stale = await model.performAgentTool(["name": "project_publish_design", "arguments": ["design": "{\"nodes\":[]}", "baseRevision": revision]], callerID: session.id, projectID: project.id)
                guard stale["isError"]?.bool == true, model.project(id: project.id)?.design == document else {
                    throw DriverError("Stale Design update changed the canvas")
                }
                let output = published["content"]?[0]?["text"]?.string ?? ""
                session.apply(.tool(ToolCall(id: "design-fixture", name: "mcp__marika_browser__project_publish_design", kind: .mcp,
                    title: "Publish Design", detail: "Architecture diagram", output: output, status: .succeeded)))
                session.apply(.textFinished(id: "design-fixture-reply", text: "The architecture is ready in Design. Open the editable canvas below.", parentToolID: nil))
                await model.save()
                log("Design tools passed: publication, stale-update rejection, and chat result")
            case "apiLifecycleTest":
                try await DebugAPIChecks.lifecycle(model, action: step["action"]?.string ?? "remove")
                log("API lifecycle passed")
            case "apiRequestsTest":
                try await DebugAPIChecks.requests(model)
                log("Local API requests passed")
            case "apiClickSend":
                guard let window = window(), let view = window.contentView, let button = marker(in: view, named: "api-send") else { throw DriverError("Send control not found") }
                try click(button, in: window)
                for _ in 0..<100 {
                    if marker(in: view, named: "api-response-ok") != nil { return }
                    try await pause(0.1)
                }
                throw DriverError("No successful response in API view")
            case "apiGenerate", "apiCompose", "apiRequest":
                guard let project = model.selectedProject else { throw DriverError("no project") }
                let api = model.apiWorkspaces[project.id] ?? APIWorkspace()
                model.apiWorkspaces[project.id] = api
                if step["op"]?.string == "apiGenerate" {
                    await api.generate(project, model: model)
                    guard let id = model.project(id: project.id)?.apiAgentID else { throw DriverError(api.generatingError ?? "agent missing") }
                    for _ in 0..<240 where model.controllers[id]?.isBusy == true {
                        if let session = model.controllers[id], let approval = session.pendingApproval {
                            if step["approvePublish"]?.bool == true && approval.toolKind == .mcp
                                && approval.input["serverName"]?.string == "marika_browser"
                                && (approval.title.contains("project_publish_api") || approval.input["_meta"]?["tool_name"]?.string == "project_publish_api") {
                                session.answer(approval, with: .allow())
                            } else { throw DriverError("Agent needs input: " + approval.title) }
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                    guard model.project(id: project.id)?.apiCollection != nil else { throw DriverError("agent did not publish") }
                } else if step["op"]?.string == "apiCompose" {
                    let args = step["stop"]?.bool == true ? ["stop"] : ["up","--build","-d"]
                    await api.compose(args, project: project, environment: model.gitEnvironment)
                    log("compose " + api.log)
                } else if let plan = project.apiCollection, let endpoint = plan.endpoints.first(where: { item in
                    (step["method"]?.string == nil || item.method == step["method"]?.string) && (step["path"]?.string == nil || item.path == step["path"]?.string)
                }) {
                    log("response " + (try await APICollection.execute(endpoint, base: endpoint.target ?? plan.baseURL, headers: "", root: project.url, environment: model.gitEnvironment)))
                }
            case "pipelineRun":
                guard let project = model.selectedProject,
                      let job = try await PipelineDiscovery.jobs(at: project.url).first(where: { $0.job == step["job"]?.string })
                else { throw DriverError("pipeline job missing") }
                if let reason = job.reason { throw DriverError(reason) }
                model.runPipeline(job, project: project, image: step["image"]?.string ?? "node:24")
                while model.pipelineRunners[project.id]?.active != nil {
                    try await Task.sleep(for: .milliseconds(200))
                }
                log("pipeline " + (model.project(id: project.id)?.pipelineRuns?.last?.status ?? "missing"))
            case "layoutState":
                guard let project = model.selectedProject else { throw DriverError("no project") }
                let layout = model.layout(for: project.id)
                let editor = model.editors[project.id]
                let browser = model.browsers[project.id]
                let value: [String: Any] = ["primary": model.projectTabs[project.id]?.rawValue ?? "Conversation",
                    "secondary": layout.secondary?.rawValue ?? "", "stacked": layout.stacked, "fraction": layout.splitFraction,
                    "files": editor?.documents.map(\.path) ?? [], "selectedFile": editor?.selectedDocument?.path ?? "",
                    "draft": editor?.selectedDocument?.text ?? "", "conflict": editor?.selectedDocument?.changedOnDisk ?? false,
                    "browserURLs": browser?.pages.map { $0.url?.absoluteString ?? "" } ?? [], "viewport": browser?.viewport ?? ""]
                log("layout " + String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
            case "toolQuery":
                guard let sheet = window()?.attachedSheet, let root = sheet.contentView else { throw DriverError("no tool sheet") }
                let placeholder = model.showsCommandPalette ? "What would you like to do?" : "Search in \(model.selectedProject?.name ?? "")…"
                guard let field = textField(in: root, placeholder: placeholder) else { throw DriverError("tool query field not found") }
                sheet.makeFirstResponder(field)
                guard let editor = field.currentEditor() as? NSTextView else { throw DriverError("tool query not editable") }
                editor.insertText(step["text"]?.string ?? "", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            case "taskCompletionFixture":
                let session = try await current(model)
                model.showsWelcome = false
                model.switchPanel(.conversation)
                if step["changes"]?.bool != false {
                    session.apply(.tool(ToolCall(id: "workflow-edit", name: "edit", kind: .edit, title: "Update preview", detail: "",
                        status: .succeeded, diff: [DiffFile(path: "index.html", newContent: "<h1>Updated preview</h1>")])))
                }
                session.apply(.textFinished(id: "workflow-result", text: step["changes"]?.bool == false ? "The preview shows your project in the browser. No files were changed." : "Updated the preview page. Review the file changes, then run checks and open the preview.", parentToolID: nil))
                session.apply(.turnFinished(TurnSummary(outcome: .completed, durationMs: 1000)))
            case "taskCompletionCheck":
                let session = try await current(model)
                let summary = TaskCompletionSummary(items: session.items)
                guard summary?.changedFiles == ["index.html"] else { throw DriverError("Incorrect completion file summary") }
                if let expected = step["verified"]?.bool {
                    guard (session.meta.taskVerification?.succeeded == true) == expected else { throw DriverError("Unexpected verification result") }
                }
                if step["sheet"]?.bool == true {
                    guard let sheet = window()?.attachedSheet, let root = sheet.contentView,
                          marker(in: root, named: "task-completion-view") != nil else { throw DriverError("Completion sheet not shown") }
                }
                if step["inline"]?.bool == true {
                    guard let main = window(), main.attachedSheet == nil, let root = main.contentView,
                          marker(in: root, named: "task-results-checks-details") != nil else { throw DriverError("Checks are not inline") }
                }
                log("Completion summary and verification passed")
            case "verificationStatus":
                let session = try await current(model)
                let checks = model.taskVerification(for: session.id)
                let expected = step["status"]?.string ?? "current"
                for _ in 0..<60 where String(describing: checks.status) != expected { try await pause(0.1) }
                guard String(describing: checks.status) == expected else {
                    throw DriverError("Expected verification " + expected + ", got " + String(describing: checks.status) + ": " + (checks.detail ?? ""))
                }
                if let succeeded = step["succeeded"]?.bool, session.meta.taskVerification?.succeeded != succeeded {
                    throw DriverError("Unexpected recorded test result")
                }
                if step["incomplete"]?.bool == true, session.meta.taskVerification?.succeeded != nil {
                    throw DriverError("A changed-during-run result must not stay passed")
                }
                log("verification " + checks.label)
            case "verificationEdit":
                let session = try await current(model)
                guard let project = model.project(for: session.meta) else { throw DriverError("No project") }
                let root = session.meta.agentTask?.workspace.map { URL(fileURLWithPath: $0.workingPath) } ?? project.url
                let files = ProjectFiles(root: root)
                let before = try await files.read(step["path"]?.string ?? "")
                _ = try await files.write(step["text"]?.string ?? "", replacing: before)
            case "taskVerificationWait":
                let session = try await current(model)
                for _ in 0..<600 where model.taskVerifications[session.id]?.running == true { try await pause(0.1) }
                guard session.meta.taskVerification != nil else { throw DriverError("No verification result recorded") }
            case "previewCheck":
                guard let project = model.selectedProject else { throw DriverError("no project") }
                let preview = model.preview(for: project)
                if let state = step["state"]?.string, state != preview.state.rawValue { throw DriverError("Unexpected preview state: " + preview.state.rawValue) }
                if let text = step["errorContains"]?.string, preview.error?.contains(text) != true { throw DriverError("Missing preview diagnostic") }
            case "previewConfig":
                guard let project = model.selectedProject else { throw DriverError("no project") }
                model.savePreviewConfiguration(PreviewConfiguration(command: step["command"]?.string ?? "", address: step["address"]?.string ?? "http://localhost:1"), for: project)
            case "previewStart": model.runPreview()
            case "previewWait":
                guard let project = model.selectedProject else { throw DriverError("no project") }
                let preview = model.preview(for: project)
                for _ in 0..<120 where preview.state == .starting { try await pause(0.05) }
                guard preview.state == .running else { throw DriverError(preview.error ?? preview.logs) }
            case "previewStop":
                if let project = model.selectedProject { model.preview(for: project).stop() }
            case "previewState":
                guard let project = model.selectedProject else { throw DriverError("no project") }
                let preview = model.preview(for: project)
                log("preview " + String(decoding: try JSONSerialization.data(withJSONObject: ["state": preview.state.rawValue, "url": preview.address?.absoluteString ?? "", "logs": preview.logs]), as: UTF8.self))
            case "agentWorktreeEdit":
                guard let task = model.workspace.sessions.last(where: { $0.agentTask?.workspace != nil }),
                    let workspace = task.agentTask?.workspace else { throw DriverError("no isolated agent") }
                let files = ProjectFiles(root: URL(fileURLWithPath: workspace.workingPath))
                let snapshot = try await files.read(step["path"]?.string ?? "")
                _ = try await files.write(step["text"]?.string ?? "", replacing: snapshot)
            case "agentReview":
                guard let task = model.workspace.sessions.last(where: { $0.agentTask?.workspace != nil }) else { throw DriverError("no isolated agent") }
                model.reviewAgentID = task.id
            case "reviewApply":
                guard let sheet = window()?.attachedSheet,
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil,
                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
                else { throw DriverError("review not open") }
                guard sheet.performKeyEquivalent(with: event) else { throw DriverError("apply action not available") }
            case "checkpoint": await model.save()
            case "storageState":
                let state: [String: Any] = ["label": step["label"]?.string ?? "", "loadFailed": model.workspaceLoadFailed,
                    "error": model.storageError ?? "", "recovery": model.storageRecoveryNotice ?? ""]
                log("storage " + String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self))
            case "storageRetry": await model.retryStorage()
            case "send":
                try await current(model).send(UserInput(text: step["text"]?.string ?? ""))
            case "draft":
                try await current(model).draft = step["text"]?.string ?? ""
            case "starter":
                guard let starter = SessionStarter(rawValue: step["name"]?.string ?? "") else {
                    throw DriverError("unknown starter")
                }
                let session = try await current(model)
                model.prepareStarter(starter, for: session.id)
            case "projectTab":
                guard let meta = model.selectedSession, let project = model.project(for: meta) else { throw DriverError("no project") }
                if step["tab"]?.string == "agents" {
                    model.showAgents(for: project)
                } else if step["tab"]?.string == "code" {
                    _ = model.editor(for: project)
                    model.projectTabs[project.id] = .code
                } else if step["tab"]?.string == "browser" {
                    _ = model.browser(for: project)
                    model.projectTabs[project.id] = .browser
                } else {
                    model.projectTabs[project.id] = .conversation
                    model.composerFocusRequest = UUID()
                }
            case "projectTabClick":
                guard let window = window(), let view = window.contentView,
                      let marker = marker(in: view, named: "workspace-tab-" + (step["tab"]?.string?.lowercased() ?? ""))
                else { throw DriverError("project tab control not found") }
                try click(marker, in: window)
            case "projectTabState":
                guard let meta = model.selectedSession else { throw DriverError("no selected session") }
                log("project tab \(model.projectTabs[meta.projectID]?.rawValue ?? "Conversation") browser=\(model.browsers[meta.projectID] != nil)")
            case "browserAddress":
                guard let window = window(), let view = window.contentView,
                      let field = textField(in: view, placeholder: "Search or enter address")
                else { throw DriverError("browser address field not found") }
                window.makeFirstResponder(field)
                guard let input = field.currentEditor() as? NSTextView else { throw DriverError("browser address field is not editable") }
                input.insertText(step["text"]?.string ?? "", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
            case "codeOpen":
                guard let meta = model.selectedSession, let project = model.project(for: meta) else { throw DriverError("no project") }
                model.projectTabs[project.id] = .code
                await model.editor(for: project).open(step["path"]?.string ?? "")
            case "codeColors":
                guard let document = model.activeEditor?.selectedDocument, let content = window()?.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }) else { throw DriverError("Code editor not found") }
                let source = document.text as NSString
                let words = step["tokens"]?.array?.compactMap(\.string) ?? ["func", "FetchUser", "invalid user"]
                var colours: [NSColor] = []
                for _ in 0..<50 {
                    colours = words.compactMap { word in
                        let range = source.range(of: word)
                        guard range.location != NSNotFound else { return nil }
                        return (view.textStorage?.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
                    }
                    if Set(colours.map { $0.description }).count >= 3 { break }
                    try await pause(0.05)
                }
                guard Set(colours.map { $0.description }).count >= 3, view.string == document.text, !document.isModified,
                      view.font?.pointSize ?? 0 >= 13, view.defaultParagraphStyle?.lineSpacing ?? 0 >= 3 else { throw DriverError("Editor colour or layout verification failed") }
                log("Distinct syntax colours and readable spacing passed; file unchanged")
            case "codeLayout":
                guard let document = model.activeEditor?.selectedDocument, let content = window()?.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }),
                      let scroll = view.enclosingScrollView, let layout = view.layoutManager, let container = view.textContainer else { throw DriverError("Code editor not found") }
                scroll.needsLayout = true; scroll.layoutSubtreeIfNeeded()
                let wide = view.frame.width > scroll.contentView.bounds.width + 1
                guard wide == (step["wide"]?.bool ?? false) else { throw DriverError("Incorrect horizontal scroll area: viewport=\(scroll.contentView.bounds.width), document=\(view.frame.width)") }
                if wide {
                    scroll.contentView.scroll(to: NSPoint(x: view.frame.width - scroll.contentView.bounds.width, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    guard scroll.contentView.bounds.minX > 0 else { throw DriverError("Long line cannot scroll horizontally") }
                    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
                }
                if let wrap = step["wrap"]?.bool {
                    guard container.widthTracksTextView == wrap, scroll.hasHorizontalScroller != wrap else { throw DriverError("Wrap setting did not reach the editor") }
                    let firstLine = (view.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
                    var fragments = 0
                    var rightEdge: CGFloat = 0
                    layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: firstLine, actualCharacterRange: nil)) { _, used, _, _, _ in
                        fragments += 1; rightEdge = max(rightEdge, used.maxX)
                    }
                    guard wrap ? fragments > 1 : fragments == 1 else { throw DriverError("Long line wrapping failed: \(fragments) fragments") }
                    if wrap, rightEdge + view.textContainerInset.width > scroll.contentView.bounds.maxX + 1 {
                        throw DriverError("Wrapped text extends beyond the visible edge")
                    }
                }
                log("Native horizontal scrolling and line wrapping checks passed")
            case "editorSettingsTest":
                guard ProcessInfo.processInfo.environment["MARIKA_EDITOR_DEFAULTS_SUITE"] != nil,
                      let document = model.activeEditor?.selectedDocument, let content = window()?.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }),
                      let tabs = marker(in: content, named: "editor-file-tabs"), let toolbar = marker(in: content, named: "editor-toolbar")
                else { throw DriverError("Isolated editor test is not ready") }
                guard tabs.bounds.height <= 35, toolbar.bounds.height <= 35 else { throw DriverError("Editor controls are too tall") }
                let settings = EditorSettings.shared, saved = settings.style, original = view.string
                defer {
                    settings.fontSize = saved.fontSize; settings.theme = saved.theme; settings.tabWidth = saved.tabWidth
                    settings.usesTabs = saved.usesTabs; settings.wrapsLines = saved.wrapsLines; settings.showsIndentGuides = saved.showsIndentGuides
                    document.text = original
                }
                view.undoManager?.removeAllActions()
                view.insertText("\n// preference check", replacementRange: NSRange(location: (original as NSString).length, length: 0))
                try await pause(0.2)
                let selection = view.selectedRange()
                settings.fontSize = 18; settings.theme = .light; settings.tabWidth = 8; settings.usesTabs = true; settings.showsIndentGuides = false
                try await pause(0.3)
                guard view.editorStyle.fontSize == 18, view.font?.pointSize == 18,
                      view.selectedRange() == selection, view.undoManager?.canUndo == true,
                      view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
                      view.defaultParagraphStyle?.defaultTabInterval == settings.style.paragraph.defaultTabInterval
                else { throw DriverError("Editor settings did not apply without disturbing the selection or undo") }
                view.undoManager?.undo(); try await pause(0.15)
                guard view.string == original else { throw DriverError("Changing editor settings broke undo") }
                settings.fontSize = 14; settings.theme = .dark; settings.tabWidth = 2; settings.usesTabs = false
                try await pause(0.2)
                let end = (view.string as NSString).length
                view.insertText("\nfunc check() {", replacementRange: NSRange(location: end, length: 0))
                view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                guard view.string.hasSuffix("{\n  ") else { throw DriverError("Newline did not use the chosen indentation width") }
                view.doCommand(by: #selector(NSResponder.insertTab(_:)))
                guard view.string.hasSuffix("{\n    ") else { throw DriverError("Tab did not insert the chosen spaces") }
                settings.usesTabs = true; try await pause(0.2)
                view.doCommand(by: #selector(NSResponder.insertTab(_:)))
                guard view.string.hasSuffix("\t") else { throw DriverError("Tab indentation ignored the setting") }
                let restored = EditorSettings(defaults: UserDefaults(suiteName: ProcessInfo.processInfo.environment["MARIKA_EDITOR_DEFAULTS_SUITE"]!)!)
                guard restored.style == settings.style else { throw DriverError("Editor preferences were not saved") }
                guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window()?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                      let menu = view.menu(for: event), menu.items.contains(where: { $0.title == "Rename Symbol…" }),
                      menu.items.first(where: { $0.title == "Insert Snippet" })?.submenu?.items.count == EditorSnippet.allCases.count
                else { throw DriverError("Editor context actions missing") }
                log("Compact controls, live theme and font, indentation, persisted preferences, context menus, and preserved undo passed")
            case "inlineAssistanceTest":
                try await testInlineAssistance(step, model)
            case "inlineReviewTest":
                try await testInlineReview(step, model)
            case "mcpManagerTest":
                try await testMCPManager(step, model)
            case "navigationLinksTest":
                try await testNavigationLinks(step, model)
            case "mcpOAuthTest":
                try await testMCPOAuth(step, model)
            case "projectChatTest":
                try await testProjectChat(step, model)
            case "markdownTest":
                try await testMarkdown(step, model)
            case "chatHistoryUpdatesTest":
                try await testChatHistoryUpdates(step, model)
            case "spacesTest":
                try await testSpaces(step, model)
            case "projectTabsTest":
                try await testProjectTabs(step, model)
            case "projectTabsState":
                guard let project = model.selectedProject else { throw DriverError("No selected project") }
                let layout = model.layout(for: project.id)
                let state: [String: Any] = ["project": project.name, "selected": layout.panel.rawValue,
                    "tabs": layout.openTabs.map(\.rawValue), "split": layout.secondary?.rawValue ?? "",
                    "sessions": model.workspace.sessions.count]
                log("projectTabs " + String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self))
            case "spaceCreate":
                try await editSpaceUI(name: step["name"]?.string ?? "Work", color: step["color"]?.string ?? "teal", model: model)
            case "spaceSwitch":
                guard let space = model.workspace.spaces.first(where: { $0.name == step["name"]?.string }) else { throw DriverError("Space not found") }
                if let root = window()?.contentView, let row = marker(in: root, named: "space-switch-" + space.id.uuidString) {
                    row.scrollToVisible(row.bounds)
                    try await pause(0.15)
                }
                try await run(["op": "clickMarker", "name": .string("space-switch-" + space.id.uuidString)], model)
                guard model.selectedSpace.id == space.id else { throw DriverError("Space row did not select " + space.name) }
            case "spaceContentState":
                let space = model.selectedSpace
                let notes: [[String: Any]] = space.notes.map { note in ["id": note.id.uuidString, "title": note.title,
                    "blocks": note.blocks.map { ["kind": $0.kind.rawValue, "text": $0.text, "checked": $0.checked] as [String: Any] },
                    "archived": note.archived, "pinned": note.pinned] }
                let tickets: [[String: Any]] = space.tickets.map { ticket in ["id": ticket.id.uuidString, "key": ticket.key,
                    "title": ticket.title, "body": ticket.body, "status": ticket.status.rawValue, "priority": ticket.priority.rawValue,
                    "assignee": ticket.assignee, "archived": ticket.archived, "projectID": ticket.projectID?.uuidString ?? ""] }
                log("spaceContent " + String(decoding: try JSONSerialization.data(withJSONObject: ["space": space.name, "section": space.section.rawValue, "notes": notes, "tickets": tickets], options: [.sortedKeys]), as: UTF8.self))
            case "ticketWorkTest":
                try await DebugTicketWorkChecks.run(step, model: model)
                log("Ticket work " + (step["phase"]?.string ?? "") + " passed")
            case "spaceContentText":
                guard let main = window(), let name = step["name"]?.string else { throw DriverError("Space text target missing") }
                let targetWindow = main.attachedSheet ?? main
                guard let root = targetWindow.contentView, let target = marker(in: root, named: name) else { throw DriverError("Space field not found: " + name) }
                if name == "space-ticket-description", let editor = textViews(in: root).first(where: { $0.isEditable && !$0.isFieldEditor }) {
                    guard targetWindow.makeFirstResponder(editor) else { throw DriverError("Ticket description did not receive focus") }
                    try await pause(0.1)
                } else {
                    try click(target, in: targetWindow); try await pause(0.1)
                }
                guard let field = targetWindow.firstResponder as? NSTextView else { throw DriverError("Space text field is not focused: " + name) }
                field.insertText(step["text"]?.string ?? "", replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
                try await pause(0.1)
            case "noteTicketSaveGuard":
                try await DebugNoteTicketChecks.saveFailure(model: model)
                log("Note ticket save failure recovered without an orphaned ticket")
            case "noteTicketSelect":
                guard let main = window(), let root = main.contentView,
                      let name = step["name"]?.string, let target = marker(in: root, named: name) else { throw DriverError("Note selection target missing") }
                try click(target, in: main); try await pause(0.1)
                guard let field = main.firstResponder as? NSTextView, field.isFieldEditor else { throw DriverError("Note field editor missing") }
                let selected = step["text"]?.string ?? field.string
                let range = (field.string as NSString).range(of: selected)
                guard range.location != NSNotFound else { throw DriverError("Selection text missing from the note") }
                field.setSelectedRange(range)
                try await pause(0.2)
            case "spaceNoteBlock":
                let space = model.selectedSpace
                guard let id = model.spaceNoteSelections[space.id] ?? space.notes.first?.id else { throw DriverError("No note selected") }
                let kind = SpaceNoteBlock.Kind(rawValue: step["kind"]?.string ?? "Text") ?? .text
                if step["append"]?.bool == true { model.updateSpaceNote(id, in: space.id) { $0.blocks.append(SpaceNoteBlock(kind: kind)) } }
                guard let block = model.note(id, in: space.id)?.blocks.last else { throw DriverError("No note block") }
                model.updateSpaceNote(id, in: space.id) { note in
                    if let index = note.blocks.firstIndex(where: { $0.id == block.id }) { note.blocks[index].kind = kind; note.blocks[index].checked = step["checked"]?.bool ?? false }
                }
                try await pause(0.1)
                try await run(["op": "spaceContentText", "name": .string("space-note-block-" + block.id.uuidString), "text": step["text"] ?? ""], model)
            case "spaceTicketFields":
                let space = model.selectedSpace
                guard let id = space.tickets.last?.id else { throw DriverError("No ticket") }
                let linkedProjectID = model.spaceProjects.first?.id
                model.updateSpaceTicket(id, in: space.id) { ticket in
                    if let status = step["status"]?.string.flatMap(SpaceTicket.Status.init(rawValue:)) { ticket.status = status }
                    if let priority = step["priority"]?.string.flatMap(SpaceTicket.Priority.init(rawValue:)) { ticket.priority = priority }
                    if let assignee = step["assignee"]?.string { ticket.assignee = assignee }
                    if step["linkProject"]?.bool == true { ticket.projectID = linkedProjectID }
                }
            case "spacesState":
                let state: [String: Any] = ["selectedSpace": model.selectedSpace.name,
                    "selectedProject": model.selectedProject?.name ?? "",
                    "spaces": model.workspace.spaces.map(\.name), "visibleProjects": model.spaceProjects.map(\.name),
                    "drafts": Dictionary(uniqueKeysWithValues: model.workspace.sessions.map { ($0.id.uuidString, $0.draft?.text ?? "") })]
                log("spaces " + String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self))
            case "assertMarker":
                let name = step["name"]?.string ?? ""
                for _ in 0..<40 {
                    let present = NSApp.windows.filter(\.isVisible).contains { $0.contentView.flatMap { marker(in: $0, named: name) } != nil }
                    if present == (step["present"]?.bool ?? true) { return }
                    try await pause(0.05)
                }
                throw DriverError("Unexpected visibility for " + name)
            case "qaLayoutState":
                guard let main = window(), let root = main.contentView else { throw DriverError("No QA window") }
                root.layoutSubtreeIfNeeded()
                let projectList = marker(in: root, named: "sidebar-project-list")
                let widths = Dictionary(uniqueKeysWithValues: ProjectPanel.allCases.compactMap { panel -> (String, CGFloat)? in
                    guard let tab = marker(in: root, named: "workspace-tab-" + panel.rawValue.lowercased()) else { return nil }
                    return (panel.rawValue, tab.bounds.width)
                })
                let state: [String: Any] = ["space": model.selectedSpace.name, "section": model.selectedSpace.section.rawValue,
                    "welcome": model.showsWelcome, "commandPanel": model.commandPanel?.rawValue ?? "",
                    "windowWidth": root.bounds.width, "projectListHeight": projectList.map { min($0.bounds.height, $0.visibleRect.height) } ?? 0,
                    "tabWidths": widths]
                log("qaLayout " + String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self))
            case "attentionTest":
                try await DebugAttentionChecks.run(step, model: model)
                log("Attention inbox " + (step["phase"]?.string ?? "") + " passed")
            case "clickMarker":
                let name = step["name"]?.string ?? ""
                guard let target = NSApp.windows.filter(\.isVisible).compactMap({ window in window.contentView.flatMap { marker(in: $0, named: name) }.map { (window, $0) } }).first else { throw DriverError("Missing UI element: " + name) }
                if step["scroll"]?.bool == true { target.1.scrollToVisible(target.1.bounds); try await pause(0.15) }
                try click(target.1, in: target.0)
                try await pause(0.3)
            case "editorPopoverShot":
                let name = step["name"]?.string ?? "editor-settings-panel"
                guard let mark = NSApp.windows.compactMap({ $0.contentView.flatMap { marker(in: $0, named: name) } }).first,
                      let view = mark.window?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DriverError("Popover not found") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DriverError("Popover image failed") }
                try data.write(to: URL(fileURLWithPath: step["path"]?.string ?? "popover.png"))
            case "captureMarker":
                let name = step["name"]?.string ?? ""
                guard let target = NSApp.windows.first(where: { $0.contentView.flatMap { marker(in: $0, named: name) } != nil }) else { throw DriverError("Capture target not found") }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l\(target.windowNumber)", step["path"]?.string ?? "capture.png"]
                try process.run(); process.waitUntilExit()
                if process.terminationStatus != 0 {
                    guard let view = target.contentView?.superview ?? target.contentView,
                          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DriverError("Native capture failed") }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw DriverError("Native capture failed") }
                    try data.write(to: URL(fileURLWithPath: step["path"]?.string ?? "capture.png"))
                }
            case "agentsMock":
                let seconds = step["seconds"]?.double ?? 1
                model.agentFactoryOverride = { _ in DebugTaskAgent(seconds: seconds) }
            case "welcomeStatus":
                var statuses: [AgentKind: AgentStatus] = [:]
                for agent in AgentKind.allCases {
                    let value = step[agent.rawValue]?.string ?? "missing"
                    let readiness: AgentStatus.Readiness
                    switch value {
                    case "ready": readiness = .ready
                    case "signedOut": readiness = .signedOut
                    case "checking": readiness = .checking
                    case "unavailable": readiness = .unavailable("Couldn't check the account. Try again.")
                    default: readiness = .notInstalled
                    }
                    statuses[agent] = AgentStatus(readiness: readiness,
                        executable: value == "missing" || value == "checking" ? nil : URL(fileURLWithPath: step[agent.rawValue + "Executable"]?.string ?? "/fixture/" + agent.executableName))
                }
                model.agentStatusOverride = statuses
                await model.refreshAgents(force: true)
            case "welcomeShow": model.showWelcome()
            case "welcomeUseReadyAgent":
                guard let suggestion = model.welcomeSuggestedAgent else { throw DriverError("No ready agent suggestion") }
                model.selectWelcomeAgent(suggestion)
            case "signInFixture":
                let agent = AgentKind(rawValue: step["agent"]?.string ?? "codex") ?? .codex
                let failFirst = step["failFirst"]?.bool ?? false
                let delay = step["seconds"]?.double ?? 0.5
                var attempts = 0
                model.signInOpenOverride = { [weak model] command in
                    attempts += 1
                    if failFirst && attempts == 1 { return false }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        model?.agentStatusOverride?[agent]?.readiness = .ready
                        try? Data("0\n".utf8).write(to: command.deletingLastPathComponent().appendingPathComponent("result"))
                    }
                    return true
                }
            case "signInStart": model.signIn(AgentKind(rawValue: step["agent"]?.string ?? "codex") ?? .codex)
            case "signInState":
                let agent = AgentKind(rawValue: step["agent"]?.string ?? "codex") ?? .codex
                guard let flow = model.signIns[agent] else { throw DriverError("No sign-in flow") }
                log("signIn " + String(decoding: try JSONSerialization.data(withJSONObject: ["phase": String(describing: flow.phase), "message": flow.message ?? ""], options: [.sortedKeys]), as: UTF8.self))
            case "fullScreen":
                guard let main = window() else { throw DriverError("No main window") }
                let desired = step["enabled"]?.bool ?? true
                if main.styleMask.contains(.fullScreen) != desired {
                    let transition = WindowTransition()
                    let observer = NotificationCenter.default.addObserver(forName: desired ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification, object: main, queue: .main) { _ in
                        MainActor.assumeIsolated { transition.finished = true }
                    }
                    defer { NotificationCenter.default.removeObserver(observer) }
                    main.toggleFullScreen(nil)
                    for _ in 0..<140 where !transition.finished { try await pause(0.05) }
                    guard transition.finished else { throw DriverError("Full-screen transition did not finish") }
                }
                guard main.styleMask.contains(.fullScreen) == desired else { throw DriverError("Full-screen transition failed") }
                try await pause(0.2)
            case "toolbarCheck":
                guard let main = window(), main.toolbar?.isVisible != true else { throw DriverError("An empty native toolbar is reserving space") }
                log("Native toolbar removed; fullScreen=\(main.styleMask.contains(.fullScreen))")
            case "welcomeAgent":
                model.selectWelcomeAgent(AgentKind(rawValue: step["agent"]?.string ?? "") ?? .claude)
            case "welcomeFinish":
                let result = await model.finishWelcome(exploreOnly: step["explore"]?.bool ?? false)
                if result != (step["succeeds"]?.bool ?? true) { throw DriverError("Unexpected setup completion result") }
            case "welcomeState":
                let state: [String: Any] = ["shown": model.showsWelcome, "agent": model.welcomeAgent.rawValue,
                    "project": model.selectedProject?.name ?? "", "ready": model.welcomeChecklist.isReady,
                    "completedSteps": model.welcomeChecklist.completedSteps,
                    "completed": model.workspace.preferences.welcomeCompleted ?? false,
                    "suggestedAgent": model.welcomeSuggestedAgent?.rawValue ?? "",
                    "sessionAgent": model.selectedSession?.agent.rawValue ?? ""]
                log("welcome " + String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self))
            case "streamingRecoveryTest":
                try await DebugPersistenceChecks.streamingRecovery(model)
                log("Continuous streaming and draft autosave passed")
            case "composerMock":
                let session = try await current(model)
                session.apply(.contextUsage(ContextUsage(usedTokens: 28_000, maxTokens: 128_000)))
                session.apply(.capabilities(AgentCapabilities(models: [ModelOption(
                    id: "ui-model", name: "Coding model", efforts: ["low", "medium", "high"], isDefault: true,
                    defaultEffort: "medium", serviceTiers: [
                        .standard, ServiceTierOption(id: "priority", name: "Fast"), ServiceTierOption(id: "ultrafast", name: "Ultrafast"),
                    ])])))
            case "experience":
                guard let project = model.selectedProject else { throw DriverError("No project") }
                model.showExperience(step["section"]?.string ?? "Recovery", project: project)
            case "completionTest":
                guard let project = model.selectedProject else { throw DriverError("No project") }
                model.switchPanel(.code)
                let editor = model.editor(for: project)
                await editor.open("Sample.swift")
                editor.focusEditor()
                try await pause(0.3)
                guard let window = window(), let content = window.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == editor.selectedDocumentID }) else { throw DriverError("Code editor not mounted") }
                model.completionOverride = "return value"
                defer { model.completionOverride = nil }
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                let original = view.string
                view.onRequestCompletion?()
                for _ in 0..<30 {
                    if view.suggestion == "return value" { break }
                    try await pause(0.05)
                }
                guard view.suggestion == "return value", view.string == original else { throw DriverError("Ghost suggestion changed the document") }
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else { throw DriverError("Tab event failed") }
                view.keyDown(with: event)
                try await pause(0.1)
                guard view.string == original + "return value", editor.selectedDocument?.text == view.string else { throw DriverError("Tab did not accept the suggestion") }
                log("Native ghost completion and Tab acceptance passed")
            case "ideTest":
                guard let project = model.selectedProject else { throw DriverError("No project") }
                model.showCode()
                let editor = model.editor(for: project)
                await editor.open("main.go")
                guard let document = editor.selectedDocument else { throw DriverError("Missing Go document") }
                let original = document.text, ide = model.ide(for: project, editor: editor)
                await ide.synchronize(document)
                document.line = 3; document.column = 6
                ide.renameText = "sum"; ide.perform("Rename")
                for _ in 0..<100 { if !ide.pendingEdits.isEmpty { break }; try await pause(0.05) }
                guard !ide.pendingEdits.isEmpty else { throw DriverError("Rename did not produce a preview: " + ide.message) }
                ide.pendingEdits = []
                document.text = original.replacingOccurrences(of: "fmt.Println(value)", with: "fmt.Println(missing)")
                await ide.synchronize(document)
                for _ in 0..<100 { if ide.problemCount > 0 { break }; try await pause(0.05) }
                guard ide.problemCount > 0 else { throw DriverError("Live diagnostic missing") }
                ide.showsPanel = true; ide.panel = "Problems"
                try await pause(0.3)
                if let folder = step["directory"]?.string { try snapshot(to: folder + "/problems.png", title: nil) }
                document.text = original
                ide.discoverTests()
                for _ in 0..<200 { if !ide.testRunning { break }; try await pause(0.05) }
                guard !ide.tests.isEmpty else { throw DriverError("Tests not discovered: " + ide.testOutput) }
                ide.runTest()
                for _ in 0..<200 { if !ide.testRunning { break }; try await pause(0.05) }
                guard ide.testStatuses.values.contains("pass"), !ide.coverage.isEmpty else { throw DriverError("Test results or coverage missing: " + ide.testOutput) }
                try await pause(0.3)
                if let folder = step["directory"]?.string { try snapshot(to: folder + "/tests.png", title: nil) }
                ide.breakpoints["main.go"] = [6]
                ide.launchDebugger()
                for _ in 0..<400 { if ide.debug.isPaused || ide.debug.error != nil { break }; try await pause(0.05) }
                guard ide.debug.isPaused else { throw DriverError("Debugger did not pause: " + (ide.debug.error ?? ide.message)) }
                await ide.debug.evaluate("value")
                guard ide.debug.watches["value"] == "5" else { throw DriverError("Debugger value unavailable") }
                try await pause(0.3)
                if let folder = step["directory"]?.string { try snapshot(to: folder + "/debugger.png", title: nil) }
                await ide.debug.stop()
                log("Live diagnostics, rename preview, test explorer, coverage, breakpoint and watch passed")
            case "editorMechanicsTest":
                guard let project = model.selectedProject else { throw DriverError("No project") }
                model.showCode(); let editor = model.editor(for: project)
                await editor.open("main.go"); try await pause(0.2)
                guard let document = editor.selectedDocument, let content = window()?.contentView,
                      let view = textViews(in: content).compactMap({ $0 as? CodeEditingTextView }).first(where: { $0.documentID == document.id }) else { throw DriverError("Code view not found") }
                let original = view.string, source = original as NSString
                let first = source.range(of: "func"), second = source.range(of: "func", range: NSRange(location: NSMaxRange(first), length: source.length - NSMaxRange(first)))
                view.undoManager?.removeAllActions()
                view.selectedRanges = [NSValue(range: first), NSValue(range: second)]
                guard view.selectedRanges.count == 2 else { throw DriverError("Multiple selections unavailable") }
                view.insertText("function", replacementRange: first); try await pause(0.1)
                guard view.string.components(separatedBy: "function").count == 3, document.text == view.string else { throw DriverError("Multi-cursor edit failed") }
                view.undoManager?.undo(); try await pause(0.1)
                guard view.string == original, document.text == original else { throw DriverError("Multi-cursor undo failed") }
                document.line = 4; document.column = 1
                let ide = model.ide(for: project, editor: editor)
                let height = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 0
                ide.perform("Fold")
                for _ in 0..<50 { if !document.foldedRanges.isEmpty { break }; try await pause(0.05) }
                try await pause(0.2)
                view.layoutManager?.ensureLayout(for: view.textContainer!)
                guard !document.foldedRanges.isEmpty, view.string == original,
                      (view.layoutManager?.usedRect(for: view.textContainer!).height ?? height) < height else { throw DriverError("Code folding did not collapse the block") }
                document.foldedRanges = []
                if let folder = step["directory"]?.string {
                    model.projectSettingsID = project.id; try await pause(0.4)
                    try snapshot(to: folder + "/settings.png", title: nil, sheet: true)
                }
                log("Native multi-cursor editing, undo, and non-destructive folding passed")
            case "experienceTest":
                guard let project = model.selectedProject, let secondPath = step["second"]?.string else { throw DriverError("Missing project folders") }
                let second = URL(fileURLWithPath: secondPath)
                model.updateProject(project.id) { $0.repositoryPaths = [second.path] }
                model.selectRepository(second, project: model.project(id: project.id)!)
                let secondaryEditor = model.editor(for: model.project(id: project.id)!)
                await secondaryEditor.open("Web.ts")
                guard let document = secondaryEditor.selectedDocument else { throw DriverError("Missing secondary document") }
                document.text = "unsaved secondary draft"
                model.selectRepository(project.url, project: model.project(id: project.id)!)
                var settings = ProjectTools()
                settings.memory = "Always cite observed verification."
                settings.hooks = [ProjectHook(event: .beforeTurn, command: "printf before > .before-turn"), ProjectHook(event: .afterTurn, command: "printf after > .after-turn")]
                try model.saveTools(settings, for: project)
                model.agentFactoryOverride = { _ in DebugTaskAgent(seconds: 1.5) }
                let session = try await current(model)
                session.disconnect()
                session.send(UserInput(text: "Verify automatic recovery"))
                for _ in 0..<100 {
                    if model.activeCheckpoints[session.id] != nil { break }
                    try await pause(0.05)
                }
                guard model.activeCheckpoints[session.id] != nil else { throw DriverError("Automatic checkpoint did not start") }
                try "agent change\n".write(to: project.url.appendingPathComponent("Sample.swift"), atomically: true, encoding: .utf8)
                for _ in 0..<120 {
                    if !session.isBusy, model.checkpointRecords[project.id]?.first?.after != nil { break }
                    try await pause(0.05)
                }
                await model.reloadCheckpoints(project.id)
                guard let checkpoint = model.checkpointRecords[project.id]?.first, checkpoint.after != nil else { throw DriverError("Checkpoint did not finish") }
                guard FileManager.default.fileExists(atPath: project.url.appendingPathComponent(".after-turn").path) else { throw DriverError("After hook did not run") }
                do { try await model.restoreCheckpoint(checkpoint); throw DriverError("Unsaved draft was not protected") }
                catch let error as DriverError { throw error }
                catch { log("Unsaved secondary draft correctly blocked rewind") }
                secondaryEditor.close(document)
                try await model.restoreCheckpoint(checkpoint)
                guard try String(contentsOf: project.url.appendingPathComponent("Sample.swift"), encoding: .utf8) == "original\n" else { throw DriverError("Rewind failed") }
                model.runDebug("printf 'observed failure\\n'; exit 3", project: project)
                for _ in 0..<100 {
                    if model.debugTasks[project.id] == nil { break }
                    try await pause(0.05)
                }
                guard model.project(id: project.id)?.debugRuns?.last?.exitCode == 3 else { throw DriverError("Runtime evidence missing") }
                let result = await model.performAgentTool(["name": "project_publish_artifact", "arguments": ["kind": "Plan", "title": "Improve API resilience", "body": "# Implementation plan\n\n## Proposed changes\n\nInspect Sample.swift and Web.ts. Add input validation at the API boundary.\n\n## Verification\n\nRun focused tests and reproduce the original error."]], callerID: session.id, projectID: project.id)
                guard result["isError"]?.bool != true else { throw DriverError("Artifact tool failed") }
                model.selectRepository(second, project: model.project(id: project.id)!)
                await secondaryEditor.open("Web.ts")
                secondaryEditor.selectedDocument?.text = "persisted secondary draft"
                model.selectRepository(project.url, project: model.project(id: project.id)!)
                await model.save()
                log("Recovery, multi-repo drafts, hooks, runtime evidence, and artifact publishing passed")
            case "agentsForm":
                model.showAgents(launch: true)
            case "agentsTask":
                guard let sheet = window()?.attachedSheet, let content = sheet.contentView,
                      let input = textViews(in: content).first(where: { $0.isEditable }) else { throw DriverError("agent task field not found") }
                sheet.makeFirstResponder(input)
                input.insertText(step["text"]?.string ?? "", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
            case "agentsSubmit":
                guard let sheet = window()?.attachedSheet,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                          context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
                else { throw DriverError("launch form not found") }
                sheet.makeKeyAndOrderFront(nil)
                guard sheet.performKeyEquivalent(with: event) else { throw DriverError("launch shortcut did not activate") }
            case "agentsLaunch":
                guard let meta = model.selectedSession, let project = model.project(for: meta) else { throw DriverError("no project") }
                let controller = try await model.launchAgent(in: project,
                    agent: AgentKind(rawValue: step["agent"]?.string ?? "") ?? .codex,
                    settings: AgentSettings(), prompt: step["task"]?.string ?? "Check this project")
                if let reference = step["saveAs"]?.string { agentReferences[reference] = controller.id }
            case "agentsTool":
                guard let caller = model.selectedSession, let project = model.project(for: caller) else { throw DriverError("no project") }
                let request: JSONValue = ["name": step["name"] ?? "agent_list", "arguments": resolveAgentReferences(step["arguments"] ?? [:])]
                let result = try await browserMCPCall(request, browser: model.browser(for: project), sessionID: caller.id)
                let text = result["content"]?[0]?["text"]?.string ?? ""
                if result["isError"]?.bool == true, step["allowFailure"]?.bool != true { throw DriverError(text) }
                if let reference = step["saveAs"]?.string, let data = try? JSONValue(parsing: Data(text.utf8)),
                   let id = data["id"]?.string.flatMap(UUID.init(uuidString:)) { agentReferences[reference] = id }
                log("agent tool \(step["name"]?.string ?? "") error=\(result["isError"]?.bool ?? false) \(text.prefix(1600))")
            case "agentsState":
                if let reference = step["saveAs"]?.string,
                   let task = model.workspace.sessions.last(where: { $0.agentTask != nil }) { agentReferences[reference] = task.id }
                let tasks = model.workspace.sessions.filter { $0.agentTask != nil }.map { meta -> JSONValue in
                    ["id": .string(meta.id.uuidString), "agent": .string(meta.agent.rawValue),
                     "title": .string(meta.title), "mode": .string(meta.mode.rawValue),
                     "parent": meta.agentTask?.parentSessionID.map { .string($0.uuidString) } ?? .null,
                     "busy": .bool(model.controllers[meta.id]?.isBusy ?? false)]
                }
                log("agent tasks " + String(decoding: try JSONValue.array(tasks).serialized(), as: UTF8.self))
            case "codeQuickOpen":
                model.showCode(quickOpen: true)
            case "codeSearch":
                let target = window()?.attachedSheet ?? window()
                guard let view = target?.contentView,
                      let field = textField(in: view, placeholder: step["navigator"]?.bool == true ? "Find files…" : "Go to file…")
                else {
                    log("file search missing: window=\(target?.title ?? "none"), frame=\(target?.frame ?? .zero), navigator=\(model.activeEditor?.showsNavigator == true)")
                    try? await run(["op": "uiState"], model)
                    throw DriverError("file search field not found")
                }
                target?.makeFirstResponder(field)
                if let input = field.currentEditor() as? NSTextView {
                    input.insertText(step["text"]?.string ?? "", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
                } else {
                    field.stringValue = step["text"]?.string ?? ""
                    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                    field.sendAction(field.action, to: field.target)
                }
            case "codeNavigator":
                model.showCode(focusFiles: true)
                if let path = step["path"]?.string { model.activeEditor?.navigatorSelection = path }
            case "codeClickRow":
                guard let editor = model.activeEditor, let window = window(), let view = window.contentView,
                      let path = step["path"]?.string,
                      let row = editor.visibleEntries.firstIndex(where: { $0.id == path }),
                      let table = tables(in: view).max(by: {
                          $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
                      }), row < table.numberOfRows
                else { throw DriverError("file row not found") }
                let rect = table.convert(table.rect(ofRow: row), to: nil)
                let point = NSPoint(x: rect.minX + min(130, rect.width / 2), y: rect.midY)
                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime + 0.02, windowNumber: window.windowNumber,
                      context: nil, eventNumber: 2, clickCount: 1, pressure: 0)
                else { throw DriverError("could not create file click") }
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
            case "codeAdjacent":
                model.activeEditor?.selectAdjacentDocument(step["offset"]?.int ?? 1)
            case "codePDFState":
                guard let view = window()?.contentView, let pdf = pdfView(in: view),
                      let document = pdf.document, document.pageCount > 0,
                      pdf.bounds.width > 0, pdf.bounds.height > 0,
                      let page = document.page(at: 0),
                      page.string?.contains(step["contains"]?.string ?? "") == true
                else { throw DriverError("PDF content is not loaded in the preview") }
                log("PDF preview loaded: pages=\(document.pageCount) scale=\(pdf.scaleFactor)")
            case "browserOpen", "browserTool", "browserMCP", "browserJS", "browserAttach", "browserState", "browserWait", "browserViewport", "browserNewTab", "browserCheck", "browserFind", "browserMoveTab", "browserPrepareDownload", "browserSaveDownload":
                guard let meta = model.selectedSession, let project = model.project(for: meta) else { throw DriverError("no project") }
                let browser = model.browser(for: project)
                switch step["op"]?.string {
                case "browserOpen":
                    model.projectTabs[project.id] = .browser
                    browser.navigate(step["url"]?.string ?? "")
                case "browserViewport": browser.viewport = step["value"]?.string ?? "Desktop"
                case "browserNewTab":
                    let url = try BrowserAddress.resolve(step["url"]?.string ?? "", projectRoot: project.url)
                    browser.newPage(url: url)
                case "browserWait":
                    // A DOM click queues navigation after its JavaScript reply.
                    try await pause(0.2)
                    let deadline = Date().addingTimeInterval(20)
                    while browser.selectedPage?.isLoading == true, Date() < deadline { try await pause(0.1) }
                    try await pause(0.1)
                    if let error = browser.selectedPage?.navigationError { throw DriverError(error) }
                    if browser.selectedPage?.isLoading == true { throw DriverError("browser load timed out") }
                case "browserTool", "browserMCP":
                    let request: JSONValue = ["name": step["name"] ?? "browser_snapshot", "arguments": step["arguments"] ?? [:]]
                    let result = step["op"]?.string == "browserMCP"
                        ? try await browserMCPCall(request, browser: browser) : await browser.performTool(request)
                    if result["isError"]?.bool == true, step["allowFailure"]?.bool != true {
                        throw DriverError(result["content"]?[0]?["text"]?.string ?? "browser tool failed")
                    }
                    let types = result["content"]?.array?.compactMap { $0["type"]?.string } ?? []
                    log("browser tool \(step["name"]?.string ?? "") error=\(result["isError"]?.bool ?? false) types=\(types) text=\(result["content"]?.array?.compactMap { $0["text"]?.string }.joined().prefix(1600) ?? "")")
                case "browserJS":
                    let value = try await browser.selectedPage?.evaluate(step["script"]?.string ?? "return null;")
                    if let expected = step["expect"], value != expected { throw DriverError("Unexpected browser script result: \(String(describing: value))") }
                case "browserFind":
                    browser.selectedPage?.findText = step["text"]?.string ?? ""
                    browser.selectedPage?.find()
                    try await pause(0.3)
                case "browserPrepareDownload":
                    guard let path = step["path"]?.string else { throw DriverError("Missing test destination") }
                    BrowserDownload.destinationForTesting = URL(fileURLWithPath: path)
                case "browserSaveDownload":
                    let deadline = Date().addingTimeInterval(10)
                    while browser.downloads.isEmpty, Date() < deadline { try await pause(0.1) }
                    while browser.downloads.first?.isRunning == true, Date() < deadline { try await pause(0.1) }
                    guard let path = step["path"]?.string,
                          browser.downloads.first?.state == .completed else { throw DriverError("Download did not finish") }
                    let destination = URL(fileURLWithPath: path)
                    guard
                          try String(contentsOf: destination, encoding: .utf8) == step["content"]?.string
                    else { throw DriverError("Downloaded content was not saved correctly: \(browser.downloads.first?.status ?? "no download")") }
                case "browserMoveTab":
                    guard let first = browser.pages.first, let last = browser.pages.last else { throw DriverError("No tabs") }
                    browser.moveTab(last.id, before: first.id)
                    guard browser.pages.first?.id == last.id else { throw DriverError("Tab reorder failed") }
                case "browserCheck":
                    if let count = step["tabs"]?.int, browser.pages.count != count { throw DriverError("Expected \(count) browser tabs; got \(browser.pages.count)") }
                    if let count = step["bookmarks"]?.int, browser.library.bookmarks.count != count { throw DriverError("Bookmarks not preserved") }
                    if let count = step["history"]?.int, browser.library.history.count != count { throw DriverError("Unexpected history count: \(browser.library.history.count)") }
                    if let title = step["title"]?.string, browser.selectedPage?.title != title { throw DriverError("Unexpected page title: \(browser.selectedPage?.title ?? "nil")") }
                    if let found = step["found"]?.bool, browser.selectedPage?.findFound != found { throw DriverError("Find returned unexpected result") }
                    if let zoom = step["zoom"]?.double, browser.selectedPage?.zoom != zoom { throw DriverError("Unexpected zoom") }
                    if let error = step["hasError"]?.bool, (browser.selectedPage?.navigationError != nil) != error { throw DriverError("Unexpected navigation error") }
                    if let placeholder = step["focusedField"]?.string {
                        guard let root = window()?.contentView, let field = textField(in: root, placeholder: placeholder),
                              let editor = field.currentEditor(), editor === window()?.firstResponder else { throw DriverError("Browser field is not focused: \(placeholder); responder=\(String(describing: window()?.firstResponder)); sheet=\(String(describing: window()?.attachedSheet)); windows=\(NSApp.windows.map { $0.title })") }
                    }
                    log("Browser checks passed")
                case "browserAttach":
                    browser.comment = step["text"]?.string ?? ""
                    await browser.attachFeedback()
                case "browserState":
                    log("browser state " + String(decoding: try JSONValue.object([
                        "url": .string(browser.selectedPage?.url?.absoluteString ?? ""),
                        "title": .string(browser.selectedPage?.title ?? ""), "tabs": .int(Int64(browser.pages.count)),
                        "agentAccess": .bool(browser.canUseAgent), "error": .string(browser.errorMessage ?? ""),
                        "element": browser.annotation ?? .null,
                    ]).serialized(), as: UTF8.self))
                default: break
                }
            case "browserPolishChecks":
                guard let browser = model.activeBrowser else { throw DriverError("Browser must be selected") }
                try await BrowserPolishChecks.run(browser)
                log("Browser favicon, download failure/retry/cancellation and website-data isolation checks passed")
            case "codeInsert":
                guard let document = model.activeEditor?.selectedDocument,
                    let field = window()?.firstResponder as? CodeEditingTextView, field.documentID == document.id
                else { throw DriverError("code editor is not focused") }
                let range = step["replaceAll"]?.bool == true
                    ? NSRange(location: 0, length: (field.string as NSString).length) : field.selectedRange()
                field.insertText(step["text"]?.string ?? "", replacementRange: range)
            case "codeSave":
                guard let editor = model.activeEditor, let document = editor.selectedDocument else { throw DriverError("no code document") }
                let saved = await editor.save(document)
                if !saved, step["allowFailure"]?.bool != true { throw DriverError(editor.errorMessage ?? "save failed") }
            case "codeRefresh":
                await model.activeEditor?.refresh()
            case "codeUndo":
                guard let field = window()?.firstResponder as? NSTextView, !(field is PromptTextView) else { throw DriverError("editor not focused") }
                field.undoManager?.undo()
            case "codeFind":
                model.activeEditor?.findRequest += 1
            case "codeDiskEdit":
                guard let editor = model.activeEditor, let document = editor.selectedDocument else { throw DriverError("no code document") }
                try Data((step["text"]?.string ?? "").utf8).write(to: editor.root.appendingPathComponent(document.path))
            case "codeState":
                guard let editor = model.activeEditor else { throw DriverError("no code editor") }
                let state: [String: Any] = [
                    "path": editor.selectedDocument?.path ?? "",
                    "text": editor.selectedDocument?.text ?? "",
                    "modified": editor.selectedDocument?.isModified ?? false,
                    "recovered": editor.selectedDocument?.isRecoveredDraft ?? false,
                    "conflict": editor.selectedDocument?.changedOnDisk ?? false,
                    "documents": editor.documents.map(\.path),
                    "preview": editor.selectedDocument?.preview?.url.lastPathComponent ?? "",
                    "navigator": editor.navigatorSelection ?? "",
                    "navigatorVisible": editor.showsNavigator,
                    "navigatorQuery": editor.navigatorQuery,
                    "pendingTrash": editor.pendingTrashPath ?? "",
                    "canGoBack": editor.canGoBack,
                    "canGoForward": editor.canGoForward,
                    "recentFiles": editor.recentFilePaths,
                    "quickOpen": editor.showsQuickOpen,
                    "focusRequested": editor.focusEditorOnSelection,
                    "error": editor.errorMessage ?? "",
                    "responder": window()?.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
                    "focusedDocument": (window()?.firstResponder as? CodeEditingTextView)?.documentID == editor.selectedDocumentID,
                ]
                log("code " + String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self))
            case "search":
                guard let view = window()?.contentView,
                      let field: NSTextField = textField(in: view, placeholder: "Filter projects") ?? searchField(in: view) else {
                    throw DriverError("no sidebar search field")
                }
                field.stringValue = step["text"]?.string ?? ""
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                field.sendAction(field.action, to: field.target)
            case "waitFor":
                try await waitFor(
                    step["what"]?.string ?? "idle", model, timeout: step["timeout"]?.double ?? 90,
                    approving: step["approve"]?.bool ?? false)
            case "answer":
                let session = try await current(model)
                guard let request = session.pendingApproval else { throw DriverError("nothing to answer") }
                session.answer(request, with: decision(step, request))
            case "stop":
                try await current(model).interrupt()
            case "inspector":
                model.showsInspector = step["show"]?.bool ?? true
            case "select":
                model.selectedSessionID = model.workspace.sessions.first?.id
            case "selectProject":
                if let project = model.workspace.projects.first(where: { $0.name == step["name"]?.string }) {
                    model.openProject(project)
                }
            case "projectClick":
                guard let project = model.workspace.projects.first(where: { $0.name == step["name"]?.string }),
                    let window = window(), let root = window.contentView
                else { throw DriverError("project row not found") }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                // Chat can present a native inspector; wait for its window transition before measuring the row.
                try await pause(0.5)
                root.layoutSubtreeIfNeeded()
                guard let row = marker(in: root, named: "project-row-" + project.id.uuidString) else { throw DriverError("project row disappeared") }
                row.scrollToVisible(row.bounds)
                try click(row, in: window)
                for _ in 0..<40 {
                    if model.selectedProject?.id == project.id { return }
                    try await pause(0.05)
                }
                throw DriverError("Project row click did not select " + project.name)
            case "workspaceState":
                guard let root = window()?.contentView else { throw DriverError("no window") }
                let state: [String: Any] = [
                    "projects": model.workspace.projects.map(\.name),
                    "projectRows": model.workspace.projects.filter {
                        marker(in: root, named: "project-row-" + $0.id.uuidString) != nil
                    }.count,
                    "selectedProject": model.selectedSession.flatMap(model.project(for:))?.name ?? "",
                    "selectedSession": model.selectedSessionID?.uuidString ?? "",
                    "sessionCount": model.workspace.sessions.count,
                    "conversationSessions": model.workspace.projects.map {
                        model.workspace.conversation(for: $0.id)?.id.uuidString ?? ""
                    },
                ]
                log("workspace " + String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self))
            case "appearance":
                NSApp.appearance = NSAppearance(named: step["dark"]?.bool == true ? .darkAqua : .aqua)
            case "size":
                window()?.setContentSize(
                    NSSize(width: step["width"]?.double ?? 1240, height: step["height"]?.double ?? 820))
            case "uiState":
                guard let window = window(), let root = window.contentView,
                      let tabs = marker(in: root, named: "workspace-tabs"),
                      let content = marker(in: root, named: "workspace-content")
                else { throw DriverError("project navigation not found") }
                func bounds(_ view: NSView) -> JSONValue {
                    let rect = view.convert(view.bounds, to: nil)
                    return ["x": .double(rect.minX), "y": .double(rect.minY),
                            "width": .double(rect.width), "height": .double(rect.height)]
                }
                func windowControl(_ kind: NSWindow.ButtonType) -> JSONValue {
                    guard let button = window.standardWindowButton(kind) else { return .null }
                    return ["visible": .bool(button.window === window && !button.isHiddenOrHasHiddenAncestor && button.alphaValue > 0),
                            "enabled": .bool(button.isEnabled), "bounds": bounds(button)]
                }
                let composer = textViews(in: root).first { ($0 as? PromptTextView)?.composerActive == true && !$0.isHiddenOrHasHiddenAncestor }?.enclosingScrollView
                let prompt = composer?.documentView as? NSTextView
                let usedHeight = prompt.flatMap { view -> CGFloat? in
                    guard let manager = view.layoutManager, let container = view.textContainer else { return nil }
                    manager.ensureLayout(for: container)
                    return manager.usedRect(for: container).height + view.textContainerInset.height * 2
                }
                let state: JSONValue = ["windowWidth": .double(root.bounds.width), "tabs": bounds(tabs),
                    "titleHidden": .bool(window.titleVisibility == .hidden),
                    "toolbarVisible": .bool(window.toolbar?.isVisible == true),
                    "windowControls": ["close": windowControl(.closeButton),
                                       "minimize": windowControl(.miniaturizeButton),
                                       "fullScreen": windowControl(.zoomButton)],
                    "fullScreen": .bool(window.styleMask.contains(.fullScreen)),
                    "projectsVisible": .bool(model.showsProjectSidebar),
                    "content": bounds(content),
                    "tab": .string(model.selectedSession.flatMap { model.projectTabs[$0.projectID]?.rawValue } ?? "Conversation"),
                    "composer": composer.map(bounds) ?? .null,
                    "speed": marker(in: root, named: "composer-speed").map(bounds) ?? .null,
                    "composerUsedHeight": usedHeight.map { .double($0) } ?? .null,
                    "composerScrollY": composer.map { .double($0.contentView.bounds.minY) } ?? .null,
                    "composerFocused": .bool(window.firstResponder is PromptTextView)]
                log("ui " + String(decoding: try state.serialized(), as: UTF8.self))
            case "shot":
                try snapshot(to: step["path"]?.string ?? "shot.png", title: step["window"]?.string, sheet: step["sheet"]?.bool ?? false)
            case "capture":
                // A true capture, because `shot` can't see Liquid Glass.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l\(window()?.windowNumber ?? 0)", step["path"]?.string ?? "capture.png"]
                try process.run()
                process.waitUntilExit()
                log("capture exit \(process.terminationStatus)")
            case "state":
                let session = try await current(model)
                let summary: [String: Any] = [
                    "phase": session.phase.rawValue,
                    "items": session.items.count,
                    "draft": session.draft,
                    "draftImages": session.draftImages.map(\.path),
                    "sessionID": session.id.uuidString,
                    "sessions": model.workspace.sessions.count,
                    "agent": session.meta.agent.rawValue,
                    "composerFocused": window()?.firstResponder is PromptTextView,
                    "mode": session.meta.mode.rawValue,
                    "serviceTier": session.meta.serviceTier ?? "",
                    "effort": session.meta.effort ?? "",
                    "cost": session.meta.totalCostUSD ?? -1,
                    "lastText": session.items.compactMap {
                        if case .assistant(let text) = $0.content { text } else { nil }
                    }.last ?? "",
                    "todos": session.todos.map(\.text),
                    "tools": session.items.compactMap(\.tool).map { "\($0.name):\($0.status.rawValue)" },
                    "conversation": session.meta.conversationID ?? "",
                    "plan": model.statuses[session.meta.agent]?.plan ?? "",
                    "usage": model.rateLimits[session.meta.agent]?.windows.first?.utilization ?? -1,
                    "models": model.capabilities[session.meta.agent]?.models.map(\.id) ?? [],
                ]
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                log("state " + String(decoding: data, as: UTF8.self))
            case "shortcut":
                guard let window = window(), let key = step["key"]?.string else { throw DriverError("shortcut needs a key") }
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
                try await pause(0.1)
                // Headless runs can be denied foreground activation. Give SwiftUI's
                // native menu system the same focused-window notifications instead.
                if !window.isKeyWindow { window.becomeKey() }
                if !window.isMainWindow { window.becomeMain() }
                try await pause(0.1)
                NSApp.mainMenu?.update()
                var flags: NSEvent.ModifierFlags = [.command]
                if step["shift"]?.bool == true { flags.insert(.shift) }
                if step["option"]?.bool == true { flags.insert(.option) }
                if step["control"]?.bool == true { flags.insert(.control) }
                func matchingItems(_ menu: NSMenu) -> [NSMenuItem] {
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.update()
                    return menu.items.flatMap { item in
                        let match = item.keyEquivalent.lowercased() == key.lowercased() && item.keyEquivalentModifierMask == flags
                        return (match ? [item] : []) + (item.submenu.map(matchingItems) ?? [])
                    }
                }
                if let menu = NSApp.mainMenu {
                    log("shortcut " + matchingItems(menu).map { "\($0.title): enabled=\($0.isEnabled)" }.joined(separator: ", "))
                    // Synthetic NSMenu events can choose a shifted sibling (e.g.
                    // Search Project instead of Find). Verify the exact binding
                    // and invoke its native action when a check requests it.
                    if step["exactMenu"]?.bool == true {
                        guard let item = matchingItems(menu).first(where: \.isEnabled), let action = item.action,
                              NSApp.sendAction(action, to: item.target, from: item)
                        else { throw DriverError("No enabled menu action for shortcut \(key)") }
                        return
                    }
                }
                let codes: [String: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "[": 33, "]": 30, "\\": 42, "e": 14, "f": 3, "l": 37, "t": 17, "w": 13, "r": 15, "d": 2, "y": 16, "+": 24, "-": 27]
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: codes[key] ?? 0),
                    NSApp.mainMenu?.performKeyEquivalent(with: event) == true
                else { throw DriverError("shortcut ⌘\(key) was not handled") }
            case "key":
                // Goes through the same path as a real key press.
                guard let window = window()?.attachedSheet ?? window() else { throw DriverError("no window") }
                log("first responder: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
                let code = UInt16(step["code"]?.int ?? 36)
                let text: String
                switch code {
                case 53: text = "\u{1b}"
                case 123: text = "\u{F702}"
                case 124: text = "\u{F703}"
                case 125: text = "\u{F701}"
                case 126: text = "\u{F700}"
                default: text = "\r"
                }
                let flags: NSEvent.ModifierFlags = step["shift"]?.bool == true ? .shift : []
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard
                        let event = NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: flags,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
                            keyCode: code)
                    else { continue }
                    if step["application"]?.bool == true { NSApp.postEvent(event, atStart: false) }
                    else { window.sendEvent(event) }
                }
                if step["application"]?.bool == true { try await pause(0.15) }
            case "scroll":
                // A real wheel event, so it counts as the user scrolling.
                guard let window = window(),
                    let cgEvent = CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: Int32(step["pixels"]?.int ?? 400), wheel2: 0, wheel3: 0)
                else { throw DriverError("no window") }
                cgEvent.location = CGPoint(x: window.frame.midX, y: NSScreen.main!.frame.height - window.frame.midY)
                guard let event = NSEvent(cgEvent: cgEvent) else { throw DriverError("no event") }
                // The app drops the event when inactive, so also hand it straight to the window.
                NSApp.sendEvent(event)
                window.sendEvent(event)
            case "newSession":
                model.newSessionInCurrentProject()
            case "settingsWindow":
                NotificationCenter.default.post(name: openSettingsRequest, object: nil)
                try await pause(1.5)
                log("windows: \(NSApp.windows.map { "\($0.title)[\(Int($0.frame.width))x\(Int($0.frame.height)) visible=\($0.isVisible)]" })")
            case "quit":
                await model.shutdown()
                exit(0)
            case "exitWithoutSaving":
                // Simulate a process exit without the normal final workspace/transcript save.
                exit(0)
            default:
                throw DriverError("unknown step: \(step)")
            }
        }

        private static func testMarkdown(_ step: JSONValue, _ model: AppModel) async throws {
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

        private static func testProjectChat(_ step: JSONValue, _ model: AppModel) async throws {
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

        private static func decision(_ step: JSONValue, _ request: ApprovalRequest) -> ApprovalDecision {
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

        private static func waitFor(_ what: String, _ model: AppModel, timeout: Double, approving: Bool) async throws {
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

        private static func testNavigationLinks(_ step: JSONValue, _ model: AppModel) async throws {
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
            guard let terminalView = model.terminals[project.id]?.current?.view, let terminalWindow = terminalView.window else { throw DriverError("No terminal view") }
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

        private static func testMCPOAuth(_ step: JSONValue, _ model: AppModel) async throws {
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

        private static func testMCPManager(_ step: JSONValue, _ model: AppModel) async throws {
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

        private static func testInlineReview(_ step: JSONValue, _ model: AppModel) async throws {
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

        private static func testInlineAssistance(_ step: JSONValue, _ model: AppModel) async throws {
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

        private static func testProjectTabs(_ step: JSONValue, _ model: AppModel) async throws {
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
                  let addView = marker(in: root, named: "workspace-new-view"), header.bounds.height <= 43,
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

        private static func editSpaceUI(name: String, color: String, editing id: UUID? = nil, model: AppModel) async throws {
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

        private static func testSpaces(_ step: JSONValue, _ model: AppModel) async throws {
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

        private static func testChatHistoryUpdates(_ step: JSONValue, _ model: AppModel) async throws {
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

        private static func window() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        }

        private static func browserMCPCall(_ request: JSONValue, browser: BrowserWorkspace, sessionID: UUID? = nil) async throws -> JSONValue {
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


        private static func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for child in view.subviews {
                if let field = searchField(in: child) { return field }
            }
            return nil
        }

        private static func textField(in view: NSView, placeholder: String) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
            for child in view.subviews {
                if let field = textField(in: child, placeholder: placeholder) { return field }
            }
            return nil
        }

        private static func marker(in view: NSView, named name: String) -> NSView? {
            if view.identifier?.rawValue == name, !view.isHiddenOrHasHiddenAncestor,
               view.bounds.width > 1, view.bounds.height > 1 { return view }
            for child in view.subviews {
                if let marker = marker(in: child, named: name) { return marker }
            }
            return nil
        }

        private static func click(_ view: NSView, in window: NSWindow, fractionX: CGFloat = 0.5) throws {
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

        private static func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }

        private static func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
        }

        private static func resolveAgentReferences(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text) where text.hasPrefix("$"):
                agentReferences[String(text.dropFirst())].map { .string($0.uuidString) } ?? value
            case .array(let array): .array(array.map(resolveAgentReferences))
            case .object(let object): .object(object.mapValues(resolveAgentReferences))
            default: value
            }
        }

        private static func pdfView(in view: NSView) -> PDFView? {
            if let pdf = view as? PDFView { return pdf }
            return view.subviews.lazy.compactMap { pdfView(in: $0) }.first
        }

        private static func snapshot(to path: String, title: String?, sheet: Bool = false) throws {
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

    private actor DebugTaskAgent: AgentSession {
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
