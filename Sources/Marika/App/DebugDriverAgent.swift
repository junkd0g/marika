#if DEBUG
    import AppKit
    import MarikaCore
    import PDFKit
    import SwiftUI

    extension DebugDriver {
        static func runAgentStep(_ step: JSONValue, _ model: AppModel) async throws -> Bool {
            switch step["op"]?.string {
            case "agent":
                let session = try await current(model)
                model.setAgent(AgentKind(rawValue: step["agent"]?.string ?? "") ?? .claude, for: session.id)
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
                    guard (session.meta.taskVerification?.succeeded == true) == expected else { throw DriverError("Unexpected verification result: " + (session.meta.taskVerification?.output ?? "No result recorded")) }
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
            case "mcpManagerTest":
                try await testMCPManager(step, model)
            case "mcpOAuthTest":
                try await testMCPOAuth(step, model)
            case "agentsMock":
                let seconds = step["seconds"]?.double ?? 1
                model.agentFactoryOverride = { _ in DebugTaskAgent(seconds: seconds) }
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
                    if model.projectRuntimeTools[project.id]?.debugTask == nil { break }
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
            case "waitFor":
                try await waitFor(
                    step["what"]?.string ?? "idle", model, timeout: step["timeout"]?.double ?? 90,
                    approving: step["approve"]?.bool ?? false)
            case "answer":
                let session = try await current(model)
                guard let request = session.pendingApproval else { throw DriverError("nothing to answer") }
                session.answer(request, with: decision(step, request))
            default: return false
            }
            return true
        }
    }
#endif
