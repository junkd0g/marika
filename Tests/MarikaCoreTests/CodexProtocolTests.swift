import Foundation
import Testing

@testable import MarikaCore

/// Runs the real `CodexSession` against a scripted app-server that follows the published schema.
/// This proves both directions of the protocol, but it is not a substitute for the real binary.
@MainActor
struct CodexProtocolTests {
    private struct Harness {
        var controller: SessionController
        var log: URL

        func sent() throws -> [JSONValue] {
            let text = try String(contentsOf: log, encoding: .utf8)
            return try text.split(separator: "\n").map { try JSONValue(parsing: Data($0.utf8)) }
        }

        func request(_ method: String) throws -> JSONValue {
            try #require(try sent().first { $0["method"]?.string == method })
        }
    }

    private func environment(log: URL, extra: [String: String] = [:]) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "FAKE_CODEX_LOG": log.path, "HOME": NSHomeDirectory()].merging(extra) { _, new in new }
    }

    private func installFake() throws -> (executable: URL, log: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: Fixture.url("fake-codex.py"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let log = directory.appendingPathComponent("sent.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        return (executable, log)
    }

    private func makeHarness(
        mode: ApprovalMode = .ask, conversationID: String? = nil, instructions: String = "", extra: [String: String] = [:]
    ) throws -> Harness {
        let (executable, log) = try installFake()
        let directory = executable.deletingLastPathComponent()
        let environment = environment(log: log, extra: extra)
        let meta = SessionMeta(projectID: UUID(), agent: .codex, conversationID: conversationID, mode: mode)
        let controller = SessionController(meta: meta) { meta in
            var launch = AgentLaunch(executable: executable, environment: environment, workingDirectory: directory,
                conversationID: meta.conversationID, settings: meta.settings)
            launch.projectInstructions = instructions
            return CodexSession(launch: launch)
        }
        return Harness(controller: controller, log: log)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out")
        throw CancellationError()
    }

    @Test func projectPlaybooksReachTheAgentThread() async throws {
        let harness = try makeHarness(instructions: "Always explain test evidence.")
        harness.controller.send(UserInput(text: "Review this project"))
        try await waitUntil { harness.controller.pendingApproval != nil }
        #expect(try harness.request("thread/start")["params"]?["developerInstructions"]?.string == "Always explain test evidence.")
        await harness.controller.shutdown()
    }

    @Test func aFullTurnWithApprovals() async throws {
        let harness = try makeHarness()
        let session = harness.controller
        session.send(UserInput(text: "run the tests"))

        try await waitUntil { session.pendingApproval != nil }
        let command = try #require(session.pendingApproval)
        #expect(command.title == "Run this command?")
        #expect(command.detail == "npm test", "the shell wrapper should be stripped")
        #expect(command.reason == "Codex says: Runs project code")
        #expect(session.phase == .waitingForUser)
        #expect(session.todos.map(\.text) == ["Run tests", "Fix bug"])
        session.answer(command, with: .allow())

        try await waitUntil { session.pendingApproval != nil }
        let edit = try #require(session.pendingApproval)
        #expect(edit.title == "Apply this edit?")
        #expect(edit.diff.count == 2)
        session.answer(edit, with: .allow(remember: edit.rememberOptions.first))

        try await waitUntil { !session.turnEnds.isEmpty }
        #expect(session.assistantText == ["All green."])
        #expect(session.meta.conversationID == "thr_1")
        #expect(session.turnEnds.first?.outcome == .completed)
        #expect(session.turnEnds.first?.durationMs == 1234)

        let tools = session.tools
        #expect(tools.count == 2)
        #expect(tools[0].kind == .shell)
        #expect(tools[0].status == .succeeded)
        #expect(tools[0].output == "1 passing\n")
        #expect(tools[1].kind == .edit)
        #expect(tools[1].status == .succeeded)
        #expect(tools[1].diff.count == 2)
        #expect(tools[1].diff[0].additions == 1)
        #expect(tools[1].diff[1].additions == 2)
        #expect(session.context?.fraction == 0.5)

        let replies = try harness.sent().filter { $0["method"] == nil }
        #expect(replies.first { $0["id"]?.int == 900 }?["result"]?["decision"]?.string == "accept")
        #expect(replies.first { $0["id"]?.int == 901 }?["result"]?["decision"]?.string == "acceptForSession")
        await session.shutdown()
    }

    @Test func overlappingSendsShareOneThread() async throws {
        let harness = try makeHarness()
        let session = harness.controller
        session.send(UserInput(text: "first"))
        session.send(UserInput(text: "second"))
        try await waitUntil { session.pendingApproval != nil }
        try await waitUntil { (try? harness.sent().count { $0["method"]?.string == "turn/start" }) == 2 }

        let sent = try harness.sent()
        #expect(sent.count { $0["method"]?.string == "thread/start" } == 1)
        #expect(sent.count { $0["method"]?.string == "initialize" } == 1)
        await session.shutdown()
    }

    @Test func requestsMatchTheSchema() async throws {
        let harness = try makeHarness(mode: .acceptEdits)
        let session = harness.controller
        session.update(settings: AgentSettings(model: "gpt-test", effort: "high", mode: .acceptEdits))
        session.send(UserInput(text: "hello", images: [ImageAttachment(path: "/tmp/shot.png", mediaType: "image/png")]))
        try await waitUntil { session.pendingApproval != nil }

        let initialize = try harness.request("initialize")
        #expect(initialize["params"]?["clientInfo"]?["name"]?.string == "marika")
        #expect(try harness.sent().contains { $0["method"]?.string == "initialized" })

        let thread = try harness.request("thread/start")
        #expect(thread["params"]?["sandbox"]?.string == "read-only", "a writable start would trust the folder for good")
        #expect(thread["params"]?["approvalPolicy"]?.string == "untrusted")
        #expect(thread["params"]?["approvalsReviewer"]?.string == "user")
        #expect(thread["params"]?["model"]?.string == "gpt-test")

        let turn = try #require(try harness.request("turn/start")["params"])
        #expect(turn["threadId"]?.string == "thr_1")
        #expect(turn["effort"]?.string == "high")
        #expect(turn["sandboxPolicy"]?["type"]?.string == "workspaceWrite")
        #expect(turn["sandboxPolicy"]?["writableRoots"]?.array?.count == 1)
        #expect(turn["input"]?[0]?["type"]?.string == "text")
        #expect(turn["input"]?[0]?["text_elements"]?.array?.isEmpty == true)
        #expect(turn["input"]?[1]?["type"]?.string == "localImage")
        await session.shutdown()
    }

    @Test func denyingStopsTheTurn() async throws {
        let harness = try makeHarness()
        let session = harness.controller
        session.send(UserInput(text: "run the tests"))
        try await waitUntil { session.pendingApproval != nil }
        session.answer(try #require(session.pendingApproval), with: .deny)

        try await waitUntil { !session.turnEnds.isEmpty }
        #expect(session.tools.first?.status == .denied)
        #expect(session.turnEnds.first?.outcome == .interrupted)
        #expect(session.notices.isEmpty)
        await session.shutdown()
    }

    @Test func resumingUsesTheSavedThread() async throws {
        let harness = try makeHarness(conversationID: "thr_saved")
        let session = harness.controller
        session.send(UserInput(text: "continue"))
        try await waitUntil { session.pendingApproval != nil }
        #expect(try harness.request("thread/resume")["params"]?["threadId"]?.string == "thr_saved")
        #expect(try !harness.sent().contains { $0["method"]?.string == "thread/start" })
        await session.shutdown()
    }

    @Test func statusReadsPlanModelsAndUsage() async throws {
        let (executable, log) = try installFake()
        let probe = await CodexCLI.probe(executable: executable, environment: environment(log: log))
        #expect(probe.status.readiness == .ready)
        #expect(probe.status.plan == "ChatGPT Plus")
        #expect(probe.status.account == "dev@example.com")
        #expect(probe.capabilities?.models.map(\.id) == ["gpt-test"], "hidden models stay hidden")
        #expect(probe.capabilities?.models.first?.efforts == ["low", "high"])
        #expect(probe.capabilities?.models.first?.isDefault == true)
        #expect(probe.capabilities?.commands.map(\.name) == ["compact", "review"])
        #expect(probe.rateLimit?.windows.first?.utilization == 0.2, "the meter should show before the first turn")
    }

    @Test func aCrashSurfacesAndLeavesTheSessionUsable() async throws {
        let (_, log) = try installFake()
        let script = log.deletingLastPathComponent().appendingPathComponent("crash")
        try "#!/bin/sh\necho boom >&2\nexit 3\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let environment = environment(log: log)
        let meta = SessionMeta(projectID: UUID(), agent: .codex)
        let session = SessionController(meta: meta) { meta in
            CodexSession(
                launch: AgentLaunch(
                    executable: script, environment: environment,
                    workingDirectory: script.deletingLastPathComponent(), settings: meta.settings))
        }
        session.send(UserInput(text: "hello"))
        try await waitUntil { !session.notices.isEmpty }
        #expect(session.notices.first?.level == .error)
        #expect(session.phase == .idle)
    }

    @Test func planNamesReadProperly() {
        #expect(CodexCLI.planName("promax") == "ChatGPT Pro Max")
        #expect(CodexCLI.planName("plus") == "ChatGPT Plus")
        #expect(CodexCLI.planName("enterprise_cbp_automation") == "ChatGPT Enterprise Cbp Automation")
    }

    // MARK: Modes

    @Test(arguments: ApprovalMode.allCases)
    func everyModeStartsTheThreadReadOnly(mode: ApprovalMode) async throws {
        let harness = try makeHarness(mode: mode, extra: ["FAKE_SCRIPT": "quiet"])
        let session = harness.controller
        session.send(UserInput(text: "hi"))
        try await waitUntil { !session.turnEnds.isEmpty }
        #expect(try harness.request("thread/start")["params"]?["sandbox"]?.string == "read-only")
        await session.shutdown()
    }

    @Test(arguments: [
        (ApprovalMode.ask, "untrusted", "workspaceWrite"), (.acceptEdits, "untrusted", "workspaceWrite"),
        (.plan, "on-request", "readOnly"), (.auto, "on-request", "workspaceWrite"), (.bypass, "never", "dangerFullAccess"),
    ])
    func modesSendTheirPolicyOnEachTurn(mode: ApprovalMode, policy: String, sandbox: String) async throws {
        let harness = try makeHarness(mode: mode, extra: ["FAKE_SCRIPT": "quiet"])
        let session = harness.controller
        session.send(UserInput(text: "hi"))
        try await waitUntil { !session.turnEnds.isEmpty }
        let turn = try #require(try harness.request("turn/start")["params"])
        #expect(turn["approvalPolicy"]?.string == policy)
        #expect(turn["approvalsReviewer"]?.string == "user", "a config setting must not replace the user as approver")
        #expect(turn["sandboxPolicy"]?["type"]?.string == sandbox)
        await session.shutdown()
    }

    @Test func labelsMatchWhatEachModeDoes() {
        #expect(ApprovalMode.plan.title(for: .codex) == "Read only", "Codex has no plan step to approve")
        #expect(ApprovalMode.plan.title(for: .claude) == "Plan only")
        #expect(ApprovalMode.auto.summary(for: .codex).contains("without asking"))
        #expect(ApprovalMode.auto.summary(for: .codex).contains("any file"), "Neither mode limits what can be read")
        #expect(ApprovalMode.plan.summary(for: .codex).contains("any file"))
        #expect(!ApprovalMode.auto.summary(for: .codex).contains("Asks before going outside it"))
        #expect(ApprovalMode.acceptEdits.summary(for: .codex).contains("Commands still ask"))
        #expect(!ApprovalMode.acceptEdits.summary(for: .claude).contains("commands still ask"), "rm and mv don't ask")
        #expect(ApprovalMode.acceptEdits.summary(for: .claude).contains("rm"))
    }

    @Test func approvedCommandsCanUseTheNetwork() async throws {
        for mode in [ApprovalMode.ask, .acceptEdits] {
            let policy = CodexMode.sandboxPolicy(mode, workingDirectory: "/p", settings: .init())
            #expect(policy["networkAccess"]?.bool == true)
        }
    }

    @Test func autoKeepsTheUsersOwnSandboxSettings() async throws {
        let config = #"{"sandbox_workspace_write":{"network_access":true,"exclude_slash_tmp":true,"exclude_tmpdir_env_var":true}}"#
        let harness = try makeHarness(mode: .auto, extra: ["FAKE_SCRIPT": "quiet", "FAKE_CONFIG": config])
        let session = harness.controller
        session.send(UserInput(text: "hi"))
        try await waitUntil { !session.turnEnds.isEmpty }
        let policy = try #require(try harness.request("turn/start")["params"]?["sandboxPolicy"])
        #expect(policy["networkAccess"]?.bool == true)
        #expect(policy["excludeSlashTmp"]?.bool == true)
        #expect(policy["excludeTmpdirEnvVar"]?.bool == true)
        await session.shutdown()
    }

    @Test func acceptEditsOnlyCoversOrdinaryProjectFiles() async throws {
        let harness = try makeHarness(mode: .acceptEdits, extra: ["FAKE_SCRIPT": "edit-paths"])
        let session = harness.controller
        session.send(UserInput(text: "edit"))
        try await waitUntil { session.approvals.count == 2 }
        let replies = try harness.sent().filter { $0["method"] == nil }
        #expect(replies.first { $0["id"]?.int == 910 }?["result"]?["decision"]?.string == "accept", "an ordinary project file needs no prompt")
        #expect(replies.first { $0["id"]?.int == 911 } == nil, "edits to .git must ask")
        #expect(replies.first { $0["id"]?.int == 912 } == nil, "edits outside the project must ask")
        await session.shutdown()
    }

    @Test func askFirstAsksAboutEveryEdit() async throws {
        let harness = try makeHarness(mode: .ask, extra: ["FAKE_SCRIPT": "edit-paths"])
        let session = harness.controller
        session.send(UserInput(text: "edit"))
        try await waitUntil { session.approvals.count == 3 }
        await session.shutdown()
    }

    @Test func aModeChangeDuringATurnIsShownAsPending() async throws {
        let harness = try makeHarness(mode: .auto)
        let session = harness.controller
        session.send(UserInput(text: "go"))
        try await waitUntil { session.pendingApproval != nil }
        #expect(session.runningMode == .auto)
        var settings = session.meta.settings
        settings.mode = .ask
        session.update(settings: settings)
        #expect(session.runningMode == .auto, "the turn can't change policy, so the app must not imply it did")
        await session.shutdown()
    }

    @Test func approvalsSayWhatAllowReallyMeans() async throws {
        var translator = CodexTranslator(workingDirectory: "/work/app")
        let params: JSONValue = ["itemId": "c1", "threadId": "t", "command": "/bin/zsh -lc 'npm test'", "cwd": "/work/app"]

        translator.turnMode = .auto
        let escalated = try #require(translator.approval(id: "1", method: "item/commandExecution/requestApproval", params: params))
        #expect(escalated.0.title == "Run outside the sandbox?", "on-request only asks to leave the sandbox")
        #expect(escalated.0.notes.first?.contains("full access") == true)

        translator.turnMode = .ask
        let ordinary = try #require(translator.approval(id: "1", method: "item/commandExecution/requestApproval", params: params))
        #expect(ordinary.0.title == "Run this command?")
        #expect(ordinary.0.notes.first?.contains("may retry") == true)
        #expect(ordinary.0.workingDirectory == nil)
    }

    @Test func approvalsFlagCommandsThatRunElsewhere() throws {
        let translator = CodexTranslator(workingDirectory: "/work/app")
        let params: JSONValue = ["itemId": "c1", "command": "/bin/zsh -lc 'ls'", "cwd": "/somewhere/else"]
        let request = try #require(translator.approval(id: "1", method: "item/commandExecution/requestApproval", params: params))
        #expect(request.0.workingDirectory == "/somewhere/else")
    }

    @Test func approvingAShellWarnsItIsASession() throws {
        let translator = CodexTranslator(workingDirectory: "/work/app")
        let params: JSONValue = ["itemId": "c1", "command": "/bin/zsh -lc /bin/sh", "cwd": "/work/app"]
        let request = try #require(translator.approval(id: "1", method: "item/commandExecution/requestApproval", params: params))
        #expect(request.0.notes.contains { $0.contains("interactive session") })
    }

    @Test func theModelsOwnReasonIsAttributed() throws {
        let translator = CodexTranslator(workingDirectory: "/work/app")
        let params: JSONValue = ["itemId": "c1", "command": "/bin/zsh -lc ls", "reason": "Totally safe"]
        let request = try #require(translator.approval(id: "1", method: "item/commandExecution/requestApproval", params: params))
        #expect(request.0.reason == "Codex says: Totally safe")
    }

    @Test func protectedPathsAreNotOrdinaryFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link"), withDestinationURL: outside)

        let base = project.path
        #expect(CodexMode.isOrdinaryProjectFile("\(base)/src/new/file.txt", root: base))
        #expect(CodexMode.isOrdinaryProjectFile("src/relative.txt", root: base))
        #expect(!CodexMode.isOrdinaryProjectFile("\(base)/.git/config", root: base))
        #expect(!CodexMode.isOrdinaryProjectFile("\(base)/sub/.codex/config.toml", root: base))
        #expect(!CodexMode.isOrdinaryProjectFile("\(base)/../outside/x.txt", root: base), "traversal must not count as inside")
        #expect(!CodexMode.isOrdinaryProjectFile("\(base)/link/x.txt", root: base), "a symlink out of the project must not count as inside")
        #expect(!CodexMode.isOrdinaryProjectFile("/etc/hosts", root: base))
    }

    // MARK: Defaults

    @Test func choosingDefaultReallyResetsAnEarlierOverride() async throws {
        let harness = try makeHarness(extra: ["FAKE_SCRIPT": "quiet"])
        let session = harness.controller
        session.update(settings: AgentSettings(model: "gpt-other", effort: "high", mode: .ask))
        session.send(UserInput(text: "one"))
        try await waitUntil { session.turnEnds.count == 1 }
        session.update(settings: AgentSettings(model: nil, effort: nil, mode: .ask))
        session.send(UserInput(text: "two"))
        try await waitUntil { session.turnEnds.count == 2 }

        let turns = try harness.sent().filter { $0["method"]?.string == "turn/start" }
        #expect(turns[0]["params"]?["model"]?.string == "gpt-other")
        #expect(turns[1]["params"]?["model"]?.string == "gpt-test", "omitting it or sending null leaves the override in place")
        #expect(turns[1]["params"]?["effort"]?.string == "low")
        await session.shutdown()
    }

    @Test func theUsersConfigDecidesWhatDefaultMeans() async throws {
        let config = #"{"model":"gpt-config","model_reasoning_effort":"medium"}"#
        let harness = try makeHarness(extra: ["FAKE_SCRIPT": "quiet", "FAKE_CONFIG": config])
        let session = harness.controller
        session.send(UserInput(text: "one"))
        try await waitUntil { !session.turnEnds.isEmpty }
        let turn = try #require(try harness.request("turn/start")["params"])
        #expect(turn["model"]?.string == "gpt-config")
        #expect(turn["effort"]?.string == "medium")
        await session.shutdown()
    }

    // MARK: MCP

    @Test func mcpToolsAskAndAllowRunsThem() async throws {
        let harness = try makeHarness(extra: ["FAKE_SCRIPT": "mcp"])
        let session = harness.controller
        session.send(UserInput(text: "use the tool"))
        try await waitUntil { session.pendingApproval != nil }
        let request = try #require(session.pendingApproval)
        #expect(request.title.contains("lab_echo"))
        #expect(request.detail == "text: hello")
        session.answer(request, with: .allow())
        try await waitUntil { (try? harness.sent().contains { $0["id"]?.int == 920 }) == true }

        let reply = try #require(try harness.sent().first { $0["id"]?.int == 920 && $0["method"] == nil })
        #expect(reply["result"]?["action"]?.string == "accept")
        #expect(reply["result"]?["decision"] == nil, "the command reply shape reads as a rejection here")
        await session.shutdown()
    }

    @Test func allowingAnMCPToolForTheSessionPersistsIt() async throws {
        let harness = try makeHarness(extra: ["FAKE_SCRIPT": "mcp"])
        let session = harness.controller
        session.send(UserInput(text: "use the tool"))
        try await waitUntil { session.pendingApproval != nil }
        let request = try #require(session.pendingApproval)
        session.answer(request, with: .allow(remember: request.rememberOptions.first))
        try await waitUntil { (try? harness.sent().contains { $0["id"]?.int == 920 }) == true }
        let reply = try #require(try harness.sent().first { $0["id"]?.int == 920 && $0["method"] == nil })
        #expect(reply["result"]?["_meta"]?["persist"]?.string == "session")
        await session.shutdown()
    }

    @Test func denyingAnMCPToolAlsoStopsTheTurn() async throws {
        let harness = try makeHarness(extra: ["FAKE_SCRIPT": "mcp"])
        let session = harness.controller
        session.send(UserInput(text: "use the tool"))
        try await waitUntil { session.pendingApproval != nil }
        session.answer(try #require(session.pendingApproval), with: .deny)
        try await waitUntil { (try? harness.sent().contains { $0["method"]?.string == "turn/interrupt" }) == true }
        let reply = try #require(try harness.sent().first { $0["id"]?.int == 920 && $0["method"] == nil })
        #expect(reply["result"]?["action"]?.string == "decline")
        await session.shutdown()
    }

    @Test func stoppingWithAnMCPRequestOpenRepliesInItsShape() async throws {
        let harness = try makeHarness(extra: ["FAKE_SCRIPT": "mcp"])
        let session = harness.controller
        session.send(UserInput(text: "use the tool"))
        try await waitUntil { session.pendingApproval != nil }
        session.interrupt()
        try await waitUntil { (try? harness.sent().contains { $0["id"]?.int == 920 }) == true }
        let reply = try #require(try harness.sent().first { $0["id"]?.int == 920 && $0["method"] == nil })
        #expect(reply["result"]?["action"] != nil)
        await session.shutdown()
    }

    @Test func mcpFormsBecomeQuestionsAndKeepTheirTypes() async throws {
        let harness = try makeHarness(extra: ["FAKE_SCRIPT": "form"])
        let session = harness.controller
        session.send(UserInput(text: "ask me"))
        try await waitUntil { session.pendingApproval != nil }
        let request = try #require(session.pendingApproval)
        guard case .questions(let questions) = request.kind else {
            Issue.record("expected questions, got \(request.kind)")
            return
        }
        #expect(request.detail == "Which colour?")
        #expect(questions.first?.id == "colour", "required fields come first")
        #expect(questions.first?.options.map(\.label) == ["red", "blue"])
        #expect(questions.first?.isOptional == false)
        #expect(questions.first { $0.id == "keep" }?.options.map(\.label) == ["Yes", "No"])
        #expect(questions.first { $0.id == "count" }?.isOptional == true)

        session.answer(request, with: .answers(["colour": ["blue"], "count": ["3"], "keep": ["Yes"]]))
        try await waitUntil { (try? harness.sent().contains { $0["id"]?.int == 930 }) == true }
        let content = try #require(try harness.sent().first { $0["id"]?.int == 930 && $0["method"] == nil }?["result"]?["content"])
        #expect(content["colour"]?.string == "blue")
        #expect(content["count"] == .int(3))
        #expect(content["keep"] == .bool(true))
        await session.shutdown()
    }

    // MARK: Notices

    @Test func failuresAreShownOnceAndSignInIsOffered() {
        var translator = CodexTranslator(workingDirectory: "/p")
        let error: JSONValue = [
            "message": "unexpected status 401", "codexErrorInfo": ["httpConnectionFailed": ["httpStatusCode": 401]],
        ]
        let first = translator.translate(method: "error", params: ["error": error, "willRetry": false])
        let second = translator.translate(method: "turn/completed", params: ["turn": ["id": "t", "status": "failed", "error": error]])
        let notices = (first + second).compactMap { event -> Notice? in
            if case .notice(let notice) = event { notice } else { nil }
        }
        #expect(notices.count == 1, "one failure, one message")
        #expect(notices.first?.action == .signIn)
        #expect(notices.first?.text.contains("401") == false, "a raw HTTP error doesn't tell anyone what to do")
    }

    @Test func aRetryDropsThePartialAnswer() {
        var translator = CodexTranslator(workingDirectory: "/p")
        _ = translator.translate(method: "item/agentMessage/delta", params: ["itemId": "m1", "delta": "half an ans"])
        let events = translator.translate(
            method: "error", params: ["error": ["message": "Reconnecting... 1/5", "additionalDetails": "stream closed"], "willRetry": true])
        let retracted = events.contains { if case .itemRetracted(let id) = $0 { id == "m1" } else { false } }
        #expect(retracted)
        let notice = events.compactMap { event -> Notice? in
            if case .notice(let notice) = event { notice } else { nil }
        }.first
        #expect(notice?.key == "retry")
        #expect(notice?.text.contains("stream closed") == true)
    }

    @Test func onlyTheUsersOwnMCPFailuresAreShown() {
        var translator = CodexTranslator(workingDirectory: "/p")
        translator.userMCPServers = ["mine"]
        let failed: (String) -> JSONValue = { ["name": .string($0), "status": "failed", "error": "boom"] }
        #expect(translator.translate(method: "mcpServer/startupStatus/updated", params: failed("bundled-plugin")).isEmpty)
        #expect(translator.translate(method: "mcpServer/startupStatus/updated", params: failed("mine")).count == 1)
        #expect(translator.translate(method: "mcpServer/startupStatus/updated", params: ["name": "mine", "status": "ready"]).isEmpty)
    }

    @Test func usageForOtherBucketsDoesNotReplaceThePlansUsage() {
        var translator = CodexTranslator(workingDirectory: "/p")
        let other: JSONValue = ["rateLimits": ["limitId": "codex_spark", "primary": ["usedPercent": 91, "windowDurationMins": 300]]]
        #expect(translator.translate(method: "account/rateLimits/updated", params: other).isEmpty)
        let plan: JSONValue = ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 27, "windowDurationMins": 10080]]]
        #expect(translator.translate(method: "account/rateLimits/updated", params: plan).count == 1)
    }

    // MARK: Real recordings

    /// Feeds a recording of the real server through the translator, as the session would.
    private func replay(_ fixture: String) throws -> (session: SessionController, translator: CodexTranslator, approvals: [ApprovalRequest]) {
        let frames = try Fixture.frames(fixture)
        let root = frames.first { $0["method"]?.string == "turn/started" }?["params"]?["threadId"]?.string
        var translator = CodexTranslator(workingDirectory: "/tmp/project/w2")
        translator.rootThreadID = root
        let session = SessionController(meta: SessionMeta(projectID: UUID(), agent: .codex)) { _ in IdleAgent() }
        var approvals: [ApprovalRequest] = []
        for frame in frames {
            guard let method = frame["method"]?.string else { continue }
            let params = frame["params"] ?? .object([:])
            if frame["id"] != nil {
                if let (request, _) = translator.approval(id: "r", method: method, params: params) { approvals.append(request) }
            } else {
                for event in translator.translate(method: method, params: params) { session.apply(event) }
            }
        }
        session.flushDeltas()
        return (session, translator, approvals)
    }

    @Test func aRealSubAgentRunStaysUnderItsAgentRow() throws {
        let (session, _, _) = try replay("codex-subagent.jsonl")
        #expect(session.turnEnds.count == 1, "only the main thread ends the turn")
        #expect(session.assistantText.last == "done")
        #expect(!session.assistantText.contains("sub-done"), "the sub-agent's answer isn't the assistant's")
        let agent = try #require(session.tools.first { $0.kind == .subagent })
        #expect(agent.detail == "subtask")
        #expect(agent.status == .succeeded)
        #expect(agent.output.contains("sub-done"))
    }

    @Test func realPatchesKeepMovesAndCRLFIntact() throws {
        let (session, _, _) = try replay("codex-patch.jsonl")
        let files = session.tools.flatMap(\.diff)
        #expect(!files.isEmpty)
        #expect(!files.flatMap(\.lines).contains { $0.text.contains("oved to:") }, "the move notice isn't file content")

        let moved = try #require(files.first { $0.movedTo != nil })
        #expect(moved.movedTo?.hasSuffix("new-name.txt") == true)
        #expect(moved.additions == 1)

        let crlf = try #require(files.first { $0.path.hasSuffix("crlf.txt") })
        #expect(crlf.additions == 1)
        #expect(crlf.deletions == 1)
        #expect(!crlf.lines.contains { $0.text.contains("\r") })
    }

    @Test func realWebSearchesShowWhatWasSearched() throws {
        let (session, _, _) = try replay("codex-web.jsonl")
        let searches = session.tools.filter { $0.kind == .web }
        #expect(!searches.isEmpty)
        #expect(searches.allSatisfy { !$0.detail.isEmpty }, "the query only arrives when the item completes")
        #expect(searches.contains { !$0.output.isEmpty })
    }

    @Test func realMCPApprovalsReachTheUser() throws {
        let (_, _, approvals) = try replay("codex-mcp.jsonl")
        let request = try #require(approvals.first)
        #expect(request.title.contains("lab_echo"))
        #expect(request.detail.contains("hello"))
        #expect(request.rememberOptions.count == 1)
    }

    /// The commands as typed, and as they arrived from the real server. These go on approval cards.
    @Test func realCommandsDisplayExactlyAsTyped() throws {
        for pair in try #require(try Fixture.json("codex-commands.json").array) {
            let wire = try #require(pair["wire"]?.string)
            #expect(CodexTranslator.displayCommand(wire) == pair["typed"]?.string, "from \(wire)")
        }
    }

    @Test func unbalancedQuotingFallsBackToTheRawCommand() {
        #expect(CodexTranslator.displayCommand("/bin/zsh -lc 'oops") == "/bin/zsh -lc 'oops")
        #expect(CodexTranslator.displayCommand("git status") == "git status")
        #expect(CodexTranslator.displayCommand("/usr/bin/python3 -c print") == "/usr/bin/python3 -c print")
    }

    @Test func commandWrappersAreStripped() {
        #expect(CodexTranslator.displayCommand("/bin/zsh -lc 'npm test'") == "npm test")
        #expect(CodexTranslator.displayCommand("bash -c \"ls -la\"") == "ls -la")
        #expect(CodexTranslator.displayCommand("/bin/zsh -lc pwd") == "pwd")
    }
}
