import Foundation

/// A conversation with Claude, run through the official Claude Code CLI.
///
/// Marika starts the unmodified `claude` binary and talks to it over stream-json, the same
/// protocol the official Agent SDK uses. Sign-in stays entirely inside the CLI: this class
/// never sees a token, which is what lets a user's own plan work here.
///
/// The CLI is launched without `-p`, as the SDK does in streaming mode. The docs say `-p` will
/// default to `--bare` in a future release, and bare mode ignores subscription logins.
public actor ClaudeSession: AgentSession {
    public nonisolated let events: AsyncStream<AgentEvent>

    private enum ControlReply {
        case success(JSONValue)
        case failure(String)
    }

    private let sink: AsyncStream<AgentEvent>.Continuation
    private let launch: AgentLaunch
    private var settings: AgentSettings
    private var translator: ClaudeTranslator
    private var conversationID: String?

    private var process: LineProcess?
    private var readTask: Task<Void, Never>?
    private var nextRequestID = 0
    private var controlWaiters: [String: CheckedContinuation<ControlReply, Never>] = [:]
    private var approvals: [String: ApprovalRequest] = [:]

    private var isIdle = true
    private var completedTurns = 0
    private var stopRequested = false
    /// Some settings only apply at launch, so they take effect at the next idle moment.
    private var needsRelaunch = false
    private var launchedWithBypass = false
    private static let interruptGrace: Duration = .seconds(8)
    private static let initializeRequestID = "marika-initialize"

    public init(launch: AgentLaunch) {
        self.launch = launch
        settings = launch.settings
        conversationID = launch.conversationID
        translator = ClaudeTranslator(workingDirectory: launch.sessionDirectory.path)
        (events, sink) = AsyncStream.makeStream(of: AgentEvent.self)
    }

    // MARK: AgentSession

    public func send(_ input: UserInput) async throws {
        if needsRelaunch, isIdle { await stopProcess() }
        if process == nil { try startProcess() }
        isIdle = false
        sink.yield(.phaseChanged(.running))
        write(Self.userFrame(input))
    }

    public func interrupt() async {
        guard process != nil else { return }
        // Anything still waiting on the user is moot once the turn stops.
        for (id, _) in approvals {
            respond(to: id, with: ["behavior": "deny", "message": "The user stopped this turn.", "interrupt": true])
            sink.yield(.approvalCancelled(id: id))
        }
        approvals.removeAll()
        // Stop has to work even if the agent is wedged, so give it a moment and then force it.
        let stoppedTurn = completedTurns
        Task { [weak self] in
            try? await Task.sleep(for: Self.interruptGrace)
            await self?.forceStopIfStillBusy(after: stoppedTurn)
        }
        _ = await control(["subtype": "interrupt"])
    }

    public func hasActiveTurn() async -> Bool { !isIdle }

    /// Only acts if the turn that was stopped never ended. A new turn the user started since
    /// must be left alone.
    private func forceStopIfStillBusy(after stoppedTurn: Int) async {
        guard completedTurns == stoppedTurn, !isIdle, process != nil else { return }
        await stopProcess()
        sink.yield(.turnFinished(TurnSummary(outcome: .interrupted)))
        sink.yield(.phaseChanged(.idle))
    }

    public func answer(requestID: String, decision: ApprovalDecision) async {
        guard let approval = approvals.removeValue(forKey: requestID) else { return }
        var response: [String: JSONValue]

        switch decision {
        case .allow(let remember):
            response = ["behavior": "allow", "updatedInput": approval.input]
            if let remember { response["updatedPermissions"] = [remember.payload] }

        case .deny:
            if let id = approval.toolCallID { translator.deniedToolIDs.insert(id) }
            response = ["behavior": "deny", "message": "The user declined this action.", "interrupt": true]

        case .denyWithFeedback(let feedback):
            if let id = approval.toolCallID { translator.deniedToolIDs.insert(id) }
            response = ["behavior": "deny", "message": .string(feedback)]

        case .skip:
            if let id = approval.toolCallID { translator.deniedToolIDs.insert(id) }
            response = ["behavior": "deny", "message": "The user skipped this question."]

        case .answers(let answers):
            var input = approval.input.object ?? [:]
            input["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
            response = ["behavior": "allow", "updatedInput": .object(input)]

        case .approvePlan(let nextMode):
            response = ["behavior": "allow", "updatedInput": approval.input]
            if let nextMode, nextMode != .ask {
                response["updatedPermissions"] = [
                    ["type": "setMode", "mode": .string(ClaudeMode.controlValue(nextMode)), "destination": "session"]
                ]
            }
            // Approving a plan leaves plan mode without any frame saying so, and a relaunch
            // must not fall back into it.
            settings.mode = nextMode ?? .ask
        }
        respond(to: requestID, with: .object(response))
    }

    public func update(settings new: AgentSettings) async {
        let old = settings
        settings = new
        guard process != nil else { return }

        if new.model != old.model {
            if case .failure(let message) = await control(["subtype": "set_model", "model": new.model.json]) {
                sink.yield(.notice(Notice(level: .warning, text: message)))
            }
        }
        if new.mode != old.mode {
            if new.mode == .bypass, !launchedWithBypass {
                needsRelaunch = true
            } else {
                let request: JSONValue = ["subtype": "set_permission_mode", "mode": .string(ClaudeMode.controlValue(new.mode))]
                if case .failure(let message) = await control(request) {
                    sink.yield(.notice(Notice(level: .warning, text: message)))
                }
            }
        }
        if new.effort != old.effort { needsRelaunch = true }
    }

    public func shutdown() async {
        await stopProcess()
        sink.finish()
    }

    // MARK: Process

    private func startProcess() throws {
        var arguments = [
            "--output-format", "stream-json",
            "--verbose",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--thinking-display", "summarized",
            "--permission-mode", ClaudeMode.launchValue(settings.mode),
        ]
        if let model = settings.model { arguments += ["--model", model] }
        if let effort = settings.effort { arguments += ["--effort", effort] }
        launchedWithBypass = settings.mode == .bypass
        if launchedWithBypass { arguments += ["--allow-dangerously-skip-permissions"] }
        if let conversationID { arguments += ["--resume", conversationID] }
        var servers = try ProjectMCP.claudeServers(launch.projectMCP, environment: launch.environment, deferCredentials: true)
        if let builtin = launch.browser?.claudeConfig["mcpServers"]?.object { servers.merge(builtin) { _, new in new } }
        if !servers.isEmpty {
            arguments += ["--mcp-config", String(decoding: try JSONValue.object(["mcpServers": .object(servers)]).serialized(), as: UTF8.self)]
        }
        if !launch.projectInstructions.isEmpty { arguments += ["--append-system-prompt", launch.projectInstructions] }
        for directory in launch.additionalDirectories { arguments += ["--add-dir", directory.path] }

        let invocation = try launch.runtime?.invocation((["claude"] + arguments).map(WorkspaceRuntime.quote).joined(separator: " "), environment: launch.environment)
        let process = LineProcess(
            executable: invocation?.0 ?? launch.executable, arguments: invocation?.1 ?? arguments, environment: launch.environment,
            workingDirectory: launch.workingDirectory)
        do {
            try process.start()
        } catch {
            throw AgentError.launchFailed("Could not start \(launch.executable.path): \(error.localizedDescription)")
        }
        self.process = process
        needsRelaunch = false
        stopRequested = false

        readTask = Task { [weak self] in
            for await output in process.output {
                await self?.ingest(output)
            }
        }
        // Written synchronously so it reaches the CLI ahead of the first message.
        write(["type": "control_request", "request_id": .string(Self.initializeRequestID), "request": ["subtype": "initialize"]])
    }

    private func stopProcess() async {
        guard let process else { return }
        stopRequested = true
        process.closeInput()
        let readTask = self.readTask
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { process.terminate() }
        }
        await readTask?.value
        watchdog.cancel()
    }

    private func ingest(_ output: LineProcess.Output) {
        switch output {
        case .line(let data):
            guard let frame = try? JSONValue(parsing: data) else { return }
            handle(frame)
        case .exited(let status, let stderrTail):
            handleExit(status: status, stderrTail: stderrTail)
        }
    }

    private func handleExit(status: Int32, stderrTail: String) {
        process = nil
        readTask = nil
        isIdle = true
        for waiter in controlWaiters.values { waiter.resume(returning: .failure("The agent exited.")) }
        controlWaiters.removeAll()
        for id in approvals.keys { sink.yield(.approvalCancelled(id: id)) }
        approvals.removeAll()

        if stopRequested {
            stopRequested = false
            return
        }
        // The conversation can be gone if the CLI's history was cleared. Start fresh next time.
        if stderrTail.contains("No conversation found") { conversationID = nil }
        let message = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        sink.yield(.phaseChanged(.idle))
        sink.yield(.terminated(status: status, message: message.isEmpty ? nil : message))
    }

    // MARK: Frames

    private func handle(_ frame: JSONValue) {
        switch frame["type"]?.string {
        case "control_request":
            handleControlRequest(frame)
        case "control_response":
            handleControlResponse(frame)
        case "control_cancel_request":
            if let id = frame["request_id"]?.string, approvals.removeValue(forKey: id) != nil {
                sink.yield(.approvalCancelled(id: id))
            }
        default:
            for event in translator.translate(frame) {
                observe(event)
                sink.yield(event)
            }
        }
    }

    private func observe(_ event: AgentEvent) {
        switch event {
        case .conversationStarted(let id, _):
            conversationID = id
        case .phaseChanged(let phase):
            isIdle = phase == .idle
        case .modeChanged(let mode):
            settings.mode = mode
        case .turnFinished:
            completedTurns += 1
            Task { await self.requestContextUsage() }
        default:
            break
        }
    }

    private func handleControlRequest(_ frame: JSONValue) {
        guard let id = frame["request_id"]?.string, let request = frame["request"] else { return }
        if request["subtype"]?.string == "can_use_tool" {
            let approval = translator.approvalRequest(id: id, request: request)
            approvals[id] = approval
            sink.yield(.approvalRequested(approval))
        } else {
            // An unanswered request would stall the agent forever.
            write([
                "type": "control_response",
                "response": ["subtype": "error", "request_id": .string(id), "error": "Not supported by this client"],
            ])
        }
    }

    private func handleControlResponse(_ frame: JSONValue) {
        guard let response = frame["response"], let id = response["request_id"]?.string else { return }
        if id == Self.initializeRequestID {
            if let details = response["response"] { sink.yield(.capabilities(ClaudeCLI.capabilities(from: details))) }
            return
        }
        guard let waiter = controlWaiters.removeValue(forKey: id) else { return }
        if response["subtype"]?.string == "error" {
            waiter.resume(returning: .failure(response["error"]?.string ?? "The agent rejected the request."))
        } else {
            waiter.resume(returning: .success(response["response"] ?? .null))
        }
    }

    private func respond(to requestID: String, with response: JSONValue) {
        write([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestID), "response": response],
        ])
    }

    private func control(_ request: JSONValue) async -> ControlReply {
        guard process != nil else { return .failure("The agent is not running.") }
        nextRequestID += 1
        let id = "marika-\(nextRequestID)"
        return await withCheckedContinuation { continuation in
            controlWaiters[id] = continuation
            write(["type": "control_request", "request_id": .string(id), "request": request])
        }
    }

    private func write(_ frame: JSONValue) {
        guard let process, let data = try? frame.serialized() else { return }
        process.write(data)
    }

    private func requestContextUsage() async {
        guard case .success(let response) = await control(["subtype": "get_context_usage"]),
            let used = response["totalTokens"]?.int, let limit = response["maxTokens"]?.int
        else { return }
        sink.yield(.contextUsage(ContextUsage(usedTokens: used, maxTokens: limit)))
    }

    static func userFrame(_ input: UserInput) -> JSONValue {
        var content: [JSONValue] = []
        if !input.text.isEmpty {
            content.append(["type": "text", "text": .string(input.text)])
        }
        for image in input.images {
            guard let data = FileManager.default.contents(atPath: image.path) else { continue }
            content.append([
                "type": "image",
                "source": [
                    "type": "base64", "media_type": .string(image.mediaType), "data": .string(data.base64EncodedString()),
                ],
            ])
        }
        return [
            "type": "user",
            "message": ["role": "user", "content": .array(content)],
            "parent_tool_use_id": nil,
            "session_id": "",
        ]
    }
}
