#if DEBUG
    import AppKit
    import MarikaCore
    import PDFKit
    import SwiftUI

    extension DebugDriver {
        static func runWorkspaceStep(_ step: JSONValue, _ model: AppModel) async throws -> Bool {
            switch step["op"]?.string {
            case "researchSection":
                model.switchPanel(.research)
                try await pause(0.2)
                guard let window = window(), let root = window.contentView,
                      let picker = marker(in: root, named: "research-sections") else { throw DriverError("Research sections not found") }
                try click(picker, in: window, fractionX: (CGFloat(step["index"]?.int ?? 0) + 0.5) / 3)
                try await pause(0.2)
            case "sixLayout":
                try await DebugWorkspaceSixChecks.layout(model, name: step["name"]?.string ?? "Design")
            case "sixImportReference":
                try await DebugWorkspaceSixChecks.importReference(model, source: step["source"]?.string ?? "index.html", agent: AgentKind(rawValue: step["agent"]?.string ?? "claude") ?? .claude, screenshot: step["screenshot"]?.string, modelID: step["model"]?.string)
            case "sixCaptureImportReference":
                guard let project = model.selectedProject else { throw DesignToolError("Project missing") }
                let importer = DesignImportModel(projectID: project.id, app: model)
                await importer.capturePreview()
                guard let data = importer.referenceImage, let path = step["path"]?.string else {
                    throw DesignToolError(importer.error ?? "Reference unavailable")
                }
                try data.write(to: URL(fileURLWithPath: path))
            case "sixImportExport":
                try await DebugWorkspaceSixChecks.exportImport(model, directory: step["directory"]?.string ?? "")
            case "sixMetrics":
                try await DebugWorkspaceSixChecks.metrics(model)
            case "pipelineRun":
                guard let project = model.selectedProject,
                      let job = try await PipelineDiscovery.jobs(at: project.url).first(where: { $0.job == step["job"]?.string })
                else { throw DriverError("pipeline job missing") }
                if let reason = job.reason { throw DriverError(reason) }
                model.runPipeline(job, project: project, image: step["image"]?.string ?? "node:24")
                while model.projectRuntimeTools[project.id]?.pipeline?.active != nil {
                    try await Task.sleep(for: .milliseconds(200))
                }
                log("pipeline " + (model.project(id: project.id)?.pipelineRuns?.last?.status ?? "missing"))
            case "layoutState":
                guard let project = model.selectedProject else { throw DriverError("no project") }
                let layout = model.layout(for: project.id)
                let editor = model.editors[project.id]
                let browser = model.projectRuntimeTools[project.id]?.browser
                let value: [String: Any] = ["primary": model.projectTabs[project.id]?.rawValue ?? "Conversation",
                    "secondary": layout.secondary?.rawValue ?? "", "stacked": layout.stacked, "fraction": layout.splitFraction,
                    "files": editor?.documents.map(\.path) ?? [], "selectedFile": editor?.selectedDocument?.path ?? "",
                    "draft": editor?.selectedDocument?.text ?? "", "conflict": editor?.selectedDocument?.changedOnDisk ?? false,
                    "browserURLs": browser?.pages.map { $0.url?.absoluteString ?? "" } ?? [], "viewport": browser?.viewport ?? ""]
                log("layout " + String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
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
            case "storageState":
                let state: [String: Any] = ["label": step["label"]?.string ?? "", "loadFailed": model.workspaceLoadFailed,
                    "error": model.storageError ?? "", "recovery": model.storageRecoveryNotice ?? ""]
                log("storage " + String(decoding: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), as: UTF8.self))
            case "storageRetry": await model.retryStorage()
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
                log("project tab \(model.projectTabs[meta.projectID]?.rawValue ?? "Conversation") browser=\(model.projectRuntimeTools[meta.projectID]?.browser != nil)")
            case "projectChatTest":
                try await testProjectChat(step, model)
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
            case "attentionTest":
                try await DebugAttentionChecks.run(step, model: model)
                log("Attention inbox " + (step["phase"]?.string ?? "") + " passed")
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
                    if model.selectedProject?.id == project.id { return true }
                    try await pause(0.05)
                }
                throw DriverError("Project row click did not select " + project.name)
            default: return false
            }
            return true
        }
    }
#endif
