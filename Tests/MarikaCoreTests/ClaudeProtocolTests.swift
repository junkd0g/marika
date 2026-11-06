import Foundation
import Testing

@testable import MarikaCore

/// These replay frames recorded from the real Claude Code CLI.
@MainActor
struct ClaudeProtocolTests {
    @Test func streamedTextRendersOnce() throws {
        let session = try replay("claude-text.jsonl")
        #expect(session.assistantText == ["hello"])
        #expect(session.turnEnds.first?.outcome == .completed)
        #expect(session.meta.conversationID != nil)
        #expect(session.phase == .idle)
    }

    @Test func toolCallsKeepOrderAndCarryDiffs() throws {
        let session = try replay("claude-tools.jsonl")
        #expect(session.tools.map(\.name) == ["Write", "Edit", "Bash"])
        #expect(session.tools.allSatisfy { $0.status == .succeeded })

        let write = session.tools[0]
        #expect(write.kind == .write)
        #expect(write.detail == "notes.txt", "paths should be shown relative to the project")
        #expect(write.diff.first?.additions == 1)

        let edit = session.tools[1]
        #expect(edit.diff.first?.additions == 1)
        #expect(edit.diff.first?.deletions == 1)
        #expect(edit.diff.first?.lines.first?.oldNumber == 1)

        let bash = session.tools[2]
        #expect(bash.kind == .shell)
        #expect(bash.output == "hello")
        #expect(session.assistantText.last == "Done.")
    }

    @Test func aToolCallIsNeverDuplicatedByItsFinalFrame() throws {
        let session = try replay("claude-tools.jsonl")
        #expect(Set(session.tools.map(\.id)).count == session.tools.count)
    }

    @Test func interruptingIsNotAFailure() throws {
        let session = try replay("claude-interrupt.jsonl")
        let summary = try #require(session.turnEnds.last)
        #expect(summary.outcome == .interrupted)
        #expect(session.notices.isEmpty, "stopping a turn should not show an error")
        #expect(session.tools.last?.status == .denied)
    }

    @Test func questionsBecomeStructuredApprovals() throws {
        let frames = try Fixture.frames("claude-ask.jsonl")
        let request = try #require(frames.first { $0["type"]?.string == "control_request" })
        let translator = ClaudeTranslator(workingDirectory: "/tmp/project")
        let approval = translator.approvalRequest(id: "1", request: try #require(request["request"]))

        guard case .questions(let questions) = approval.kind else {
            Issue.record("expected questions, got \(approval.kind)")
            return
        }
        #expect(questions.count == 1)
        #expect(questions[0].options.map(\.label) == ["Tabs", "Spaces"])
    }

    @Test func plansBecomeReviewableApprovals() throws {
        let frames = try Fixture.frames("claude-plan.jsonl")
        let request = try #require(
            frames.first { $0["request"]?["tool_name"]?.string == "ExitPlanMode" })
        let translator = ClaudeTranslator(workingDirectory: "/tmp/project")
        let approval = translator.approvalRequest(id: "1", request: try #require(request["request"]))

        guard case .plan(let text) = approval.kind else {
            Issue.record("expected a plan, got \(approval.kind)")
            return
        }
        #expect(text.contains("plan.txt"))
    }

    @Test func editApprovalsPreviewTheChange() throws {
        let frames = try Fixture.frames("claude-tools.jsonl")
        let request = try #require(frames.first { $0["request"]?["tool_name"]?.string == "Edit" })
        let translator = ClaudeTranslator(workingDirectory: "/tmp/project")
        let approval = translator.approvalRequest(id: "1", request: try #require(request["request"]))

        #expect(approval.title == "Apply this edit?")
        #expect(approval.detail == "notes.txt")
        #expect(approval.diff.first?.deletions == 1)
        #expect(approval.diff.first?.additions == 1)
        #expect(approval.rememberOptions.first?.label == "Accept all edits in this session")
    }

    @Test func rateLimitsReportPlanUsage() throws {
        var translator = ClaudeTranslator(workingDirectory: "/tmp")
        let frame = try #require(try Fixture.frames("claude-text.jsonl").first { $0["type"]?.string == "rate_limit_event" })
        guard case .rateLimit(let snapshot) = try #require(translator.translate(frame).first) else {
            Issue.record("expected a rate limit")
            return
        }
        #expect(snapshot.windows.first?.label == "Weekly limit")
        #expect(snapshot.windows.first?.resetsAt != nil)
        #expect(!snapshot.isExhausted)
    }

    @Test func initializeProvidesLiveModels() throws {
        let capabilities = ClaudeCLI.capabilities(from: try Fixture.json("claude-initialize.json"))
        #expect(capabilities.models.count == 3)
        #expect(capabilities.models.first?.efforts.contains("high") == true)
        #expect(capabilities.commands.map(\.name).contains("compact"))
        #expect(capabilities.version != nil)
    }

    @Test func theCLIHasTheLastWordOnTheMode() throws {
        var translator = ClaudeTranslator(workingDirectory: "/tmp")
        let events = translator.translate(["type": "system", "subtype": "status", "permissionMode": "acceptEdits"])
        guard case .modeChanged(let mode) = try #require(events.first) else {
            Issue.record("expected a mode change")
            return
        }
        #expect(mode == .acceptEdits)
    }

    @Test func failuresThatMeanSignedOutOfferSignIn() {
        var translator = ClaudeTranslator(workingDirectory: "/tmp")
        let events = translator.translate([
            "type": "result", "subtype": "success", "is_error": true, "terminal_reason": "completed",
            "result": "Not logged in · Please run /login",
        ])
        let notice = events.compactMap { event -> Notice? in
            if case .notice(let notice) = event { notice } else { nil }
        }.first
        #expect(notice?.action == .signIn)
    }

    @Test func subscriptionModeNeverLeaksAnAPIKey() {
        let shell = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "from-profile", "ANTHROPIC_AUTH_TOKEN": "from-profile"]
        let subscription = ClaudeCLI.environment(base: shell, billing: .subscription, apiKey: "stored")
        #expect(subscription["ANTHROPIC_API_KEY"] == nil)
        #expect(subscription["ANTHROPIC_AUTH_TOKEN"] == nil)

        let metered = ClaudeCLI.environment(base: shell, billing: .apiKey, apiKey: "stored")
        #expect(metered["ANTHROPIC_API_KEY"] == "stored")
    }
}
