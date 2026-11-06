import Foundation

public enum CodeCompletion {
    public static func prompt(path: String, text: String, offset: Int) -> String {
        let source = text as NSString
        let cursor = min(source.length, max(0, offset))
        let before = source.substring(to: cursor)
        let after = source.substring(from: cursor)
        return """
        Complete code at the cursor in \(path). Return only a JSON object {"insert":"code to insert"}.
        Insert at most 8 lines. Do not repeat existing prefix or suffix. Preserve indentation.
        Do not use tools, read files, run commands, or include explanations. If uncertain, return {"insert":""}.
        Code before cursor:
        \(String(before.suffix(6000)))
        <CURSOR>
        Code after cursor:
        \(String(after.prefix(2000)))
        """
    }
    public static func insertion(from response: String) throws -> String {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), let first = json.firstIndex(of: "\n"), let last = json.range(of: "```", options: .backwards), first < last.lowerBound {
            json = String(json[json.index(after: first)..<last.lowerBound])
        }
        let value = try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
        guard let insertion = value["insert"], insertion.utf8.count <= 4000, insertion.components(separatedBy: "\n").count <= 8,
              !insertion.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AgentError.protocolError("The agent returned an invalid code suggestion.")
        }
        return insertion
    }
    public static func request(agent: any AgentSession, prompt: String) async throws -> String {
        do {
            let value = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await agent.send(UserInput(text: prompt))
                    var reply = ""
                    for await event in agent.events {
                        try Task.checkCancellation()
                        switch event {
                        case .textFinished(_, let text, nil): reply = text
                        case .approvalRequested(let request): await agent.answer(requestID: request.id, decision: .deny)
                        case .turnFinished: return try insertion(from: reply)
                        case .terminated(_, let message): throw AgentError.launchFailed(message ?? "Suggestion agent stopped.")
                        default: break
                        }
                    }
                    throw CancellationError()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw AgentError.timedOut("Code suggestion timed out.")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
            await agent.shutdown()
            return value
        } catch { await agent.shutdown(); throw error }
    }
}
