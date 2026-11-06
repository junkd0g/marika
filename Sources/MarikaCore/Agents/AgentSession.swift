import Foundation

/// Everything needed to start talking to an agent.
public struct AgentLaunch: Sendable {
    public var executable: URL
    public var environment: [String: String]
    public var workingDirectory: URL
    /// Continue this conversation instead of starting a new one.
    public var conversationID: String?
    public var settings: AgentSettings
    public var browser: BrowserMCPConfiguration?
    public var projectInstructions = ""
    public var projectMCP: [String: JSONValue] = [:]
    public var additionalDirectories: [URL] = []
    public var runtime: WorkspaceRuntime?
    public var sessionDirectory: URL { runtime.map { URL(fileURLWithPath: $0.directory) } ?? workingDirectory }
    /// Runs before an agent process starts again mid-session, so the checks made when the session
    /// opened still apply. Throwing stops the launch.
    public var preflight: (@Sendable () async throws -> Void)?

    public init(
        executable: URL, environment: [String: String], workingDirectory: URL, conversationID: String? = nil,
        settings: AgentSettings, preflight: (@Sendable () async throws -> Void)? = nil, browser: BrowserMCPConfiguration? = nil
    ) {
        self.executable = executable
        self.environment = environment.merging(browser?.environment ?? [:]) { _, new in new }
        self.workingDirectory = workingDirectory
        self.conversationID = conversationID
        self.settings = settings
        self.preflight = preflight
        self.browser = browser
    }
}

/// A live conversation with one agent. Each agent adapts its own wire protocol to this.
public protocol AgentSession: Actor {
    nonisolated var events: AsyncStream<AgentEvent> { get }

    func send(_ input: UserInput) async throws
    func interrupt() async
    /// Whether work is still running. A failed send must not mark a running turn as finished.
    func hasActiveTurn() async -> Bool
    func answer(requestID: String, decision: ApprovalDecision) async
    func update(settings: AgentSettings) async
    func shutdown() async
}

public enum AgentError: LocalizedError {
    case launchFailed(String)
    case protocolError(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message), .protocolError(let message), .timedOut(let message): message
        }
    }
}
