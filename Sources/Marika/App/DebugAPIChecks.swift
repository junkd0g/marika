#if DEBUG
import Foundation
import MarikaCore

@MainActor enum DebugAPIChecks {
    static func requests(_ model: AppModel) async throws {
        guard let project = model.selectedProject, let endpoint = project.apiCollection?.endpoints.first,
              let api = model.apiWorkspaces[project.id], let draft = api.drafts[endpoint.id],
              let first = api.result(for: endpoint.id), first.primary.status.hasPrefix("HTTP 200 ·"),
              first.primary.body.contains("sent-by-marika") else {
            throw AgentError.launchFailed("Native Send did not reach the local server with its headers")
        }
        api.drafts[endpoint.id]?.headers = "X-Mode: first\nx-mode: second"
        api.send(endpoint, project: project, environment: model.gitEnvironment)
        guard api.runningRequests.isEmpty, api.requestErrors[endpoint.id] != nil, api.history.runs.count == 1 else {
            throw AgentError.launchFailed("Invalid headers were sent")
        }
        api.drafts[endpoint.id] = draft
        api.drafts[endpoint.id]?.path = "/error"
        api.send(endpoint, project: project, environment: model.gitEnvironment)
        try await finished(api)
        guard api.result(for: endpoint.id)?.primary.status.hasPrefix("HTTP 503 ·") == true, api.result(for: endpoint.id)?.primary.isFailure == true else {
            throw AgentError.launchFailed("HTTP failure was not retained")
        }
        api.drafts[endpoint.id]?.path = "/slow"
        api.send(endpoint, project: project, environment: model.gitEnvironment)
        try await Task.sleep(for: .milliseconds(200))
        api.cancel(endpoint.id)
        guard api.runningRequests.isEmpty, api.result(for: endpoint.id)?.primary.status == "Cancelled" else {
            throw AgentError.launchFailed("Request cancellation failed")
        }
        api.drafts[endpoint.id]?.path = "/echo?retry=1"
        api.send(endpoint, project: project, environment: model.gitEnvironment)
        try await finished(api)
        let retry = api.result(for: endpoint.id)
        guard retry?.primary.status.hasPrefix("HTTP 200 ·") == true, retry?.primary.body.contains("retry=1") == true else {
            throw AgentError.launchFailed("Retry after cancellation failed")
        }
        try await Task.sleep(for: .seconds(2.2))
        guard api.result(for: endpoint.id)?.id == retry?.id, api.history.runs.count == 4 else {
            throw AgentError.launchFailed("A cancelled request replaced the retry response")
        }
    }

    private static func finished(_ api: APIWorkspace) async throws {
        for _ in 0..<100 where !api.runningRequests.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        guard api.runningRequests.isEmpty else { throw AgentError.launchFailed("Local request timed out") }
    }

    static func lifecycle(_ model: AppModel, action: String) async throws {
        guard let project = model.selectedProject, let endpoint = project.apiCollection?.endpoints.first else {
            throw AgentError.launchFailed("API fixture missing")
        }
        let api = APIWorkspace()
        model.apiWorkspaces[project.id] = api
        api.select(endpoint, project: project)
        api.send(endpoint, project: project, environment: model.gitEnvironment)
        try await Task.sleep(for: .milliseconds(300))
        guard api.runningRequests.contains(endpoint.id) else { throw AgentError.launchFailed("Slow request did not start") }
        if action == "remove" {
            model.removeProject(project)
            for _ in 0..<100 where model.project(id: project.id) != nil { try await Task.sleep(for: .milliseconds(50)) }
            guard model.project(id: project.id) == nil, model.apiWorkspaces[project.id] == nil else {
                throw AgentError.launchFailed("Removed project retained its API workspace")
            }
        } else {
            guard await model.shutdown(saveChanges: false) else { throw AgentError.launchFailed("Shutdown failed") }
        }
        guard api.runningRequests.isEmpty, api.result(for: endpoint.id)?.primary.status == "Cancelled" else {
            throw AgentError.launchFailed("Closing the project left its API request running")
        }
        let cancellation = api.result(for: endpoint.id)?.id
        try await Task.sleep(for: .seconds(3))
        guard api.result(for: endpoint.id)?.id == cancellation, api.history.runs.count == 1 else {
            throw AgentError.launchFailed("A late response overwrote cancellation")
        }
    }
}
#endif
