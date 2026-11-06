import Foundation

/// Read-only queries against the installed `claude` CLI.
public enum ClaudeCLI {
    /// Asks the CLI whether it is signed in. The CLI answers with account details only; no
    /// credentials are involved.
    public static func status(executable: URL, environment: [String: String]) async -> AgentStatus {
        var status = AgentStatus(readiness: .signedOut, executable: executable)
        guard
            let result = try? await Command.run(
                executable, ["auth", "status", "--json"], environment: environment, timeout: 15),
            let json = try? JSONValue(parsing: result.stdout)
        else {
            status.readiness = .unavailable("Couldn't check the Claude Code CLI.")
            return status
        }

        if json["loggedIn"]?.bool == true {
            status.readiness = .ready
            status.account = json["email"]?.string
            status.plan = planName(json["subscriptionType"]?.string, authMethod: json["authMethod"]?.string)
        }
        return status
    }

    private static func planName(_ subscription: String?, authMethod: String?) -> String? {
        if let subscription, !subscription.isEmpty { return "\(subscription.capitalized) plan" }
        return authMethod == "claude.ai" ? "Claude plan" : "API billing"
    }

    /// Reads the live model and command lists. `initialize` makes no model request, so this
    /// costs nothing against the user's limits.
    public static func capabilities(executable: URL, environment: [String: String]) async -> AgentCapabilities? {
        let process = LineProcess(
            executable: executable,
            arguments: [
                "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                "--permission-prompt-tool", "stdio",
            ],
            environment: environment,
            workingDirectory: FileManager.default.temporaryDirectory)
        do {
            try process.start()
        } catch {
            return nil
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { process.terminate() }
        }
        defer { timeout.cancel() }

        let request: JSONValue = [
            "type": "control_request", "request_id": "probe", "request": ["subtype": "initialize"],
        ]
        guard let data = try? request.serialized() else { return nil }
        process.write(data)

        var capabilities: AgentCapabilities?
        for await output in process.output {
            guard case .line(let line) = output, let frame = try? JSONValue(parsing: line) else { continue }
            if frame["type"]?.string == "control_response", frame["response"]?["request_id"]?.string == "probe" {
                if let response = frame["response"]?["response"] {
                    capabilities = Self.capabilities(from: response)
                }
                process.closeInput()
            }
        }
        return capabilities
    }

    static func capabilities(from response: JSONValue) -> AgentCapabilities {
        let models = (response["models"]?.array ?? []).compactMap { model -> ModelOption? in
            guard let id = model["value"]?.string else { return nil }
            return ModelOption(
                id: id, name: model["displayName"]?.string ?? id, detail: model["description"]?.string ?? "",
                efforts: model["supportedEffortLevels"]?.array?.compactMap(\.string) ?? [])
        }
        let commands = (response["commands"]?.array ?? []).compactMap { command -> SlashCommand? in
            guard let name = command["name"]?.string else { return nil }
            return SlashCommand(
                name: name, detail: command["description"]?.string ?? "",
                argumentHint: command["argumentHint"]?.string ?? "")
        }
        return AgentCapabilities(models: models, commands: commands, version: response["claude_code_version"]?.string)
    }

    /// The environment for a Claude session under the chosen billing. In subscription mode any
    /// API key from the user's shell profile is removed, because the CLI would prefer it and
    /// quietly bill per token.
    public static func environment(base: [String: String], billing: ClaudeBilling, apiKey: String?) -> [String: String] {
        var environment = base
        // Asks the CLI for `session_state_changed` frames, the reliable end-of-turn signal.
        environment["CLAUDE_CODE_SDK_READS_SESSION_STATE"] = "1"
        environment["ANTHROPIC_API_KEY"] = nil
        environment["ANTHROPIC_AUTH_TOKEN"] = nil
        if billing == .apiKey { environment["ANTHROPIC_API_KEY"] = apiKey }
        return environment
    }
}
