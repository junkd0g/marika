import Foundation

/// Translates Claude Code's stream-json frames into `AgentEvent`s.
///
/// Pure and synchronous, so it can be tested against recorded traffic. The mapping below
/// follows frames observed from the real CLI:
///
/// - `stream_event` carries live deltas, and `assistant` then repeats each finished block in
///   its own frame, sharing the `message.id`. The two are paired up so a block renders once.
/// - `result` ends a turn, but a message sent mid-turn is folded into that turn, so counting
///   results against sends does not work. `session_state_changed` is the reliable signal.
/// - An interrupted turn reports `is_error: true` with a `terminal_reason` of `aborted_*`.
///   That is the user stopping it, not a failure.
struct ClaudeTranslator {
    private enum BlockKind {
        case text
        case thinking
    }

    private struct OpenBlock {
        var id: String
        var kind: BlockKind
    }

    let workingDirectory: String

    /// Tool calls the user refused, so their error result reads as a refusal.
    var deniedToolIDs: Set<String> = []

    private var openBlocks: [String: [OpenBlock]] = [:]
    private var lastMessageID = "message"
    private var syntheticID = 0
    private var sawTextThisTurn = false

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    mutating func translate(_ frame: JSONValue) -> [AgentEvent] {
        switch frame["type"]?.string {
        case "stream_event": translateStream(frame)
        case "assistant": translateAssistant(frame)
        case "user": translateUser(frame)
        case "system": translateSystem(frame)
        case "result": translateResult(frame)
        case "rate_limit_event": translateRateLimit(frame)
        default: []
        }
    }

    // MARK: Live deltas

    private mutating func translateStream(_ frame: JSONValue) -> [AgentEvent] {
        guard let event = frame["event"] else { return [] }
        let parent = frame["parent_tool_use_id"]?.string
        if let id = frame["api_message_id"]?.string ?? event["message"]?["id"]?.string {
            lastMessageID = id
        }
        let index = event["index"]?.int ?? 0
        let blockID = "\(lastMessageID)#\(index)"

        switch event["type"]?.string {
        case "content_block_start":
            guard let block = event["content_block"] else { return [] }
            switch block["type"]?.string {
            case "text":
                openBlocks[lastMessageID, default: []].append(OpenBlock(id: blockID, kind: .text))
            case "thinking":
                openBlocks[lastMessageID, default: []].append(OpenBlock(id: blockID, kind: .thinking))
            case "tool_use":
                guard let id = block["id"]?.string, let name = block["name"]?.string else { return [] }
                // The input arrives with the finished block. Show the call as soon as it starts.
                return [.tool(toolCall(id: id, name: name, input: .object([:]), parent: parent))]
            default:
                break
            }
            return []
        case "content_block_delta":
            guard let delta = event["delta"] else { return [] }
            switch delta["type"]?.string {
            case "text_delta":
                guard let text = delta["text"]?.string else { return [] }
                if parent == nil { sawTextThisTurn = true }
                return [.textDelta(id: blockID, delta: text, parentToolID: parent)]
            case "thinking_delta":
                guard let text = delta["thinking"]?.string else { return [] }
                return [.thinkingDelta(id: blockID, delta: text, parentToolID: parent)]
            default:
                return []
            }
        default:
            return []
        }
    }

    // MARK: Finished blocks

    private mutating func translateAssistant(_ frame: JSONValue) -> [AgentEvent] {
        guard let message = frame["message"], let blocks = message["content"]?.array else { return [] }
        let messageID = message["id"]?.string ?? lastMessageID
        let parent = frame["parent_tool_use_id"]?.string
        var events: [AgentEvent] = []

        for block in blocks {
            switch block["type"]?.string {
            case "text":
                let text = block["text"]?.string ?? ""
                let id = claimBlock(.text, in: messageID)
                if parent == nil { sawTextThisTurn = true }
                events.append(.textFinished(id: id, text: text, parentToolID: parent))
            case "thinking":
                let id = claimBlock(.thinking, in: messageID)
                let text = block["thinking"]?.string ?? ""
                if !text.isEmpty {
                    events.append(
                        .thinkingFinished(
                            id: id, text: text, durationMs: frame["thinking_duration_ms"]?.int, parentToolID: parent))
                }
            case "tool_use":
                guard let id = block["id"]?.string, let name = block["name"]?.string else { continue }
                let input = block["input"] ?? .object([:])
                events.append(.tool(toolCall(id: id, name: name, input: input, parent: parent)))
                if name == "TodoWrite", let todos = input["todos"]?.array {
                    events.append(.todosUpdated(todos.compactMap(Self.todoItem)))
                }
            default:
                break
            }
        }
        return events
    }

    private mutating func claimBlock(_ kind: BlockKind, in messageID: String) -> String {
        if let index = openBlocks[messageID]?.firstIndex(where: { $0.kind == kind }) {
            return openBlocks[messageID]!.remove(at: index).id
        }
        syntheticID += 1
        return "\(messageID)#final-\(syntheticID)"
    }

    private func toolCall(id: String, name: String, input: JSONValue, parent: String?) -> ToolCall {
        let description = ToolDescriber.describe(name: name, input: input, workingDirectory: workingDirectory)
        return ToolCall(
            id: id, name: name, kind: description.kind, title: description.title, detail: description.detail,
            input: input, parentID: parent)
    }

    private static func todoItem(_ value: JSONValue) -> TodoItem? {
        guard let text = value["content"]?.string else { return nil }
        let status: TodoItem.Status =
            switch value["status"]?.string {
            case "completed": .completed
            case "in_progress": .inProgress
            default: .pending
            }
        return TodoItem(text: text, status: status)
    }

    // MARK: Tool results

    private mutating func translateUser(_ frame: JSONValue) -> [AgentEvent] {
        guard let blocks = frame["message"]?["content"]?.array else { return [] }
        var events: [AgentEvent] = []
        let structured = frame["tool_use_result"]

        for block in blocks where block["type"]?.string == "tool_result" {
            guard let id = block["tool_use_id"]?.string else { continue }
            let isError = block["is_error"]?.bool ?? false
            let output = Self.resultText(block["content"])
            let rejected = structured?.string == "User rejected tool use"
            let status: ToolStatus =
                if deniedToolIDs.contains(id) || rejected {
                    .denied
                } else if isError {
                    .failed
                } else {
                    .succeeded
                }
            let diff = isError ? [] : diff(from: structured)
            events.append(.toolFinished(id: id, output: output, status: status, diff: diff))
            if !diff.isEmpty { events.append(.filesChanged) }
        }
        return events
    }

    private func diff(from result: JSONValue?) -> [DiffFile] {
        guard let result, let filePath = result["filePath"]?.string else { return [] }
        let path = ToolDescriber.relative(filePath, to: workingDirectory)
        if let patch = result["structuredPatch"]?.array, !patch.isEmpty {
            return [DiffFile(path: path, structuredPatch: patch)]
        }
        if result["type"]?.string == "create", let content = result["content"]?.string {
            return [DiffFile(path: path, newContent: content)]
        }
        return []
    }

    private static func resultText(_ content: JSONValue?) -> String {
        let text: String
        if let string = content?.string {
            text = string
        } else if let blocks = content?.array {
            text = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
        } else {
            text = ""
        }
        return text
            .replacingOccurrences(of: "<tool_use_error>", with: "")
            .replacingOccurrences(of: "</tool_use_error>", with: "")
    }

    // MARK: Session state

    private func translateSystem(_ frame: JSONValue) -> [AgentEvent] {
        switch frame["subtype"]?.string {
        case "init":
            var events: [AgentEvent] = []
            if let id = frame["session_id"]?.string {
                events.append(.conversationStarted(id: id, model: frame["model"]?.string))
            }
            if let mode = ClaudeMode.parse(frame["permissionMode"]?.string) {
                events.append(.modeChanged(mode))
            }
            return events
        case "session_state_changed":
            switch frame["state"]?.string {
            case "running": return [.phaseChanged(.running)]
            case "requires_action": return [.phaseChanged(.waitingForUser)]
            case "idle": return [.phaseChanged(.idle)]
            default: return []
            }
        case "status":
            var events: [AgentEvent] = []
            // The agent can change mode itself, for example when a plan is approved.
            if let mode = ClaudeMode.parse(frame["permissionMode"]?.string) {
                events.append(.modeChanged(mode))
            }
            events.append(.activity(frame["status"]?.string == "compacting" ? "Compacting conversation" : nil))
            return events
        case "api_retry":
            let attempt = frame["attempt"]?.int ?? 1
            let limit = frame["max_retries"]?.int ?? 0
            let reason = (frame["error"]?.string ?? "error").replacingOccurrences(of: "_", with: " ")
            return [
                .notice(Notice(level: .warning, text: "Retrying after \(reason) (attempt \(attempt) of \(limit))", key: "retry"))
            ]
        case "compact_boundary":
            return [.notice(Notice(level: .info, text: "Conversation compacted to free up context"))]
        default:
            return []
        }
    }

    private mutating func translateResult(_ frame: JSONValue) -> [AgentEvent] {
        let reason = frame["terminal_reason"]?.string ?? ""
        let isError = frame["is_error"]?.bool ?? false
        let resultText = frame["result"]?.string
        let usage = frame["usage"]

        let outcome: TurnSummary.Outcome =
            if reason.hasPrefix("aborted") {
                .interrupted
            } else if isError {
                .failed
            } else {
                .completed
            }
        let failureMessage: String? =
            outcome == .failed
            ? (resultText ?? frame["errors"]?.array?.compactMap(\.string).joined(separator: "\n")) : nil

        var events: [AgentEvent] = []
        // Local slash commands answer through `result` alone, with no assistant message.
        if outcome == .completed, !sawTextThisTurn, let resultText, !resultText.isEmpty {
            syntheticID += 1
            events.append(.textFinished(id: "result-\(syntheticID)", text: resultText, parentToolID: nil))
        }
        if outcome == .failed, let failureMessage, !failureMessage.isEmpty {
            let isAuth = failureMessage.localizedCaseInsensitiveContains("logged in")
                || failureMessage.localizedCaseInsensitiveContains("/login")
            events.append(.notice(Notice(level: .error, text: failureMessage, action: isAuth ? .signIn : nil)))
        }
        events.append(
            .turnFinished(
                TurnSummary(
                    outcome: outcome,
                    durationMs: frame["duration_ms"]?.int,
                    inputTokens: Self.inputTokens(usage),
                    outputTokens: usage?["output_tokens"]?.int,
                    totalCostUSD: frame["total_cost_usd"]?.double,
                    message: failureMessage)))
        events.append(.phaseChanged(.idle))
        sawTextThisTurn = false
        openBlocks.removeAll()
        return events
    }

    private static func inputTokens(_ usage: JSONValue?) -> Int? {
        guard let usage else { return nil }
        return (usage["input_tokens"]?.int ?? 0) + (usage["cache_read_input_tokens"]?.int ?? 0)
            + (usage["cache_creation_input_tokens"]?.int ?? 0)
    }

    private func translateRateLimit(_ frame: JSONValue) -> [AgentEvent] {
        guard let info = frame["rate_limit_info"] else { return [] }
        var windows: [RateLimitWindow] = []
        for (key, window) in info["unifiedWindows"]?.object ?? [:] {
            guard let utilization = window["utilization"]?.double else { continue }
            windows.append(
                RateLimitWindow(
                    id: key, label: Self.windowLabel(key), utilization: utilization,
                    resetsAt: window["resetsAt"]?.double.map(Date.init(timeIntervalSince1970:))))
        }
        windows.sort { $0.utilization > $1.utilization }
        let snapshot = RateLimitSnapshot(
            agent: .claude, windows: windows, isExhausted: info["status"]?.string == "rejected",
            resetsAt: info["resetsAt"]?.double.map(Date.init(timeIntervalSince1970:)))
        return [.rateLimit(snapshot)]
    }

    private static func windowLabel(_ key: String) -> String {
        switch key {
        case "five_hour": "5-hour limit"
        case "seven_day": "Weekly limit"
        case "seven_day_opus": "Weekly Opus limit"
        case "seven_day_sonnet": "Weekly Sonnet limit"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Approvals

    func approvalRequest(id: String, request: JSONValue) -> ApprovalRequest {
        let toolName = request["tool_name"]?.string ?? "Tool"
        let input = request["input"] ?? .object([:])
        let toolUseID = request["tool_use_id"]?.string
        let description = ToolDescriber.describe(name: toolName, input: input, workingDirectory: workingDirectory)

        switch toolName {
        case "AskUserQuestion":
            let questions = (input["questions"]?.array ?? []).map { value in
                let text = value["question"]?.string ?? ""
                return AgentQuestion(
                    id: text, header: value["header"]?.string ?? "Question", question: text,
                    options: (value["options"]?.array ?? []).map {
                        AgentQuestion.Option(label: $0["label"]?.string ?? "", detail: $0["description"]?.string ?? "")
                    },
                    allowsMultiple: value["multiSelect"]?.bool ?? false)
            }
            return ApprovalRequest(
                id: id, kind: .questions(questions), toolCallID: toolUseID, toolKind: .question,
                title: "Claude has a question", input: input)
        case "ExitPlanMode":
            return ApprovalRequest(
                id: id, kind: .plan(input["plan"]?.string ?? ""), toolCallID: toolUseID, toolKind: .plan,
                title: "Review the plan", input: input)
        default:
            let detail = toolName == "Bash" ? (input["command"]?.string ?? "") : description.detail
            let explanation = request["decision_reason"]?.string ?? request["title"]?.string
            return ApprovalRequest(
                id: id, toolCallID: toolUseID, toolKind: description.kind,
                title: Self.approvalTitle(for: description), detail: detail, reason: explanation,
                diff: ToolDescriber.previewDiff(name: toolName, input: input, workingDirectory: workingDirectory),
                input: input,
                rememberOptions: rememberOptions(from: request["permission_suggestions"]?.array ?? []))
        }
    }

    private static func approvalTitle(for description: ToolDescriber.Description) -> String {
        switch description.kind {
        case .shell: "Run this command?"
        case .edit: "Apply this edit?"
        case .write: "Write this file?"
        case .web: "Allow web access?"
        case .read: "Read this file?"
        default: "Allow \(description.title)?"
        }
    }

    private func rememberOptions(from suggestions: [JSONValue]) -> [RememberOption] {
        suggestions.enumerated().compactMap { index, suggestion in
            let scope = suggestion["destination"]?.string == "session" ? "this session" : "this project"
            switch suggestion["type"]?.string {
            case "addRules":
                guard let rule = suggestion["rules"]?[0], suggestion["behavior"]?.string == "allow" else { return nil }
                let subject = rule["ruleContent"]?.string ?? rule["toolName"]?.string ?? "this"
                return RememberOption(id: "\(index)", label: "Always allow \(subject) in \(scope)", payload: suggestion)
            case "setMode":
                guard suggestion["mode"]?.string == "acceptEdits" else { return nil }
                return RememberOption(id: "\(index)", label: "Accept all edits in \(scope)", payload: suggestion)
            default:
                return nil
            }
        }
    }
}

/// Claude Code's names for `ApprovalMode`.
enum ClaudeMode {
    static func launchValue(_ mode: ApprovalMode) -> String {
        switch mode {
        case .ask: "manual"
        case .acceptEdits: "acceptEdits"
        case .plan: "plan"
        case .auto: "auto"
        case .bypass: "bypassPermissions"
        }
    }

    static func controlValue(_ mode: ApprovalMode) -> String {
        mode == .ask ? "default" : launchValue(mode)
    }

    static func parse(_ value: String?) -> ApprovalMode? {
        switch value {
        case "default", "manual": .ask
        case "acceptEdits": .acceptEdits
        case "plan": .plan
        case "auto": .auto
        case "bypassPermissions": .bypass
        default: nil
        }
    }
}
