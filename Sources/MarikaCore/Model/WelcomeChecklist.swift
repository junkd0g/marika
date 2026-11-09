import Foundation

/// Setup follows one selected provider; another unconfigured provider never blocks it.
public struct WelcomeChecklist: Equatable, Sendable {
    public enum State: Equatable, Sendable { case complete, pending, checking, blocked, needsAttention }
    public let installation: State
    public let account: State
    public let project: State
    public var isReady: Bool { installation == .complete && account == .complete && project == .complete }
    public var completedSteps: Int { [installation, account, project].count { $0 == .complete } }

    public static func suggestedAgent(selected: AgentKind, statuses: [AgentKind: AgentStatus], claudeCredentialConfigured: Bool = true) -> AgentKind? {
        func ready(_ agent: AgentKind) -> Bool {
            WelcomeChecklist(status: statuses[agent], hasProject: false,
                credentialConfigured: agent != .claude || claudeCredentialConfigured).account == .complete
        }
        guard !ready(selected) else { return nil }
        return AgentKind.allCases.first { $0 != selected && ready($0) }
    }

    public init(status: AgentStatus?, hasProject: Bool, credentialConfigured: Bool = true) {
        project = hasProject ? .complete : .pending
        switch status?.readiness ?? .checking {
        case .checking:
            installation = status?.executable == nil ? .checking : .complete
            account = .checking
        case .notInstalled:
            installation = .pending
            account = .blocked
        case .signedOut:
            installation = .complete
            account = .pending
        case .unavailable:
            installation = status?.executable == nil ? .needsAttention : .complete
            account = .needsAttention
        case .ready:
            installation = .complete
            account = credentialConfigured ? .complete : .pending
        }
    }
}
