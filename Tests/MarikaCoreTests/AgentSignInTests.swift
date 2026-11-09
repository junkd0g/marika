import Foundation
import Testing
@testable import MarikaCore

@MainActor struct AgentSignInTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marika-login-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func wait(_ phase: AgentSignIn.Phase, in flow: AgentSignIn) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while flow.phase != phase, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(flow.phase == phase, "Expected \(phase), got \(flow.phase): \(flow.message ?? "")")
    }

    @Test func duplicateClicksAreIgnoredAndExitZeroRequiresVerifiedSignIn() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let flow = AgentSignIn(root: root, pollInterval: .milliseconds(10))
        var command: URL?, opens = 0, checks = 0
        let open: (URL) -> Bool = { command = $0; opens += 1; return true }
        let verify: @MainActor () async -> AgentStatus.Readiness = { checks += 1; return .ready }
        flow.start(agent: .codex, executable: URL(fileURLWithPath: "/bin/echo"), open: open, verify: verify)
        flow.start(agent: .codex, executable: URL(fileURLWithPath: "/bin/echo"), open: open, verify: verify)
        #expect(flow.phase == .waiting && opens == 1 && checks == 0)
        let directory = try #require(command).deletingLastPathComponent()
        try Data("0\n".utf8).write(to: directory.appendingPathComponent("result"))
        try await wait(.succeeded, in: flow)
        #expect(checks == 1 && !flow.isPending)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func anUnconfirmedLoginReportsFailureAndCanRetry() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let flow = AgentSignIn(root: root, pollInterval: .milliseconds(10))
        var command: URL?
        let open: (URL) -> Bool = { command = $0; return true }
        flow.start(agent: .claude, executable: URL(fileURLWithPath: "/bin/echo"), open: open, verify: { .signedOut })
        let first = try #require(command)
        try Data("0\n".utf8).write(to: first.deletingLastPathComponent().appendingPathComponent("result"))
        try await wait(.failed, in: flow)
        #expect(flow.message?.contains("isn't confirmed") == true)
        flow.start(agent: .claude, executable: URL(fileURLWithPath: "/bin/echo"), open: open, verify: { .signedOut })
        #expect(flow.phase == .waiting && command != first)
        flow.stopWaiting()
    }

    @Test func missingCLIAndRejectedTerminalLaunchAreVisibleFailures() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let flow = AgentSignIn(root: root)
        flow.start(agent: .codex, executable: nil, open: { _ in Issue.record("A missing CLI must not launch"); return true }, verify: { .ready })
        #expect(flow.phase == .failed && flow.message?.contains("CLI") == true)
        flow.start(agent: .codex, executable: URL(fileURLWithPath: "/bin/echo"), open: { _ in false }, verify: { .ready })
        #expect(flow.phase == .failed && flow.message?.contains("Couldn't open Terminal") == true)
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func lateVerificationCannotUndoAConfirmedAccount() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let flow = AgentSignIn(root: root, pollInterval: .milliseconds(10))
        var command: URL?
        flow.start(agent: .codex, executable: URL(fileURLWithPath: "/bin/echo"), open: { command = $0; return true }, verify: {
            try? await Task.sleep(for: .milliseconds(300))
            return .signedOut
        })
        try Data("0\n".utf8).write(to: #require(command).deletingLastPathComponent().appendingPathComponent("result"))
        try await wait(.checking, in: flow)
        flow.update(status: AgentStatus(readiness: .ready))
        try await Task.sleep(for: .milliseconds(350))
        #expect(flow.phase == .succeeded)
        flow.update(status: AgentStatus(readiness: .signedOut))
        #expect(flow.phase == .idle)
    }

    @Test func aWedgedLoginTimesOutAndManualRecheckCanStillConfirmIt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let flow = AgentSignIn(root: root, timeout: .milliseconds(40), pollInterval: .milliseconds(10))
        flow.start(agent: .codex, executable: URL(fileURLWithPath: "/bin/echo"), open: { _ in true }, verify: { .ready })
        try await wait(.failed, in: flow)
        #expect(flow.message?.contains("longer than expected") == true)
        flow.update(status: AgentStatus(readiness: .ready))
        #expect(flow.phase == .succeeded)
        flow.stopWaiting()
    }

    @Test func switchingAccountsDoesNotMistakeTheOldAccountForCompletion() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let flow = AgentSignIn(root: root, pollInterval: .milliseconds(10))
        let original = AgentStatus(readiness: .ready, account: "original@example.test")
        var command: URL?
        flow.start(agent: .codex, executable: URL(fileURLWithPath: "/bin/echo"), previousStatus: original,
            open: { command = $0; return true }, verify: { .ready })
        flow.update(status: original)
        #expect(flow.phase == .waiting)
        try Data("130\n".utf8).write(to: #require(command).deletingLastPathComponent().appendingPathComponent("result"))
        try await wait(.failed, in: flow)
        flow.start(agent: .codex, executable: URL(fileURLWithPath: "/bin/echo"), previousStatus: original,
            open: { _ in true }, verify: { .ready })
        flow.update(status: AgentStatus(readiness: .ready, account: "replacement@example.test"))
        #expect(flow.phase == .succeeded)
    }

    @Test(arguments: AgentKind.allCases)
    func theTerminalScriptPreservesArgumentsAndExitCodeWithQuotedPaths(agent: AgentKind) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("agent's test CLI")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.args\"\necho fixture-login\nexit 7\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let flow = AgentSignIn(root: root, pollInterval: .milliseconds(10))
        var command: URL?
        flow.start(agent: agent, executable: executable, open: { command = $0; return true }, verify: { .signedOut })
        let result = try await Command.run(URL(fileURLWithPath: "/bin/zsh"), [try #require(command).path], timeout: 5)
        #expect(result.status == 7 && result.output.contains("fixture-login"))
        let recorded = try String(contentsOf: URL(fileURLWithPath: executable.path + ".args"), encoding: .utf8)
        #expect(recorded == (agent == .claude ? "auth\nlogin\n" : "login\n"))
        try await wait(.failed, in: flow)
        #expect(flow.message?.contains("7") == true)
    }
}
