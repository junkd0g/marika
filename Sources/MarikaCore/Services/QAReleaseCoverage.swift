import Foundation

public struct QACoverageRow: Identifiable, Sendable {
    public var id: UUID { testCase.id }
    public var testCase: QACase
    public var result: QAStatus
    public var detail: String
    public var runID: UUID?
    public var current: Bool
}

public enum QAReleaseCoverage {
    public static func rows(_ qa: QAProject, currentSnapshot: VerificationSnapshot?) -> [QACoverageRow] {
        qa.cases.filter { !$0.archived }.map { test in
            var row = QACoverageRow(testCase: test, result: .notTested, detail: test.approved ? "Not tested for this build" : "Case needs approval", current: false)
            guard test.approved else { return row }
            let matching = qa.runs.filter {
                $0.environment == qa.environment && $0.build == qa.build && (qa.url.isEmpty || $0.url == qa.url)
            }
                .sorted { $0.startedAt > $1.startedAt }
            guard let run = matching.first(where: { $0.cases.contains { $0.id == test.id && $0.testCase.revision == test.revision } }),
                  let result = run.cases.first(where: { $0.id == test.id && $0.testCase.revision == test.revision }) else { return row }
            row.runID = run.id
            guard run.finishedAt != nil else { row.detail = "Run in progress"; return row }
            row.result = result.status
            row.current = currentSnapshot != nil && run.snapshot == currentSnapshot && run.freshnessNote == nil
            row.detail = row.current ? result.status.rawValue : "\(result.status.rawValue) · source outdated or unverified"
            return row
        }
    }

    public static func markdown(_ qa: QAProject, currentSnapshot: VerificationSnapshot?) -> String {
        let rows = rows(qa, currentSnapshot: currentSnapshot)
        var text = "# QA release coverage\n\nEnvironment: \(qa.environment)\n\nBuild: \(qa.build)\n\n"
        for row in rows {
            text += "- \(row.testCase.title): \(row.detail)\n  Requirement: \(row.testCase.requirement)\n"
            if let id = row.runID { text += "  Run: \(id)\n" }
        }
        text += "\nCoverage is limited to the configured, non-archived cases. Source freshness does not verify external services, tool versions or test data.\n"
        return text
    }
}
