import Foundation

/// A conversation with Codex, run through the official `codex app-server`.
///
/// As with Claude, sign-in stays inside the official tool. `codex login` manages the user's ChatGPT
/// plan or API key, and this class never handles those credentials.
///
/// Threads always start read-only, and each turn sets the real sandbox. Starting a thread with a
/// writable sandbox would make Codex permanently trust the folder in the user's global config, and
/// run the repository's own MCP servers unsandboxed before anything could be approved.
public actor CodexSession: AgentSession {
    public nonisolated let events: AsyncStream<AgentEvent>

    private struct PendingRequest {
        var rpcID: JSONValue
        var kind: CodexTranslator.RequestKind
        var threadID: String?
        var turnID: String?
        var approval: ApprovalRequest
    }

    /// What Default means, read from the user's Codex config and model list.
    private struct Profile {
        var model: String?
        var effort: String?
        var serviceTier: String?
        var models: [ModelOption] = []
        var sandbox = CodexMode.SandboxSettings()

        var defaultModel: String? { model ?? models.first(where: \.isDefault)?.id }
    }

    /// How long Stop waits for the server before forcing the issue.
    private let interruptGrace: Duration
    private let requestTimeout: Duration
    private let sink: AsyncStream<AgentEvent>.Continuation
    private let launch: AgentLaunch
    private var settings: AgentSettings
    private var translator: CodexTranslator
    private var profile = Profile()

    private var connection: CodexConnection?
    private var connectionGeneration = 0
    /// Set when the app ended the connection itself, so its exit isn't reported as a crash.
    private var expectingExit = false

    private var threadID: String?
    private var threadIsLoaded = false
    private var reportedConversationID: String?

    private var mainTurnID: String?
    /// Sub-agents run turns of their own, and Stop has to reach each one: the protocol has no
    /// tree-wide stop, and stopping the main turn leaves children running.
    private var childTurns: [String: String] = [:]
    private var finishedTurns: Set<String> = []
    private var completedTurns = 0
    private var stopPending = false

    private var pendingRequests: [String: PendingRequest] = [:]
    private var lastSend: Task<Void, Error>?
    private var isShutDown = false

    public init(
        launch: AgentLaunch, interruptGrace: Duration = .seconds(8), requestTimeout: Duration = CodexConnection.defaultTimeout
    ) {
        self.launch = launch
        self.interruptGrace = interruptGrace
        self.requestTimeout = requestTimeout
        settings = launch.settings
        threadID = launch.conversationID
        reportedConversationID = launch.conversationID
        translator = CodexTranslator(workingDirectory: launch.sessionDirectory.path)
        translator.rootThreadID = launch.conversationID
        (events, sink) = AsyncStream.makeStream(of: AgentEvent.self)
    }

    // MARK: AgentSession

    /// Sends run one at a time. Each one awaits replies, and an actor lets other calls in at every
    /// `await`, so overlapping sends could otherwise start two processes or two threads.
    public func send(_ input: UserInput) async throws {
        try await enqueue(input, thread: nil)
    }

    private func enqueue(_ input: UserInput, thread: String?) async throws {
        let previous = lastSend
        let task = Task { [weak self] in
            _ = await previous?.result
            try await self?.performSend(input, thread: thread)
        }
        lastSend = task
        try await task.value
    }

    public func hasActiveTurn() async -> Bool {
        mainTurnID != nil || !childTurns.isEmpty
    }

    public func interrupt() async {
        cancelPendingRequests()
        let stoppedTurn = completedTurns
        let grace = interruptGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.forceStopIfStillBusy(after: stoppedTurn)
        }
        if mainTurnID == nil, childTurns.isEmpty {
            // The turn hasn't begun yet. Stop it the moment it does, or before it's sent.
            stopPending = true
        } else {
            await interruptLiveTurns()
        }
    }

    public func answer(requestID: String, decision: ApprovalDecision) async {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        let reply = Self.reply(to: pending, decision: decision)
        await connection?.respond(to: pending.rpcID, result: reply.result)

        // `cancel` ends the turn for commands and edits, but not for MCP requests.
        if reply.stopsTurn { await interruptLiveTurns() }
        if case .denyWithFeedback(let feedback) = decision {
            let target = pending.threadID == threadID ? nil : pending.threadID
            Task { [weak self] in
                do {
                    try await self?.enqueue(UserInput(text: feedback), thread: target)
                } catch {
                    self?.sink.yield(.notice(Notice(level: .error, text: "Your message wasn't delivered: \(error.localizedDescription)")))
                }
            }
        }
    }

    /// Codex takes these on each `turn/start`, so they apply from the next turn. A running turn can't
    /// change policy, and the app says so.
    public func update(settings new: AgentSettings) async {
        settings = new
    }

    public func shutdown() async {
        isShutDown = true
        expectingExit = true
        lastSend?.cancel()
        await connection?.close()
        connection = nil
        sink.finish()
    }

    // MARK: Sending

    private func checkNotShutDown() throws {
        if isShutDown { throw CancellationError() }
    }

    private func performSend(_ input: UserInput, thread target: String?) async throws {
        try checkNotShutDown()
        guard FileManager.default.fileExists(atPath: launch.workingDirectory.path) else {
            throw AgentError.launchFailed("\(launch.sessionDirectory.path) no longer exists.")
        }
        do {
            let connection = try await connect()
            try checkNotShutDown()
            sink.yield(.phaseChanged(.running))
            let thread = try await resolveThread(connection)
            try checkNotShutDown()
            if stopPending, mainTurnID == nil {
                stopPending = false
                sink.yield(.turnFinished(TurnSummary(outcome: .interrupted)))
                sink.yield(.phaseChanged(.idle))
                return
            }
            if try await runCommand(input.text, thread: thread, connection: connection) { return }

            let isNewTurn = mainTurnID == nil
            if isNewTurn { translator.turnMode = settings.mode }
            // Starting a turn while one runs adds to it, so this is safe for all user input.
            var params: [String: JSONValue] = [
                "threadId": .string(target ?? thread),
                "input": .array(Self.inputItems(input)),
                "cwd": .string(launch.sessionDirectory.path),
                "approvalPolicy": CodexMode.approvalPolicy(settings.mode),
                "approvalsReviewer": "user",
                "sandboxPolicy": CodexMode.sandboxPolicy(
                    settings.mode, workingDirectory: launch.sessionDirectory.path, settings: profile.sandbox, additionalDirectories: launch.additionalDirectories.map(\.path)),
                "summary": "concise",
            ]
            // Overrides stick to the thread, and nothing clears them but a concrete value. So Default
            // has to be sent as the real default, or an earlier choice would quietly remain.
            let model = settings.model ?? profile.defaultModel
            if let model { params["model"] = .string(model) }
            if let effort = resolvedEffort(for: model) { params["effort"] = .string(effort) }
            if isNewTurn { params["serviceTier"] = .string(resolvedServiceTier(for: model)) }

            let result = try await connection.request("turn/start", .object(params), timeout: requestTimeout)
            if target == nil, mainTurnID == nil, let turn = result["turn"]?["id"]?.string, !finishedTurns.contains(turn) {
                mainTurnID = turn
            }
            reportConversation(id: thread)
            if stopPending { await interruptLiveTurns() }
        } catch AgentError.timedOut(let message) {
            // A server that stops answering stays wedged, so don't reuse it.
            await dropConnection()
            throw AgentError.timedOut(message)
        }
    }

    private func resolvedEffort(for model: String?) -> String? {
        settings.effort ?? profile.effort ?? profile.models.first { $0.id == model }?.defaultEffort
    }

    private func resolvedServiceTier(for model: String?) -> String {
        // Like model and effort, tier overrides stick. A concrete default clears an earlier Fast choice.
        ServiceTierOption.requestValue(settings.serviceTier ?? profile.serviceTier
            ?? profile.models.first { $0.id == model }?.defaultServiceTier ?? "default")
    }

    /// The conversation is only worth saving once a turn exists: a thread with no turn has no
    /// history on disk, so it can't be resumed.
    private func reportConversation(id: String) {
        guard reportedConversationID != id else { return }
        reportedConversationID = id
        sink.yield(.conversationStarted(id: id, model: settings.model ?? profile.defaultModel))
    }

    /// Commands the app-server offers directly. Returns true when the input was one of them.
    private func runCommand(_ text: String, thread: String, connection: CodexConnection) async throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/compact" {
            _ = try await connection.request("thread/compact/start", ["threadId": .string(thread)])
            reportConversation(id: thread)
            return true
        }
        if trimmed == "/review" || trimmed.hasPrefix("/review ") {
            let instructions = trimmed.dropFirst("/review".count).trimmingCharacters(in: .whitespaces)
            let target: JSONValue =
                instructions.isEmpty
                ? ["type": "uncommittedChanges"] : ["type": "custom", "instructions": .string(instructions)]
            _ = try await connection.request("review/start", ["threadId": .string(thread), "target": target])
            reportConversation(id: thread)
            return true
        }
        return false
    }

    private static func inputItems(_ input: UserInput) -> [JSONValue] {
        var items: [JSONValue] = []
        if !input.text.isEmpty {
            items.append(["type": "text", "text": .string(input.text), "text_elements": []])
        }
        for image in input.images {
            items.append(["type": "localImage", "path": .string(image.path)])
        }
        return items
    }

    // MARK: Connection

    private func connect() async throws -> CodexConnection {
        if let connection { return connection }
        connectionGeneration += 1
        let generation = connectionGeneration
        let args = (launch.browser?.codexArguments ?? []) + (try ProjectMCP.codexArguments(launch.projectMCP))
        let remote = try launch.runtime?.invocation((["codex"] + args + ["app-server"]).map(WorkspaceRuntime.quote).joined(separator: " "), environment: launch.environment)
        let connection = CodexConnection(
            executable: remote?.0 ?? launch.executable, environment: launch.environment, workingDirectory: launch.workingDirectory,
            arguments: remote?.1 ?? args, appendServerArgument: remote == nil,
            inbound: { [weak self] message in await self?.receive(message, generation: generation) })
        // Stored before the handshake, so a shutdown can reach a server that is still starting.
        self.connection = connection
        expectingExit = false
        do {
            try await connection.start()
            try await connection.initialize()
            try checkNotShutDown()
            await loadProfile(connection)
        } catch {
            self.connection = nil
            expectingExit = true
            await connection.close()
            if error is CancellationError { throw error }
            throw AgentError.launchFailed("Could not start Codex: \(error.localizedDescription)")
        }
        return connection
    }

    /// Closes a connection that can't be trusted any more. The next send starts a new one.
    private func dropConnection() async {
        let old = connection
        connection = nil
        threadIsLoaded = false
        expectingExit = true
        await old?.close()
    }

    private func loadProfile(_ connection: CodexConnection) async {
        let cwd = launch.sessionDirectory.path
        if let config = try? await connection.request("config/read", ["cwd": .string(cwd)], timeout: .seconds(10)),
            let values = config["config"]
        {
            profile.model = values["model"]?.string
            profile.effort = values["model_reasoning_effort"]?.string
            profile.serviceTier = values["service_tier"]?.string
            let sandbox = values["sandbox_workspace_write"]
            profile.sandbox = CodexMode.SandboxSettings(
                networkAccess: sandbox?["network_access"]?.bool ?? false,
                excludeTmpdirEnvVar: sandbox?["exclude_tmpdir_env_var"]?.bool ?? false,
                excludeSlashTmp: sandbox?["exclude_slash_tmp"]?.bool ?? false)
            translator.userMCPServers = Set(values["mcp_servers"]?.object?.keys.map { $0 } ?? [])
        }
        if let capabilities = try? await CodexCLI.capabilities(using: connection) {
            profile.models = capabilities.models
            sink.yield(.capabilities(capabilities))
        }
        if let limits = try? await connection.request("account/rateLimits/read", timeout: .seconds(10)),
            let snapshot = limits["rateLimits"].flatMap(CodexTranslator.rateLimit)
        {
            sink.yield(.rateLimit(snapshot))
        }
    }

    private var threadParams: [String: JSONValue] {
        var params: [String: JSONValue] = [
            "cwd": .string(launch.sessionDirectory.path),
            "approvalPolicy": CodexMode.approvalPolicy(settings.mode),
            "approvalsReviewer": "user",
            "sandbox": "read-only",
        ]
        if let model = settings.model ?? profile.defaultModel { params["model"] = .string(model) }
        params["serviceTier"] = .string(resolvedServiceTier(for: settings.model ?? profile.defaultModel))
        if !launch.projectInstructions.isEmpty { params["developerInstructions"] = .string(launch.projectInstructions) }
        return params
    }

    private func resolveThread(_ connection: CodexConnection) async throws -> String {
        if let threadID {
            if threadIsLoaded { return threadID }
            if try await resume(threadID, connection: connection) {
                threadIsLoaded = true
                return threadID
            }
            sink.yield(
                .notice(
                    Notice(level: .warning, text: "Codex no longer has this conversation, so it's starting fresh without the earlier context.")
                ))
        }
        let result = try await connection.request("thread/start", .object(threadParams))
        guard let id = result["thread"]?["id"]?.string else {
            throw AgentError.protocolError("Codex did not return a thread.")
        }
        threadID = id
        translator.rootThreadID = id
        threadIsLoaded = true
        return id
    }

    /// Returns false when the thread is gone. An archived thread is brought back.
    private func resume(_ id: String, connection: CodexConnection) async throws -> Bool {
        var params = threadParams
        params["threadId"] = .string(id)
        params["excludeTurns"] = true
        do {
            _ = try await connection.request("thread/resume", .object(params))
            return true
        } catch let error as AgentError {
            let message = error.localizedDescription
            if message.contains("is archived") {
                _ = try await connection.request("thread/unarchive", ["threadId": .string(id)])
                _ = try await connection.request("thread/resume", .object(params))
                return true
            }
            if message.contains("no rollout found") {
                threadID = nil
                reportedConversationID = nil
                translator.rootThreadID = nil
                return false
            }
            throw error
        }
    }

    // MARK: Stopping

    private func interruptLiveTurns() async {
        guard let connection else { return }
        var turns = childTurns
        if let threadID, let mainTurnID { turns[threadID] = mainTurnID }
        for (thread, turn) in turns {
            do {
                _ = try await connection.request(
                    "turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)], timeout: .seconds(10))
            } catch {
                // The reply to turn/start can arrive before the turn can be interrupted.
                if error.localizedDescription.contains("no active turn") {
                    stopPending = true
                } else {
                    sink.yield(.activity(nil))
                    sink.yield(.notice(Notice(level: .error, text: "Couldn't stop the agent: \(error.localizedDescription)")))
                }
            }
        }
    }

    /// Only acts if the turn that was stopped never ended. A new turn the user started since
    /// must be left alone.
    private func forceStopIfStillBusy(after stoppedTurn: Int) async {
        guard completedTurns == stoppedTurn, mainTurnID != nil || !childTurns.isEmpty else { return }
        stopPending = false
        mainTurnID = nil
        childTurns.removeAll()
        await dropConnection()
        sink.yield(.turnFinished(TurnSummary(outcome: .interrupted)))
        sink.yield(.activity(nil))
        sink.yield(.phaseChanged(.idle))
    }

    private func cancelPendingRequests() {
        for (id, pending) in pendingRequests {
            let reply = Self.reply(to: pending, decision: .deny)
            let rpcID = pending.rpcID
            let connection = connection
            Task { await connection?.respond(to: rpcID, result: reply.result) }
            sink.yield(.approvalCancelled(id: id))
        }
        pendingRequests.removeAll()
    }

    // MARK: Inbound

    private func receive(_ message: CodexConnection.Message, generation: Int) async {
        guard generation == connectionGeneration else { return }
        switch message {
        case .notification(let method, let params):
            handleNotification(method, params)
        case .request(let id, let method, let params):
            await handleRequest(id: id, method: method, params: params)
        case .exited(let status, let stderrTail):
            handleExit(status: status, stderrTail: stderrTail)
        }
    }

    /// Runs inside the read loop, so it must not wait for a reply. Anything that needs one goes
    /// through a separate task.
    private func handleNotification(_ method: String, _ params: JSONValue) {
        let thread = params["threadId"]?.string
        let isMain = thread == nil || thread == threadID

        switch method {
        case "turn/started":
            guard let thread, let turn = params["turn"]?["id"]?.string else { break }
            if isMain { mainTurnID = turn } else { childTurns[thread] = turn }
        case "turn/completed":
            guard let turn = params["turn"]?["id"]?.string else { break }
            finishedTurns.insert(turn)
            if isMain {
                mainTurnID = nil
                completedTurns += 1
            } else if let thread {
                childTurns[thread] = nil
            }
            dropRequests(forTurn: turn)
        case "serverRequest/resolved":
            let key = Self.requestKey(params["requestId"])
            if pendingRequests.removeValue(forKey: key) != nil {
                sink.yield(.approvalCancelled(id: key))
            }
        default:
            break
        }

        for event in translator.translate(method: method, params: params) {
            sink.yield(event)
        }

        if method == "turn/started" {
            if isMain { sink.yield(.phaseChanged(.running)) }
            if stopPending {
                stopPending = false
                Task { await self.interruptLiveTurns() }
            }
        } else if method == "turn/completed", mainTurnID == nil {
            if childTurns.isEmpty {
                sink.yield(.activity(nil))
                sink.yield(.phaseChanged(.idle))
            } else {
                // The session stays busy, so Stop stays available while a sub-agent still works.
                sink.yield(.activity("Sub-agents still running"))
            }
        }
    }

    /// The server sends nothing more about a request whose turn has ended.
    private func dropRequests(forTurn turn: String) {
        for (id, pending) in pendingRequests where pending.turnID == turn {
            pendingRequests[id] = nil
            sink.yield(.approvalCancelled(id: id))
        }
    }

    private func handleRequest(id: JSONValue, method: String, params: JSONValue) async {
        let key = Self.requestKey(id)
        guard let (approval, kind) = translator.approval(id: key, method: method, params: params) else {
            if method == "mcpServer/elicitation/request" {
                sink.yield(.notice(Notice(level: .warning, text: "An MCP server asked for input that Marika can't show yet.")))
                await connection?.respond(to: id, result: ["action": "decline", "content": nil, "_meta": nil])
            } else {
                // An unanswered request would stall the turn forever.
                await connection?.respondWithError(to: id, code: -32601, message: "Not supported by this client")
            }
            return
        }
        // Accept edits covers ordinary files in the project. Anything else still goes to the user.
        if kind == .fileChange, translator.turnMode == .acceptEdits,
            let item = params["itemId"]?.string, translator.changesStayInProject(item)
        {
            await connection?.respond(to: id, result: ["decision": "accept"])
            return
        }
        pendingRequests[key] = PendingRequest(
            rpcID: id, kind: kind, threadID: params["threadId"]?.string, turnID: params["turnId"]?.string, approval: approval)
        sink.yield(.approvalRequested(approval))
    }

    private func handleExit(status: Int32, stderrTail: String) {
        connection = nil
        threadIsLoaded = false
        mainTurnID = nil
        childTurns.removeAll()
        stopPending = false
        for id in pendingRequests.keys { sink.yield(.approvalCancelled(id: id)) }
        pendingRequests.removeAll()
        guard !expectingExit else { return }
        let message = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        sink.yield(.activity(nil))
        sink.yield(.phaseChanged(.idle))
        sink.yield(.terminated(status: status, message: message.isEmpty ? nil : message))
    }

    private static func requestKey(_ id: JSONValue?) -> String {
        "rpc-\(id?.int.map(String.init) ?? id?.string ?? UUID().uuidString)"
    }

    // MARK: Replies

    /// Each request type has its own reply shape. A wrong one reads as a rejection, or is dropped.
    private static func reply(
        to pending: PendingRequest, decision: ApprovalDecision
    ) -> (result: JSONValue, stopsTurn: Bool) {
        switch pending.kind {
        case .command, .fileChange:
            switch decision {
            case .allow(let remember): return (["decision": remember?.payload ?? "accept"], false)
            case .deny: return (["decision": "cancel"], false)
            case .denyWithFeedback, .skip: return (["decision": "decline"], false)
            case .answers, .approvePlan: return (["decision": "accept"], false)
            }
        case .mcpApproval, .link:
            switch decision {
            case .allow(let remember):
                let meta: JSONValue = remember.map { ["persist": $0.payload] } ?? nil
                return (["action": "accept", "content": [:], "_meta": meta], false)
            case .answers, .approvePlan:
                return (["action": "accept", "content": [:], "_meta": nil], false)
            case .deny:
                return (["action": "decline", "content": nil, "_meta": nil], true)
            case .denyWithFeedback, .skip:
                return (["action": "decline", "content": nil, "_meta": nil], false)
            }
        case .form:
            switch decision {
            case .answers(let answers):
                let schema = pending.approval.input["requestedSchema"]
                return (["action": "accept", "content": CodexTranslator.formContent(answers: answers, schema: schema), "_meta": nil], false)
            case .allow, .approvePlan:
                return (["action": "accept", "content": [:], "_meta": nil], false)
            case .deny:
                return (["action": "cancel", "content": nil, "_meta": nil], true)
            case .denyWithFeedback, .skip:
                return (["action": "decline", "content": nil, "_meta": nil], false)
            }
        case .userInput:
            switch decision {
            case .answers(let answers):
                return (["answers": .object(answers.mapValues { ["answers": .array($0.map(JSONValue.string))] })], false)
            case .deny:
                return (["answers": [:]], true)
            default:
                return (["answers": [:]], false)
            }
        }
    }
}
