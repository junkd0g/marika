import Foundation

/// A coding agent Marika can drive. The agent is fixed per session, because a conversation's
/// history lives inside that agent's own harness; the model can change at any time.
public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    /// The label used in pickers.
    public var displayName: String {
        switch self {
        case .claude: "Claude Agent"
        case .codex: "Codex"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// The official command-line tool this agent runs through.
    public var executableName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }
}

/// How much the agent may do without asking. Each agent maps these to its own controls.
public enum ApprovalMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case ask
    case acceptEdits
    case plan
    case auto
    case bypass

    public var id: String { rawValue }

    /// Names differ by agent where the behaviour does. Each agent's controls work differently, and
    /// a label must never promise more than that agent delivers.
    public func title(for agent: AgentKind) -> String {
        switch self {
        case .ask: "Ask first"
        case .acceptEdits: "Accept edits"
        case .plan: agent == .codex ? "Read only" : "Plan only"
        case .auto: "Auto"
        case .bypass: "Bypass"
        }
    }

    public func summary(for agent: AgentKind) -> String {
        switch (self, agent) {
        case (.ask, .claude):
            "Edits and commands that change things ask. Read-only commands inside the project can run without asking"
        case (.ask, .codex):
            "Approve every command and edit. Approved commands can use the network. MCP tools marked read-only don't ask"
        case (.acceptEdits, .claude):
            "Edits, read-only commands and file commands such as rm, mv and cp run inside the project without asking, including deleting folders and overwriting files. Other commands ask"
        case (.acceptEdits, .codex):
            "Edits to ordinary project files apply automatically. Commands still ask, and so do protected folders such as .git"
        case (.plan, .claude):
            "Read and plan; no changes until you approve"
        case (.plan, .codex):
            "Can read any file on your Mac, not just this project. Changes are blocked unless the agent asks and you approve. MCP tools marked read-only don't ask"
        case (.auto, .claude):
            "A safety check reviews each action and asks when unsure"
        case (.auto, .codex):
            "Reads any file. Changes the project and temp folders without asking, except protected folders such as .git. Anything else is blocked unless the agent asks and you approve"
        case (.bypass, _):
            "No checks at all. Only for disposable environments"
        }
    }

    public var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .acceptEdits: "pencil.and.outline"
        case .plan: "list.bullet.clipboard"
        case .auto: "wand.and.sparkles"
        case .bypass: "exclamationmark.shield"
        }
    }
}

/// The settings a session runs with. Any of them can change between turns.
public struct AgentSettings: Codable, Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public var serviceTier: String?
    public var mode: ApprovalMode

    public init(model: String? = nil, effort: String? = nil, mode: ApprovalMode = .ask, serviceTier: String? = nil) {
        self.model = model
        self.effort = effort
        self.mode = mode
        self.serviceTier = serviceTier
    }
}

public struct ServiceTierOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String

    public init(id: String, name: String, detail: String = "") {
        self.id = Self.requestValue(id)
        self.name = name
        self.detail = detail
    }

    public static let standard = ServiceTierOption(id: "default", name: "Standard")

    public static func requestValue(_ tier: String) -> String {
        switch tier {
        case "fast": "priority"
        case "standard": "default"
        default: tier
        }
    }

    public static func displayName(_ tier: String) -> String {
        switch requestValue(tier) {
        case "default": "Standard"
        case "priority": "Fast"
        case "ultrafast": "Ultrafast"
        default: tier.capitalized
        }
    }
}

public struct ModelOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var efforts: [String]
    public var isDefault: Bool
    public var defaultEffort: String?
    public var serviceTiers: [ServiceTierOption]?
    public var defaultServiceTier: String?

    public init(
        id: String, name: String, detail: String = "", efforts: [String] = [], isDefault: Bool = false,
        defaultEffort: String? = nil, serviceTiers: [ServiceTierOption]? = nil, defaultServiceTier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.efforts = efforts
        self.isDefault = isDefault
        self.defaultEffort = defaultEffort
        self.serviceTiers = serviceTiers
        self.defaultServiceTier = defaultServiceTier
    }

    /// Standard is always available; faster tiers must come from the active model's catalog.
    public var speedOptions: [ServiceTierOption] {
        var seen: Set<String> = []
        return ([.standard] + (serviceTiers ?? [])).filter { seen.insert($0.id).inserted }
    }
}

public struct SlashCommand: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var detail: String
    public var argumentHint: String
    /// False for commands that would replace a running turn rather than add to it.
    public var runsDuringTurn: Bool

    public var id: String { name }

    public init(name: String, detail: String, argumentHint: String = "", runsDuringTurn: Bool = true) {
        self.name = name
        self.detail = detail
        self.argumentHint = argumentHint
        self.runsDuringTurn = runsDuringTurn
    }
}

/// What an installed agent reports about itself.
public struct AgentCapabilities: Codable, Equatable, Sendable {
    public var models: [ModelOption]
    public var commands: [SlashCommand]
    public var version: String?

    public init(models: [ModelOption] = [], commands: [SlashCommand] = [], version: String? = nil) {
        self.models = models
        self.commands = commands
        self.version = version
    }
}

/// Whether an agent is ready to use on this Mac. Marika only ever reads this from the
/// agent's own CLI; credentials stay with the CLI and never pass through the app.
public struct AgentStatus: Equatable, Sendable {
    public enum Readiness: Equatable, Sendable {
        case checking
        case notInstalled
        case signedOut
        /// The check itself failed. The agent may still work, so this must not read as signed out.
        case unavailable(String)
        case ready
    }

    public var readiness: Readiness
    public var executable: URL?
    public var version: String?
    public var account: String?
    public var plan: String?

    public init(
        readiness: Readiness = .checking, executable: URL? = nil, version: String? = nil,
        account: String? = nil, plan: String? = nil
    ) {
        self.readiness = readiness
        self.executable = executable
        self.version = version
        self.account = account
        self.plan = plan
    }
}

/// How a Claude session is paid for.
public enum ClaudeBilling: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The Claude plan the user signed in to in the Claude Code CLI.
    case subscription
    /// The user's own Console API key, charged per token.
    case apiKey

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .subscription: "Claude plan"
        case .apiKey: "API key (pay per token)"
        }
    }
}

public struct RateLimitWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// 0...1
    public var utilization: Double
    public var resetsAt: Date?

    public init(id: String, label: String, utilization: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct RateLimitSnapshot: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var windows: [RateLimitWindow]
    public var isExhausted: Bool
    public var resetsAt: Date?

    public init(agent: AgentKind, windows: [RateLimitWindow], isExhausted: Bool = false, resetsAt: Date? = nil) {
        self.agent = agent
        self.windows = windows
        self.isExhausted = isExhausted
        self.resetsAt = resetsAt
    }
}

public struct ContextUsage: Codable, Equatable, Sendable {
    public var usedTokens: Int
    public var maxTokens: Int

    public init(usedTokens: Int, maxTokens: Int) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
    }

    public var fraction: Double {
        maxTokens > 0 ? min(1, Double(usedTokens) / Double(maxTokens)) : 0
    }
}

public struct ImageAttachment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var path: String
    public var mediaType: String

    public var id: String { path }

    public init(path: String, mediaType: String) {
        self.path = path
        self.mediaType = mediaType
    }
}

public struct UserInput: Sendable, Equatable {
    public var text: String
    public var images: [ImageAttachment]

    public init(text: String, images: [ImageAttachment] = []) {
        self.text = text
        self.images = images
    }
}

/// What a session is doing right now.
public enum AgentPhase: String, Codable, Sendable {
    case idle
    case running
    case waitingForUser
}
