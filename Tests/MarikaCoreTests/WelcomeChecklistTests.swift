import Foundation
import Testing
@testable import MarikaCore

struct WelcomeChecklistTests {
    @Test func aReadyAlternativeIsSuggestedWithoutReplacingAReadyChoice() {
        let statuses: [AgentKind: AgentStatus] = [.claude: AgentStatus(readiness: .notInstalled), .codex: AgentStatus(readiness: .ready)]
        #expect(WelcomeChecklist.suggestedAgent(selected: .claude, statuses: statuses) == .codex)
        #expect(WelcomeChecklist.suggestedAgent(selected: .codex, statuses: statuses) == nil)
        #expect(WelcomeChecklist.suggestedAgent(selected: .codex, statuses: [.claude: AgentStatus(readiness: .ready)], claudeCredentialConfigured: false) == nil)
        #expect(WelcomeChecklist.suggestedAgent(selected: .claude, statuses: [.claude: AgentStatus(readiness: .ready), .codex: AgentStatus(readiness: .ready)]) == nil)
    }
    @Test func aMissingAgentDoesNotBlockChoosingAProjectOrPretendToBeSignedIn() {
        let checklist = WelcomeChecklist(status: AgentStatus(readiness: .notInstalled), hasProject: true)
        #expect(checklist.installation == .pending && checklist.account == .blocked)
        #expect(checklist.project == .complete && !checklist.isReady)
        #expect(checklist.completedSteps == 1)
    }

    @Test func checkingAndFailedChecksNeverCountAsSignedOutOrReady() {
        let unknown = WelcomeChecklist(status: nil, hasProject: false)
        #expect(unknown.installation == .checking && unknown.account == .checking && !unknown.isReady)
        let failure = WelcomeChecklist(status: AgentStatus(readiness: .unavailable("Timed out"), executable: URL(fileURLWithPath: "/fixture/codex")), hasProject: true)
        #expect(failure.installation == .complete && failure.account == .needsAttention && !failure.isReady)
        let missing = WelcomeChecklist(status: AgentStatus(readiness: .unavailable("Couldn't locate CLI")), hasProject: true)
        #expect(missing.installation == .needsAttention && !missing.isReady)
    }

    @Test func signingInAndOpeningAProjectAreBothRequiredForTheSelectedProvider() {
        let signedOut = WelcomeChecklist(status: AgentStatus(readiness: .signedOut), hasProject: true)
        #expect(signedOut.installation == .complete && signedOut.account == .pending && !signedOut.isReady)
        let noProject = WelcomeChecklist(status: AgentStatus(readiness: .ready), hasProject: false)
        #expect(noProject.completedSteps == 2 && !noProject.isReady)
        let ready = WelcomeChecklist(status: AgentStatus(readiness: .ready), hasProject: true)
        #expect(ready.isReady && ready.completedSteps == 3)
    }

    @Test func setupProgressSurvivesRelaunchAndOlderPreferencesStillDecode() throws {
        var workspace = Workspace(projects: [Project(path: "/fixture")])
        workspace.preferences.welcomeCompleted = false
        let unfinished = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(unfinished.preferences.welcomeCompleted == false)
        workspace.preferences.welcomeCompleted = true
        let finished = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(finished.preferences.welcomeCompleted == true)
        let legacy = try JSONDecoder().decode(Preferences.self, from: Data(#"{"defaultAgent":"codex","defaultMode":"ask","claudeBilling":"subscription"}"#.utf8))
        #expect(legacy.welcomeCompleted == nil && legacy.defaultAgent == .codex)
    }

    @Test func aCLILoginDoesNotReplaceARequiredAPIKey() {
        let checklist = WelcomeChecklist(status: AgentStatus(readiness: .ready), hasProject: true, credentialConfigured: false)
        #expect(checklist.installation == .complete && checklist.account == .pending && !checklist.isReady)
    }
}
