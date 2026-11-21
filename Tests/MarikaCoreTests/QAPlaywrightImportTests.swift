import Foundation
import Testing
@testable import MarikaCore

struct QAPlaywrightImportTests {
    @Test func matchesNestedResultsByRevisionAndDistinguishesRetries() throws {
        var test = QACase(title: "Checkout", steps: [
            QAStep(action: "Open", expected: "Loads", automation: QAAction(.navigate, value: "http://localhost:8080")),
            QAStep(action: "Check", expected: "Visible", automation: QAAction(.assertVisible, selector: "#submit"))
        ])
        test.approved = true
        let report = """
        {"suites":[{"suites":[{"specs":[{"tests":[
          {"projectName":"chromium","projectId":"a","status":"unexpected","expectedStatus":"passed",
           "annotations":[{"type":"marika-case","description":"\(test.id):1"}],
           "results":[{"status":"failed","errors":[{"message":"Missing submit"}],
                       "attachments":[{"name":"trace","path":"/runner/results/trace.zip"}]}]},
          {"projectName":"firefox","projectId":"b","status":"flaky","expectedStatus":"passed",
           "annotations":[{"type":"marika-case","description":"\(test.id):1"}],
           "results":[{"status":"timedOut"},{"status":"passed"}]},
          {"projectName":"webkit","projectId":"c","status":"expected","expectedStatus":"passed",
           "annotations":[{"type":"marika-case","description":"\(test.id):2"}],
           "results":[{"status":"passed"}]}
        ]}]}]}],"stats":{"startTime":"2026-11-21T12:34:00.000Z"}}
        """
        let imported = try QAPlaywrightImport(data: Data(report.utf8), cases: [test])
        let result = try #require(imported.results.first)
        #expect(try QATools.playwright(test).contains("\(test.id):1"))
        #expect(imported.startedAt != nil)
        #expect(imported.ignored == 1)
        #expect(result.playwright?.map(\.status) == [.failed, .blocked])
        #expect(result.status == .failed)
        #expect(result.steps.allSatisfy { $0.status == .notTested })
        #expect(result.playwright?.first?.error == "Missing submit")
        #expect(result.playwright?.first?.traceHint == "trace.zip")
        test.approved = false
        #expect(throws: QAError.self) { try QAPlaywrightImport(data: Data(report.utf8), cases: [test]) }
    }
}
