import Foundation
import Testing
@testable import MarikaCore

struct ScanReviewTests {
    @Test func publishedReviewsStayCompleteDuringFollowUpConversationTurns() {
        let session = UUID()
        var scan = CodeScan(id: UUID(), date: .now, agentSessionID: session, files: 1,
                            linesByLanguage: ["Swift": 1], markerLines: 0, skipped: 0, limited: false)
        #expect(ScanReviewActivity(scans: [scan], sessionID: session, isBusy: true).isReviewing)
        scan.review = ScanReview(summary: "Reviewed.", inspectedFiles: ["File.swift"], findings: [])
        #expect(!ScanReviewActivity(scans: [scan], sessionID: session, isBusy: false).isReviewing)
        #expect(!ScanReviewActivity(scans: [scan], sessionID: session, isBusy: true).isReviewing)
        // Another worker can start while the previously published report stays visible.
        #expect(ScanReviewActivity(scans: [scan], sessionID: UUID(), isBusy: true).isReviewing)
    }

    @Test func reviewActivityHandlesStartupAndStoppedUnpublishedScans() {
        let session = UUID()
        #expect(ScanReviewActivity(scans: [], sessionID: session, isBusy: true).isReviewing)
        #expect(!ScanReviewActivity(scans: [], sessionID: nil, isBusy: true).isReviewing)
        let scan = CodeScan(id: UUID(), date: .now, agentSessionID: session, files: 1,
                            linesByLanguage: ["Swift": 1], markerLines: 0, skipped: 0, limited: false)
        #expect(!ScanReviewActivity(scans: [scan], sessionID: session, isBusy: false).isReviewing)
    }

    @Test func unrelatedScansCannotRestartAPublishedReviewOrHideARerunFailure() {
        let original = UUID(), other = UUID(), rerun = UUID()
        var published = CodeScan(id: UUID(), date: .now, agentSessionID: original, files: 1,
                                 linesByLanguage: ["Swift": 1], markerLines: 0, skipped: 0, limited: false)
        published.review = ScanReview(summary: "Published.", inspectedFiles: ["File.swift"], findings: [])
        let unrelated = CodeScan(id: UUID(), date: .now, agentSessionID: other, files: 1,
                                 linesByLanguage: ["Swift": 1], markerLines: 0, skipped: 0, limited: false)
        let history = [published, unrelated]
        #expect(!ScanReviewActivity(scans: history, sessionID: original, isBusy: true).isReviewing)
        #expect(ScanReviewActivity(scans: history, sessionID: other, isBusy: true).isReviewing)
        let failure = ScanReviewActivity(scans: history, sessionID: rerun, isBusy: false, lastError: "Worker could not start")
        #expect(!failure.isReviewing && failure.failure == "Worker could not start")
        let followUp = ScanReviewActivity(scans: history, sessionID: original, isBusy: false, lastError: "Unrelated follow-up failed")
        #expect(followUp.failure == nil)
    }

    @Test func rerunFailureIsVisibleEvenWhenOnlyAnOlderPublishedReportExists() {
        var published = CodeScan(id: UUID(), date: .now, agentSessionID: UUID(), files: 1,
                                 linesByLanguage: ["Swift": 1], markerLines: 0, skipped: 0, limited: false)
        published.review = ScanReview(summary: "Published.", inspectedFiles: [], findings: [])
        let status = ScanReviewActivity(scans: [published], sessionID: UUID(), isBusy: false, lastError: "Launch failed before scanning")
        #expect(status.failure == "Launch failed before scanning")
    }

    @Test func theWorkersNewestScanControlsItsOwnRerunAndIncompleteState() {
        let session = UUID()
        var published = CodeScan(id: UUID(), date: .now, agentSessionID: session, files: 1,
                                 linesByLanguage: ["Swift": 1], markerLines: 0, skipped: 0, limited: false)
        published.review = ScanReview(summary: "Published.", inspectedFiles: [], findings: [])
        var rerun = CodeScan(id: UUID(), date: .now, agentSessionID: session, files: 1,
                            linesByLanguage: ["Swift": 1], markerLines: 0, skipped: 0, limited: false)
        rerun.inventory = ScanInventory(sourceLines: 1, testLines: 0, testFiles: 0, generatedLines: 0,
                                       generatedFiles: 0, excludedFiles: 0, modules: [:], largestFiles: [], markers: [])
        #expect(ScanReviewActivity(scans: [published, rerun], sessionID: session, isBusy: true).isReviewing)
        let stopped = ScanReviewActivity(scans: [published, rerun], sessionID: session, isBusy: false)
        #expect(stopped.failure == "Inventory saved. The agent finished without publishing a code review.")
    }

    @Test func inventorySeparatesMaintainedTestsGeneratedAndDependencies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = ["internal/service.go": "package service\n// TODO handle timeout\nfunc Run() {}\n",
                        "internal/service_test.go": "package service\nfunc TestRun() {}\n",
                        "pkg/api.pb.go": "// Code generated by protoc. DO NOT EDIT.\npackage api\n",
                        "source.py": "text = \"Code generated by a test\"\n",
                        "vendor/lib.go": "package lib\n", "dist/bundle.js": "var compiled = 1;\n"]
        for (path, text) in contents {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let scan = try await CodeScan.run(at: root)
        #expect(scan.files == 3 && scan.lines == 6)
        #expect(scan.inventory?.sourceLines == 4 && scan.inventory?.testLines == 2)
        #expect(scan.inventory?.generatedFiles == 1 && scan.inventory?.excludedFiles == 2)
        #expect(scan.inventory?.largestFiles.first?.path == "internal/service.go")
        #expect(scan.inventory?.markers.first?.line == 2)
    }

    @Test func findingsRequireEvidenceAtTheCitedLocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "func run() {\n    fatalError()\n}\n".write(to: root.appendingPathComponent("File.swift"), atomically: true, encoding: .utf8)
        let finding = ScanFinding(title: "Failure terminates process", severity: .high, category: .reliability,
                                  path: "File.swift", line: 2, evidence: "fatalError()", impact: "A call exits the process.", action: "Return a handled error.")
        var report = ScanReview(summary: "The failure path terminates the process.", inspectedFiles: ["File.swift"], findings: [finding])
        try await report.validate(at: root)
        report.findings[0].line = 1
        await #expect(throws: AgentError.self) { try await report.validate(at: root) }
        report.findings[0].line = 2
        report.findings[0].evidence = "madeUpCode()"
        await #expect(throws: AgentError.self) { try await report.validate(at: root) }
    }

    @Test func olderScansStillDecodeWithoutInventoryOrReview() throws {
        let json = #"{"id":"7017A814-3A98-4E63-83D0-C8DEFB1F7B78","date":0,"files":12,"linesByLanguage":{"Go":1200},"markerLines":2,"skipped":0,"limited":false,"analysis":"Earlier summary"}"#
        let scan = try JSONDecoder().decode(CodeScan.self, from: Data(json.utf8))
        #expect(scan.inventory == nil && scan.review == nil && scan.lines == 1200)
    }
}
