import Foundation

public struct Project: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: String
    public var name: String
    public var spaceID: UUID?
    /// Legacy filenames, retained for decoding older workspaces. Trust now requires matching digests.
    public var acceptedConfigFiles: [String]?
    public var acceptedConfigDigests: [String: String]?
    public var previewAddress: String?
    /// The project's main conversation, separate from task agents and older history.
    public var conversationSessionID: UUID?
    /// Last channel or agent DM shown in Chat, independent of the main project conversation.
    public var chatSessionID: UUID?
    public var chatReadDates: [String: Date]?
    public var scanProvider: AgentKind?
    public var scanModel: String?
    public var statsAgentID: UUID?
    public var apiCollection: APICollection?
    public var apiAgentID: UUID?
    public var apiPublisherID: UUID?
    public var apiDrafts: [String: APIEndpoint]?
    public var pipelineRuns: [PipelineResult]?
    public var scans: [CodeScan]?
    public var tools: ProjectTools?
    public var layout: ProjectLayout?
    public var previewConfiguration: PreviewConfiguration?
    public var repositoryPaths: [String]?
    public var selectedRepositoryPath: String?
    public var repositoryLayouts: [String: ProjectLayout]?
    public var debugRuns: [DebugRun]?
    public var artifacts: [ProjectArtifact]?
    public var research: [ResearchRun]?
    public var comparisons: [ModelComparison]?
    public var knowledge: ProjectKnowledge?
    public var taskQueue: AgentTaskQueue?
    public var taskActivity: [TaskActivity]?
    public var runtime: WorkspaceRuntime?
    public var design: DesignDocument?
    public var designVersions: [DesignVersion]?

    public init(id: UUID = UUID(), path: String, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.spaceID = ProjectSpace.personalID
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var repositoryURLs: [URL] { ([path] + (repositoryPaths ?? []).filter { $0 != path }).map { URL(fileURLWithPath: $0) } }
    public var editorURL: URL { repositoryURLs.first { $0.path == selectedRepositoryPath } ?? url }
}

public struct SessionDraft: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var images: [ImageAttachment]

    public init(text: String = "", images: [ImageAttachment] = []) {
        self.text = text
        self.images = images
    }

    public var isEmpty: Bool { text.isEmpty && images.isEmpty }
}

public struct SessionMeta: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var agent: AgentKind
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The conversation id inside the agent, once it has one.
    public var conversationID: String?
    public var model: String?
    public var effort: String?
    public var serviceTier: String?
    public var mode: ApprovalMode
    public var totalCostUSD: Double?
    /// Kept with metadata so drafts can be restored without loading every transcript.
    public var draft: SessionDraft?
    public var agentTask: AgentTask?
    /// A provider switch starts a fresh harness; seed it with the visible conversation on send.
    public var needsProviderContext: Bool?
    public var agentHandle: String?
    public var previousProviderCostUSD: Double?
    /// A user-requested handoff to apply once the current turn becomes idle.
    public var queuedAgent: AgentKind?
    public var taskPlan: [TodoItem]?
    public var taskVerification: TaskVerificationRecord?
    public var attention: SessionAttention?
    public var dismissedAttentionEvent: String?

    public init(
        id: UUID = UUID(), projectID: UUID, agent: AgentKind, title: String = "New session", createdAt: Date = Date(),
        updatedAt: Date = Date(), conversationID: String? = nil, model: String? = nil, effort: String? = nil,
        mode: ApprovalMode = .ask, totalCostUSD: Double? = nil, draft: SessionDraft? = nil, agentTask: AgentTask? = nil,
        serviceTier: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.agent = agent
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.conversationID = conversationID
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
        self.mode = mode
        self.totalCostUSD = totalCostUSD
        self.draft = draft
        self.agentTask = agentTask
    }

    public var hasDraft: Bool { draft.map { !$0.isEmpty } ?? false }

    public var settings: AgentSettings {
        get { AgentSettings(model: model, effort: effort, mode: mode, serviceTier: serviceTier) }
        set {
            model = newValue.model
            effort = newValue.effort
            serviceTier = newValue.serviceTier
            mode = newValue.mode
        }
    }
}

public struct AgentTask: Codable, Equatable, Hashable, Sendable {
    public var prompt: String
    public var parentSessionID: UUID?
    public var workspace: AgentWorkspace?
    public var queueID: UUID?
    public var ticketID: UUID?

    public init(prompt: String, parentSessionID: UUID? = nil) {
        self.prompt = prompt
        self.parentSessionID = parentSessionID
    }
}

/// Everything Marika remembers apart from transcripts.
public struct Workspace: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var sessions: [SessionMeta]
    public var preferences: Preferences
    public var selectedProjectID: UUID?
    public var spaces: [ProjectSpace]
    public var selectedSpaceID: UUID?

    public init(projects: [Project] = [], sessions: [SessionMeta] = [], preferences: Preferences = Preferences(),
                spaces: [ProjectSpace] = [.personal], selectedSpaceID: UUID? = nil) {
        self.projects = projects
        self.sessions = sessions
        self.preferences = preferences
        self.spaces = spaces
        self.selectedSpaceID = selectedSpaceID
        normalizeSpaces()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        sessions = try container.decodeIfPresent([SessionMeta].self, forKey: .sessions) ?? []
        preferences = try container.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
        selectedProjectID = try container.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        spaces = try container.decodeIfPresent([ProjectSpace].self, forKey: .spaces) ?? [.personal]
        selectedSpaceID = try container.decodeIfPresent(UUID.self, forKey: .selectedSpaceID)
        normalizeSpaces()
    }

    public func conversation(for projectID: UUID) -> SessionMeta? {
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        let conversations = sessions.filter { $0.projectID == projectID && $0.agentTask == nil }
        if let id = project.conversationSessionID, let saved = conversations.first(where: { $0.id == id }) { return saved }
        return conversations.max { $0.updatedAt < $1.updatedAt }
    }

    public func chat(for projectID: UUID) -> SessionMeta? {
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        if let id = project.chatSessionID,
           let selected = sessions.first(where: { $0.id == id && $0.projectID == projectID }) { return selected }
        return conversation(for: projectID)
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var defaultAgent: AgentKind
    public var defaultMode: ApprovalMode
    public var claudeBilling: ClaudeBilling
    public var taskNotifications: Bool?
    /// Missing in older workspaces; existing projects skip first-run setup on upgrade.
    public var welcomeCompleted: Bool?

    public init(defaultAgent: AgentKind = .claude, defaultMode: ApprovalMode = .ask, claudeBilling: ClaudeBilling = .subscription) {
        self.defaultAgent = defaultAgent
        self.defaultMode = defaultMode
        self.claudeBilling = claudeBilling
    }
}
