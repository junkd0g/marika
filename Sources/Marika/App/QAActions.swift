import Foundation
import MarikaCore

extension AppModel {
    func qa(for project: Project) -> QAWorkspace {
        if let existing = projectRuntimeTools[project.id]?.qa { return existing }
        let workspace = QAWorkspace(project: project, model: self)
        runtimeTools(for: project.id).qa = workspace
        var recovered = workspace.data
        if recovered.recoverInterruptedReplays() { workspace.data = recovered }
        return workspace
    }

    func draftQACases(project: Project, requirement: String, ticketID: UUID?, designIDs: [UUID], agent: AgentKind) async throws {
        guard !requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QAError("Select a ticket, Design elements, or write a requirement.") }
        let qa = qa(for: project), id = UUID()
        guard qa.data.drafts.count < 20 else { throw QAError("Review or discard existing drafts before generating more.") }
        let controller = try await launchAgent(in: project, agent: agent, settings: AgentSettings(mode: .plan),
            prompt: QATools.prompt(id: id, requirement: requirement), isolated: false, name: "Draft QA cases")
        qa.data.drafts.append(QADraft(id: id, sessionID: controller.id, source: String(requirement.prefix(32_000)), ticketID: ticketID, designIDs: designIDs))
    }

    func publishQACases(_ args: JSONValue, project: Project, callerID: UUID) throws -> JSONValue {
        let qa = qa(for: project)
        guard let id = args["draftID"]?.string.flatMap(UUID.init(uuidString:)) else {
            throw QAError("Publish only to the QA draft assigned to this chat.")
        }
        try qa.data.publishDraft(id, callerID: callerID, json: args["draft"]?.string ?? "")
        return BrowserTools.text("QA draft saved. Cases require tester review and approval; no tests have been run.")
    }

    func createQABug(project: Project, runID: UUID, caseID: UUID, step: Int) async throws -> UUID {
        let qa = qa(for: project)
        guard let r = qa.data.runs.firstIndex(where: { $0.id == runID }),
              let c = qa.data.runs[r].cases.firstIndex(where: { $0.id == caseID }),
              qa.data.runs[r].cases[c].steps.indices.contains(step) else { throw QAError("This QA result is unavailable.") }
        if let existing = qa.data.runs[r].cases[c].steps[step].ticketID { return existing }
        let run = qa.data.runs[r], result = run.cases[c]
        let body = try QATools.bugBody(run: run, result: result, step: step)
        let source = QATicketSource(projectID: project.id, runID: runID, caseID: caseID, stepID: result.testCase.steps[step].id)
        return try await saveQABug(project: project, title: result.testCase.title, body: body, source: source) { id in
            guard let r = qa.data.runs.firstIndex(where: { $0.id == runID }),
                  let c = qa.data.runs[r].cases.firstIndex(where: { $0.id == caseID }) else { return }
            qa.data.runs[r].cases[c].steps[step].ticketID = id
        }
    }

    func createQAVisualBug(project: Project, runID: UUID, caseID: UUID) async throws -> UUID {
        let qa = qa(for: project)
        guard let run = qa.data.runs.first(where: { $0.id == runID }), let result = run.cases.first(where: { $0.id == caseID }),
              result.visualError == nil, let visual = result.visual, !visual.passed,
              let stepID = result.testCase.steps.last?.id else { throw QAError("No failed visual comparison is available.") }
        if let id = visual.ticketID { return id }
        let body = """
        ## Visual regression
        Case: \(result.testCase.title)
        Build: \(run.build) · \(run.environment) · \(run.platform)
        Page: \(visual.actual.url ?? run.url)
        Run: \(run.id)

        Expected: match the approved baseline within \(visual.allowedFraction * 100)% changed pixels.
        Actual: \(String(format: "%.2f", visual.changedFraction * 100))% changed pixels.
        Baseline: \(visual.baseline.filename)
        Actual image: \(visual.actual.filename)
        Difference: \(visual.difference?.filename ?? "Unavailable")

        Open the linked QA run for the images and recorded reproduction steps.
        """
        return try await saveQABug(project: project, title: "Visual: " + result.testCase.title, body: body,
            source: QATicketSource(projectID: project.id, runID: runID, caseID: caseID, stepID: stepID)) { id in
            guard let r = qa.data.runs.firstIndex(where: { $0.id == runID }),
                  let c = qa.data.runs[r].cases.firstIndex(where: { $0.id == caseID }) else { return }
            qa.data.runs[r].cases[c].visual?.ticketID = id
        }
    }

    func createQAPlaywrightBug(project: Project, runID: UUID, caseID: UUID, resultID: UUID) async throws -> UUID {
        let qa = qa(for: project)
        guard !qa.busy, let (r, c, i) = qa.playwrightIndex(runID: runID, caseID: caseID, resultID: resultID),
              let observation = qa.data.runs[r].cases[c].playwright?[i], observation.status == .failed,
              let firstStep = qa.data.runs[r].cases[c].testCase.steps.first else {
            throw QAError("Choose a failed Playwright result.")
        }
        if let id = observation.ticketID { return id }
        qa.busy = true
        defer { qa.busy = false }
        let run = qa.data.runs[r], test = run.cases[c].testCase
        let body = """
        ## Playwright failure
        Build: \(run.build) · \(run.environment)
        Browser project: \(observation.browserProject)
        Test outcome: \(observation.outcome) · \(observation.attempts) attempts

        \(observation.error.isEmpty ? "See the Playwright report for failure details." : observation.error)

        ## Reproduction
        \(test.preconditions)
        \(test.steps.enumerated().map { "\($0.offset + 1). \($0.element.action) — expected \($0.element.expected)" }.joined(separator: "\n"))

        Open the linked QA run for browser evidence and any saved trace.
        """
        return try await saveQABug(project: project, title: test.title, body: body,
            source: QATicketSource(projectID: project.id, runID: runID, caseID: caseID, stepID: firstStep.id)) { id in
            guard let (r, c, i) = qa.playwrightIndex(runID: runID, caseID: caseID, resultID: resultID) else { return }
            qa.data.runs[r].cases[c].playwright?[i].ticketID = id
        }
    }

    private func saveQABug(project: Project, title: String, body: String, source: QATicketSource, link: (UUID?) -> Void) async throws -> UUID {
        guard let spaceID = project.spaceID else { throw QAError("This project's space is unavailable.") }
        guard let ticket = editSpaceContent({ workspace -> SpaceTicket? in
            guard let ticket = workspace.createTicket(in: spaceID) else { return nil }
            workspace.updateTicket(ticket.id, in: spaceID) {
                $0.title = "QA: " + title; $0.body = body; $0.kind = .bug
                $0.projectID = project.id; $0.priority = .high
                $0.qaSource = source
            }
            return ticket
        }) else { throw QAError("This project's space is unavailable.") }
        link(ticket.id)
        guard await save() else {
            link(nil)
            editSpaceContent { workspace in
                if let i = workspace.spaces.firstIndex(where: { $0.id == spaceID }) { workspace.spaces[i].tickets.removeAll { $0.id == ticket.id } }
            }
            throw QAError("Couldn't save the bug. Your test result is kept; try again after resolving the storage error.")
        }
        return ticket.id
    }

    func openQA(_ source: QATicketSource) {
        guard let project = project(id: source.projectID) else { return }
        openProject(project, tab: .qa)
        let qa = qa(for: project); qa.section = "Runs"; qa.selectedRunID = source.runID; qa.selectedCaseID = source.caseID
    }
}
