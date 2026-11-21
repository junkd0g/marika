#if DEBUG
import Foundation
import MarikaCore

@MainActor enum DebugImprovementChecks {
    static func prepareCI(_ model: AppModel, directory: URL) async throws {
        guard let project = model.selectedProject else { throw QAError("QA fixture project missing.") }
        let page = directory.appendingPathComponent("page.html")
        try "<h1>Checkout</h1>".write(to: page, atomically: true, encoding: .utf8)
        let qa = model.qa(for: project)
        let test = QACase(title: "Checkout button", steps: [
            QAStep(action: "Open checkout", expected: "The page loads", automation: QAAction(.navigate, value: page.absoluteString)),
            QAStep(action: "Check submit", expected: "Submit is visible", automation: QAAction(.assertVisible, selector: "#submit"))
        ])
        try qa.saveCase(test)
        try qa.approveCase(test.id)
        guard let approved = qa.selectedCase else { throw QAError("Approved case missing.") }
        try QATools.playwright(approved).write(to: directory.appendingPathComponent("checkout.spec.ts"), atomically: true, encoding: .utf8)
        guard await model.save() else { throw QAError("QA case did not save.") }
    }

    static func importCI(_ model: AppModel, report: URL, trace: URL) async throws {
        guard let project = model.selectedProject else { throw QAError("QA fixture project missing.") }
        let qa = model.qa(for: project)
        qa.data.build = "fixture-commit"
        try await qa.importPlaywrightReport(report)
        guard let run = qa.selectedRun, let result = run.cases.first, let observation = result.playwright?.first,
              observation.status == .failed, observation.browserProject == "chromium-fixture", observation.traceHint == "trace.zip" else {
            throw QAError("Report did not retain the Chromium failure and trace reference.")
        }
        try await qa.importPlaywrightReport(report)
        guard qa.data.runs.count == 1 else { throw QAError("The report was duplicated.") }
        try await qa.attachPlaywrightTrace(trace, runID: run.id, caseID: result.id, resultID: observation.id)
        let id = try await model.createQAPlaywrightBug(project: project, runID: run.id, caseID: result.id, resultID: observation.id)
        let saved = try await model.store.loadWorkspace()
        guard let savedRun = saved.projects.first(where: { $0.id == project.id })?.qa?.runs.first,
              let traceID = savedRun.cases.first?.playwright?.first?.traceID,
              FileManager.default.fileExists(atPath: qa.traceURL(traceID).path),
              model.ticketLocation(id)?.ticket.qaSource?.runID == run.id else {
            throw QAError("The failure, trace or ticket link did not persist.")
        }
    }

    static func incidentAndShutdown(_ model: AppModel) async throws {
        guard let project = model.selectedProject, let other = model.spaceProjects.first(where: { $0.id != project.id }) else {
            throw ContainerHubError("Two isolated projects are required.")
        }
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let podJSON = #"{"kind":"Pod","metadata":{"name":"api","namespace":"default","uid":"fixture"},"spec":{"containers":[{"name":"api","image":"api:v2"}]}}"#
        let workspace = ContainerWorkspace(project: project, environment: [:], clusterDirectory: project.url, runner: { command in
            if command.arguments.contains("logs") {
                return ContainerCommandResult(output: "\(date.ISO8601Format()) upstream unavailable\n")
            }
            return ContainerCommandResult(output: "fixture")
        })
        let pods = try ContainerDecoding.kubernetes(Data(("{\"items\":[" + podJSON + "]}").utf8))
        guard let pod = pods.first else { throw ContainerHubError("No fixture pod.") }
        workspace.settings.provider = .kubernetes
        workspace.settings.kubeContext = "fixture"
        workspace.kubeTargets = [ContainerTarget(name: "fixture")]
        workspace.inventory.resources = pods
        workspace.inventory.events = [ContainerEvent(id: "started", resourceUID: pod.uid, reason: "Started",
            message: "Deployed v2", warning: false, timestamp: date)]
        workspace.selectedID = pod.id
        workspace.metrics.history.append([ContainerMetricPoint(resourceID: pod.id, metric: .restarts, date: date, value: 3)])
        let tools = model.runtimeTools(for: project.id)
        tools.containers = workspace
        let capture = try await workspace.captureIncident(at: date)
        let ticket = try await model.saveContainerIncident(capture, projectID: project.id)
        let saved = try await model.store.loadWorkspace()
        guard capture.logs.count == 1, capture.metrics.count == 1, capture.events.count == 1,
              saved.spaces.flatMap(\.tickets).first(where: { $0.id == ticket })?.containerIncident == capture else {
            throw ContainerHubError("Evidence is incomplete or did not persist.")
        }

        model.runDebug("sleep 30", project: project)
        model.runDebug("sleep 30", project: other)
        guard let closedTask = tools.debugTask,
              let otherTask = model.projectRuntimeTools[other.id]?.debugTask else {
            throw ContainerHubError("Both project processes must be running.")
        }
        defer { otherTask.cancel() }
        model.removeProject(project)
        for _ in 0..<80 where !closedTask.isCancelled { try await Task.sleep(for: .milliseconds(50)) }
        guard closedTask.isCancelled, !otherTask.isCancelled, model.projectRuntimeTools[project.id] == nil,
              model.projectRuntimeTools[other.id]?.debugTask != nil else { throw ContainerHubError("Project shutdown was not isolated.") }
        await closedTask.value
    }
}
#endif
