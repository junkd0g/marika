import Foundation

/// Read-only queries against the installed `codex` CLI.
public enum CodexCLI {
    public struct Probe: Sendable {
        public var status: AgentStatus
        public var capabilities: AgentCapabilities?
        public var rateLimit: RateLimitSnapshot?
    }

    private static let timeout: Duration = .seconds(10)

    public static func probe(executable: URL, environment: [String: String]) async -> Probe {
        var probe = Probe(status: AgentStatus(readiness: .signedOut, executable: executable))
        let connection = CodexConnection(
            executable: executable, environment: environment,
            workingDirectory: FileManager.default.temporaryDirectory, inbound: { _ in })
        do {
            try await connection.start()
            probe.status.version = try await connection.initialize(timeout: timeout)
            let account = try await connection.request("account/read", timeout: timeout)
            apply(account: account, to: &probe.status)
            probe.capabilities = try? await capabilities(using: connection)
            if let limits = try? await connection.request("account/rateLimits/read", timeout: timeout) {
                probe.rateLimit = limits["rateLimits"].flatMap(CodexTranslator.rateLimit)
            }
        } catch {
            // Only an explicit answer means signed out. Anything else is the check itself failing.
            probe.status.readiness = .unavailable(error.localizedDescription)
        }
        await connection.close()
        return probe
    }

    private static func apply(account result: JSONValue, to status: inout AgentStatus) {
        guard let account = result["account"], !account.isNull else {
            // `requiresOpenaiAuth: false` means a provider that needs no OpenAI login.
            status.readiness = result["requiresOpenaiAuth"]?.bool == false ? .ready : .signedOut
            return
        }
        status.readiness = .ready
        switch account["type"]?.string {
        case "chatgpt":
            status.account = account["email"]?.string
            status.plan = account["planType"]?.string.map(planName) ?? "ChatGPT plan"
        case "apiKey":
            status.plan = "API billing"
        case "amazonBedrock":
            status.plan = "Amazon Bedrock"
        case "gcp":
            status.plan = "Google Cloud"
        default:
            status.plan = account["type"]?.string
        }
    }

    /// The wire values run words together, as in `promax`.
    static func planName(_ plan: String) -> String {
        let names = [
            "free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "promax": "Pro Max",
            "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu",
        ]
        let name = names[plan] ?? plan.replacingOccurrences(of: "_", with: " ").capitalized
        return "ChatGPT \(name)"
    }

    static func capabilities(using connection: CodexConnection) async throws -> AgentCapabilities {
        var models: [ModelOption] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = ["limit": 50, "includeHidden": false]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await connection.request("model/list", .object(params), timeout: timeout)
            models += (result["data"]?.array ?? []).compactMap(option)
            cursor = result["nextCursor"]?.string
        } while cursor != nil
        return AgentCapabilities(models: models, commands: commands)
    }

    static func option(_ model: JSONValue) -> ModelOption? {
        guard model["hidden"]?.bool != true, let id = model["model"]?.string ?? model["id"]?.string else { return nil }
        let tiers: [ServiceTierOption]?
        if let advertised = model["serviceTiers"]?.array, !advertised.isEmpty {
            tiers = advertised.compactMap { tier in
                guard let id = tier["id"]?.string, !id.isEmpty else { return nil }
                return ServiceTierOption(id: id, name: tier["name"]?.string ?? ServiceTierOption.displayName(id),
                                         detail: tier["description"]?.string ?? "")
            }
        } else {
            // Older app-servers advertise just the additional speed IDs.
            tiers = model["additionalSpeedTiers"]?.array?.compactMap { tier in
                tier.string.map { ServiceTierOption(id: $0, name: ServiceTierOption.displayName($0)) }
            }
        }
        return ModelOption(
            id: id, name: model["displayName"]?.string ?? id, detail: model["description"]?.string ?? "",
            efforts: (model["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string },
            isDefault: model["isDefault"]?.bool ?? false, defaultEffort: model["defaultReasoningEffort"]?.string,
            serviceTiers: tiers, defaultServiceTier: model["defaultServiceTier"]?.string)
    }

    private static let commands = [
        SlashCommand(name: "compact", detail: "Free up context by summarizing the conversation so far"),
        SlashCommand(name: "review", detail: "Review uncommitted changes, or follow your instructions", argumentHint: "[instructions]"),
    ]
}
