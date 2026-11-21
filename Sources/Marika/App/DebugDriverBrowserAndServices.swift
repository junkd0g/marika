#if DEBUG
    import AppKit
    import MarikaCore
    import PDFKit
    import SwiftUI

    extension DebugDriver {
        static func runBrowserAndServicesStep(_ step: JSONValue, _ model: AppModel) async throws -> Bool {
            switch step["op"]?.string {
            case "browserAgentAccessTest":
                try await DebugBrowserAccessChecks.run(model)
                log("Browser agent access passed: all-site default, opt-out, safe addresses, bridge gating, and persistence")
            case "browserAgentAccessRestoreTest":
                try DebugBrowserAccessChecks.restored(model)
                log("Browser agent access restored after restart")
            case "qaPrepareCIFixture":
                try await DebugImprovementChecks.prepareCI(model, directory: URL(fileURLWithPath: step["directory"]?.string ?? ""))
            case "qaImportCIFixture":
                try await DebugImprovementChecks.importCI(model, report: URL(fileURLWithPath: step["report"]?.string ?? ""),
                    trace: URL(fileURLWithPath: step["trace"]?.string ?? ""))
                log("Playwright import, trace persistence, and bug link passed")
            case "incidentAndShutdownTest":
                try await DebugImprovementChecks.incidentAndShutdown(model)
                log("Incident evidence and isolated shutdown passed")
            case "qaSection":
                guard let project = model.selectedProject, let section = step["section"]?.string,
                      ["Cases", "Runs", "Release"].contains(section) else { throw DriverError("QA section unavailable") }
                model.openProject(project, tab: .qa)
                let qa = model.qa(for: project)
                if step["refreshFixtureSnapshots"]?.bool == true, DebugFixtureSettings.value("MARIKA_DATA") != nil {
                    let snapshot = try await VerificationSnapshot.capture(at: project.url)
                    for index in qa.data.runs.indices where qa.data.runs[index].snapshot != nil {
                        qa.data.runs[index].snapshot = snapshot
                    }
                }
                qa.section = section
            case "qaTest":
                try await DebugQAChecks.run(model)
                log("QA passed: case approval, immutable run definitions, incomplete results, bug links, idempotency, AI drafts and persistence")
            case "qaRegressionTest":
                try await DebugQAChecks.regressions(model)
                log("QA regressions passed: failed comparison invalidation and evidence limits")
            case "qaRestoreTest":
                try DebugQAChecks.restored(model)
                log("QA panel and saved runs restored")
            case "containersPrepare":
                try await DebugContainersChecks.prepare(model)
            case "containersLogsPreview":
                try await DebugContainersChecks.previewLogs(model, name: step["name"]?.string ?? "")
            case "containersCheck":
                try await DebugContainersChecks.check(step["phase"]?.string ?? "", model)
                log("Containers " + (step["phase"]?.string ?? "") + " passed")
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
                    if marker(in: view, named: "api-response-ok") != nil { return true }
                    try await pause(0.1)
                }
                throw DriverError("No successful response in API view")
            case "apiGenerate", "apiCompose", "apiRequest":
                guard let project = model.selectedProject else { throw DriverError("no project") }
                let api = model.projectRuntimeTools[project.id]?.api ?? APIWorkspace()
                model.runtimeTools(for: project.id).api = api
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
            case "browserAddress":
                guard let window = window(), let view = window.contentView,
                      let field = textField(in: view, placeholder: "Search or enter address")
                else { throw DriverError("browser address field not found") }
                window.makeFirstResponder(field)
                guard let input = field.currentEditor() as? NSTextView else { throw DriverError("browser address field is not editable") }
                input.insertText(step["text"]?.string ?? "", replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
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
            default: return false
            }
            return true
        }
    }
#endif
