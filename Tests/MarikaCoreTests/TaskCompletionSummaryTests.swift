import Foundation
import Testing
@testable import MarikaCore

struct TaskCompletionSummaryTests {
    private func item(_ content: TranscriptItem.Content) -> TranscriptItem { TranscriptItem(id: UUID().uuidString, content: content) }

    @Test func latestTurnExcludesEarlierEditsDeniedEditsAndNestedAgents() throws {
        func edit(_ path: String, status: ToolStatus = .succeeded) -> TranscriptItem {
            item(.tool(ToolCall(id: path, name: "edit", kind: .edit, title: path, detail: "", status: status, diff: [DiffFile(path: path)])))
        }
        var nested = edit("nested.swift"); nested.parentToolID = "child"
        let items = [edit("earlier.swift"), item(.turnEnd(TurnSummary(outcome: .completed))),
            item(.user(text: "Next task", images: [])), edit("current.swift"), edit("denied.swift", status: .denied), nested,
            item(.assistant(text: "Done")), item(.turnEnd(TurnSummary(outcome: .completed)))]
        let summary = try #require(TaskCompletionSummary(items: items))
        #expect(summary.changedFiles == ["current.swift"])
        #expect(summary.reply == "Done" && summary.outcome == .completed)
        #expect(TaskCompletionSummary(items: items + [item(.user(text: "Continue", images: []))]) == nil)
        #expect(TaskCompletionSummary(items: []) == nil)
    }

    @Test func commandSuccessDoesNotClaimTestsPassedAndOldVerificationIsNotCurrent() throws {
        let summary = try #require(TaskCompletionSummary(items: [item(.tool(ToolCall(id: "shell", name: "shell", kind: .shell,
            title: "echo ok", detail: "", status: .succeeded))), item(.turnEnd(TurnSummary(outcome: .interrupted)))]))
        #expect(summary.outcome == .interrupted && summary.commands.count == 1)
        #expect(!summary.includes(TaskVerificationRecord(command: "tests", output: "ok", succeeded: true, date: .distantPast)))
        #expect(summary.includes(TaskVerificationRecord(command: "tests", output: "failed", succeeded: false, date: .distantFuture)))
    }
}
