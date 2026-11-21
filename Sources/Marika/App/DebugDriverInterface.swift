#if DEBUG
    import AppKit
    import MarikaCore
    import PDFKit
    import SwiftUI

    extension DebugDriver {
        static func runInterfaceStep(_ step: JSONValue, _ model: AppModel) async throws -> Bool {
            switch step["op"]?.string {
            case "wait":
                try await pause(step["seconds"]?.double ?? 1)
            case "open":
                model.addProject(at: URL(fileURLWithPath: step["path"]?.string ?? ""))
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
                guard let output = model.projectRuntimeTools[project.id]?.terminal?.output(), output.contains("MARIKA_TERMINAL_OK"), output.contains(project.url.lastPathComponent) else { throw DriverError("Interactive terminal output missing") }
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
            case "toolRoutingTest":
                try await DebugToolRoutingChecks.run(model)
                log("Tool routing passed: caller isolation, knowledge review, publishers, API merge, scans and child-agent scope")
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
            case "toolQuery":
                guard let sheet = window()?.attachedSheet, let root = sheet.contentView else { throw DriverError("no tool sheet") }
                let placeholder = model.showsCommandPalette ? "What would you like to do?" : "Search in \(model.selectedProject?.name ?? "")…"
                guard let field = textField(in: root, placeholder: placeholder) else { throw DriverError("tool query field not found") }
                sheet.makeFirstResponder(field)
                guard let editor = field.currentEditor() as? NSTextView else { throw DriverError("tool query not editable") }
                editor.insertText(step["text"]?.string ?? "", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            case "assertMarker":
                let name = step["name"]?.string ?? ""
                for _ in 0..<40 {
                    let present = NSApp.windows.filter(\.isVisible).contains { $0.contentView.flatMap { marker(in: $0, named: name) } != nil }
                    if present == (step["present"]?.bool ?? true) { return true }
                    try await pause(0.05)
                }
                throw DriverError("Unexpected visibility for " + name)
            case "clickMarker":
                let name = step["name"]?.string ?? ""
                guard let target = NSApp.windows.filter(\.isVisible).compactMap({ window in window.contentView.flatMap { marker(in: $0, named: name) }.map { (window, $0) } }).first else { throw DriverError("Missing UI element: " + name) }
                if step["scroll"]?.bool == true { target.1.scrollToVisible(target.1.bounds); try await pause(0.15) }
                try click(target.1, in: target.0, fractionX: CGFloat(step["fraction"]?.double ?? 0.5))
                try await pause(0.3)
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
            case "search":
                guard let view = window()?.contentView,
                      let field: NSTextField = textField(in: view, placeholder: "Filter projects") ?? searchField(in: view) else {
                    throw DriverError("no sidebar search field")
                }
                field.stringValue = step["text"]?.string ?? ""
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                field.sendAction(field.action, to: field.target)
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
                        return true
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
            default: return false
            }
            return true
        }
    }
#endif
