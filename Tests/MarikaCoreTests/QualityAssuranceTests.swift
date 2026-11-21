import AppKit
import Foundation
import Testing
@testable import MarikaCore

struct QualityAssuranceTests {
    private var draft: String {
        #"{"cases":[{"title":"Expired code","requirement":"Reject expired discounts","preconditions":"Use an expired test code","approved":true,"steps":[{"action":"Apply the code","expected":"An error appears","status":"Passed"}]}]}"#
    }
    private func testCase() -> QACase {
        QACase(title: "Checkout", steps: [QAStep(action: "Apply an expired code", expected: "Show an error")])
    }

    @Test func aiCanOnlyPublishUnapprovedCasesToItsOwnDraft() throws {
        let owner = UUID(), id = UUID(), ticket = UUID(), element = UUID()
        var qa = QAProject()
        qa.drafts.append(QADraft(id: id, sessionID: owner, source: "Requirement", ticketID: ticket, designIDs: [element]))
        #expect(throws: QAError.self) { try qa.publishDraft(id, callerID: UUID(), json: draft) }
        #expect(qa.drafts[0].cases.isEmpty)
        try qa.publishDraft(id, callerID: owner, json: draft)
        let value = try #require(qa.drafts[0].cases.first)
        #expect(!value.approved)
        #expect(value.ticketID == ticket)
        #expect(value.designIDs == [element])
        #expect(qa.runs.isEmpty)
        #expect(qa.cases.isEmpty)
    }

    @Test func emptyExpectedResultsAndOversizedDraftsAreRejected() throws {
        var value = testCase(); value.steps[0].expected = "   "
        #expect(throws: QAError.self) { try value.validate() }
        #expect(throws: QAError.self) { try QATools.cases(from: "{\"cases\":[]}", ticketID: nil, designIDs: []) }
        #expect(throws: QAError.self) { try QATools.cases(from: String(repeating: "x", count: 200_001), ticketID: nil, designIDs: []) }
    }

    @Test func historicalRunsPreserveDefinitionsAndStartUntested() throws {
        var value = testCase(); value.approved = true
        var run = QARun(name: "Release", environment: "Local", build: "abc123", url: "http://localhost:3000", mode: .manual, cases: [value])
        value.steps[0].expected = "A different result"; value.revision += 1
        #expect(run.cases[0].testCase.steps[0].expected == "Show an error")
        #expect(run.cases[0].status == .notTested)
        run.finishedAt = Date()
        #expect(!run.isPassed)
        run.cases[0].steps[0].status = .passed
        #expect(run.isPassed)
        run.cases[0].steps[0].status = .blocked
        #expect(!run.isPassed)
    }

    @Test func replayNeedsApprovalNavigationAndAnAssertion() throws {
        var value = QACase(title: "Recorded", steps: [QAStep(action: "Open", expected: "Loaded", automation: QAAction(.navigate, value: "http://localhost:3000"))])
        value.approved = true
        #expect(!value.canReplay)
        value.steps.append(QAStep(action: "Check", expected: "Saved", automation: QAAction(.assertText, selector: "#status", value: "Saved")))
        #expect(value.canReplay)
        value.approved = false
        #expect(!value.canReplay)
        value.approved = true
        value.steps.append(QAStep(action: "Password", expected: "Entered", automation: QAAction(.manual, value: "Enter protected input manually")))
        #expect(!value.canReplay)
    }

    @Test func playwrightExportEscapesTestDataAndIncludesRealAssertions() throws {
        var value = QACase(title: "Quotes ' and `", steps: [
            QAStep(action: "Open", expected: "Loaded", automation: QAAction(.navigate, value: "http://localhost:3000")),
            QAStep(action: "Fill", expected: "Entered", automation: QAAction(.fill, selector: "input[name=code]", value: "a\"; throw new Error('injected')")),
            QAStep(action: "Check", expected: "Saved", automation: QAAction(.assertText, selector: "#status", value: "Saved"))])
        value.approved = true
        let code = try QATools.playwright(value)
        #expect(code.contains(".toContainText(\"Saved\")"))
        #expect(code.contains("a\\\"; throw new Error('injected')"))
        #expect(code.contains("page.goto"))
    }

    @Test func bugRequiresObservedFailureAndIncludesReproductionContext() throws {
        var run = QARun(name: "Checkout", environment: "Staging", build: "abc123", url: "http://localhost:3000", mode: .manual, cases: [testCase()])
        #expect(throws: QAError.self) { try QATools.bugBody(run: run, result: run.cases[0], step: 0) }
        run.cases[0].steps[0].status = .failed
        #expect(throws: QAError.self) { try QATools.bugBody(run: run, result: run.cases[0], step: 0) }
        run.cases[0].steps[0].actual = "Checkout accepted the expired code."
        let body = try QATools.bugBody(run: run, result: run.cases[0], step: 0)
        #expect(body.contains("abc123")); #expect(body.contains("Apply an expired code")); #expect(body.contains("Checkout accepted"))
    }

    @Test func qaAndBugLinksSurviveWorkspaceRoundTrip() throws {
        var project = Project(path: "/tmp/qa")
        project.qa = QAProject(); project.qa?.cases = [testCase()]
        let run = QARun(name: "Regression", environment: "Local", build: "1", url: "", mode: .manual, cases: project.qa!.cases)
        project.qa?.runs = [run]
        var workspace = Workspace(projects: [project])
        let space = try #require(workspace.spaces.first?.id)
        let created = workspace.createTicket(in: space)
        let ticket = try #require(created)
        let source = QATicketSource(projectID: project.id, runID: run.id, caseID: run.cases[0].id, stepID: run.cases[0].testCase.steps[0].id)
        workspace.updateTicket(ticket.id, in: space) { $0.qaSource = source; $0.projectID = project.id }
        let restored = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(restored.projects[0].qa == project.qa)
        #expect(restored.spaces[0].tickets[0].qaSource == source)
        #expect(QATools.report(run).contains("Not tested: 1"))
    }

    private func png(_ red: UInt8, width: Int = 2) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let pixels = try #require(bitmap.bitmapData)
        for i in stride(from: 0, to: width * 2 * 4, by: 4) { pixels[i] = red; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 255 }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func visualComparisonDetectsChangesAndRefusesToResize() throws {
        let black = try png(0), red = try png(255)
        #expect(try QAImages.compare(baseline: black, actual: black).changedFraction == 0)
        #expect(try QAImages.compare(baseline: black, actual: red).changedFraction == 1)
        let differentSize = try png(0, width: 3)
        #expect(throws: QAError.self) { try QAImages.compare(baseline: black, actual: differentSize) }
    }

    @Test func releaseCoverageRejectsUnfinishedStaleAndDifferentBuildResults() {
        var test = testCase(); test.approved = true
        var qa = QAProject(); qa.cases = [test]; qa.build = "abc"
        let snapshot = VerificationSnapshot(root: "/tmp", digest: "version-one", fileCount: 1, version: 1)
        var run = QARun(name: "Check", environment: qa.environment, build: qa.build, url: "", mode: .manual, cases: [test])
        run.snapshot = snapshot; run.cases[0].steps[0].status = .passed; qa.runs = [run]
        #expect(QAReleaseCoverage.rows(qa, currentSnapshot: snapshot)[0].result == .notTested)
        qa.runs[0].finishedAt = Date()
        #expect(QAReleaseCoverage.rows(qa, currentSnapshot: snapshot)[0].current)
        #expect(!QAReleaseCoverage.rows(qa, currentSnapshot: nil)[0].current)
        qa.cases[0].revision += 1
        #expect(QAReleaseCoverage.rows(qa, currentSnapshot: snapshot)[0].result == .notTested)
        qa.cases[0] = test; qa.build = "other-build"
        #expect(QAReleaseCoverage.rows(qa, currentSnapshot: snapshot)[0].result == .notTested)
    }

    @Test func aConfiguredVisualCheckMustRunBeforeTheCasePasses() {
        var test = testCase()
        let baseline = QAEvidence(filename: UUID().uuidString + ".png", title: "Baseline", width: 2, height: 2)
        test.baseline = baseline
        var result = QACaseResult(test)
        result.steps[0].status = .passed
        #expect(result.status == .notTested)
        #expect(result.needsVisualCheck)
        result.visual = QAVisualResult(baseline: baseline, actual: baseline, difference: nil, changedFraction: 0, allowedFraction: 0.005)
        #expect(result.status == .passed)
        result.visual?.changedFraction = 0.25
        #expect(result.status == .failed)
    }

    @Test func failedComparisonCannotReuseAnEarlierPass() {
        var test = testCase()
        let image = QAEvidence(filename: UUID().uuidString + ".png", title: "Image", width: 2, height: 2)
        test.baseline = image
        var run = QARun(name: "Visual", environment: "Local", build: "1", url: "", mode: .manual, cases: [test])
        run.cases[0].steps[0].status = .passed
        run.cases[0].visual = QAVisualResult(baseline: image, actual: image, difference: nil, changedFraction: 0, allowedFraction: 0.005)
        run.cases[0].visualError = "Viewport changed"
        run.finishedAt = Date()
        #expect(run.cases[0].status == .blocked)
        #expect(!run.isPassed)
        #expect(QATools.report(run).contains("Visual check incomplete: Viewport changed"))
    }

    @Test func interruptedReplaysAreRecoverableButManualRunsStayOpen() {
        var qa = QAProject()
        let manual = QARun(name: "Manual", environment: "Local", build: "1", url: "", mode: .manual, cases: [testCase()])
        var replay = QARun(name: "Replay", environment: "Local", build: "1", url: "", mode: .replay, cases: [testCase()])
        replay.cases[0].steps[0].status = .passed
        qa.runs = [manual, replay]
        let date = Date(timeIntervalSince1970: 123)
        let recovered = qa.recoverInterruptedReplays(at: date)
        #expect(recovered)
        #expect(qa.runs[0] == manual)
        #expect(qa.runs[1].finishedAt == date)
        #expect(qa.runs[1].cases[0].status == .blocked)
        #expect(qa.runs[1].cases[0].steps[0].actual.contains("interrupted"))
        let recoveredAgain = qa.recoverInterruptedReplays(at: date)
        #expect(!recoveredAgain)
    }

    @Test func releaseCoverageDoesNotReuseAnotherTestServer() {
        var test = testCase(); test.approved = true
        var qa = QAProject(); qa.cases = [test]; qa.url = "https://staging-b.example"
        let snapshot = VerificationSnapshot(root: "/tmp", digest: "version-one", fileCount: 1, version: 1)
        var run = QARun(name: "Check", environment: qa.environment, build: qa.build,
                        url: "https://staging-a.example", mode: .manual, cases: [test])
        run.snapshot = snapshot; run.cases[0].steps[0].status = .passed; run.finishedAt = Date()
        qa.runs = [run]
        #expect(QAReleaseCoverage.rows(qa, currentSnapshot: snapshot)[0].result == .notTested)
        qa.url = run.url
        #expect(QAReleaseCoverage.rows(qa, currentSnapshot: snapshot)[0].result == .passed)
    }
}
