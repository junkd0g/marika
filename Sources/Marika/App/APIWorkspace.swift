import Foundation
import MarikaCore
import Observation

@MainActor @Observable final class APIWorkspace {
    var busy = false
    var log = ""
    var generating = false
    var generatingError: String?
    var selectedRequestID: String?
    var filter = ""
    var drafts: [String: APIRequestDraft] = [:]
    private(set) var savedDrafts: [String: APIRequestDraft] = [:]
    private(set) var history = APIRequestHistory()
    var selectedRunIDs: [String: UUID] = [:]
    private(set) var runningRequests: Set<String> = []
    var requestErrors: [String: String] = [:]
    @ObservationIgnored private var requestTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestTokens: [String: UUID] = [:]
    @ObservationIgnored private var runningDrafts: [String: APIRequestDraft] = [:]
    private var restoreBackups: [String: (before: APIRequestDraft, restored: APIRequestDraft)] = [:]

    typealias RequestResult = APIRequestRun

    func result(for id: String) -> RequestResult? {
        history.runs.first { $0.endpointID == id && $0.id == selectedRunIDs[id] } ?? history.latest(for: id)
    }

    private func record(_ result: RequestResult) {
        history.record(result)
        selectedRunIDs[result.endpointID] = nil
    }

    func select(_ endpoint: APIEndpoint, project: Project) {
        if drafts[endpoint.id] == nil {
            let draft = APIRequestDraft(endpoint: project.apiDrafts?[endpoint.id] ?? endpoint, baseURL: project.apiCollection?.baseURL ?? "")
            drafts[endpoint.id] = draft
            savedDrafts[endpoint.id] = draft
        }
        selectedRequestID = endpoint.id
    }

    func hasChanges(_ id: String) -> Bool {
        guard let draft = drafts[id], let saved = savedDrafts[id] else { return false }
        return draft.hasRequestChanges(comparedTo: saved)
    }

    func restore(_ run: APIRequestRun) {
        guard !runningRequests.contains(run.endpointID), let before = drafts[run.endpointID] else { return }
        restoreBackups[run.endpointID] = (before, run.request)
        drafts[run.endpointID] = run.request
        requestErrors[run.endpointID] = nil
    }

    func canUndoRestore(_ id: String) -> Bool {
        guard let backup = restoreBackups[id] else { return false }
        return drafts[id] == backup.restored
    }

    func undoRestore(_ id: String) {
        guard canUndoRestore(id), let backup = restoreBackups.removeValue(forKey: id) else { return }
        drafts[id] = backup.before
        requestErrors[id] = nil
    }

    func save(_ endpoint: APIEndpoint, project: Project, model: AppModel) {
        guard let draft = drafts[endpoint.id] else { return }
        do {
            let saved = try draft.savedEndpoint(from: endpoint)
            model.updateProject(project.id) { current in
                var requests = current.apiDrafts ?? [:]
                requests[endpoint.id] = saved
                current.apiDrafts = requests
            }
            savedDrafts[endpoint.id] = draft
            requestErrors[endpoint.id] = nil
        } catch { requestErrors[endpoint.id] = error.localizedDescription }
    }

    func send(_ endpoint: APIEndpoint, project: Project, environment: [String: String], compare: Bool = false, snapshot: APIRequestDraft? = nil) {
        let key = endpoint.id
        guard !runningRequests.contains(key), let draft = snapshot ?? drafts[key] else { return }
        var errors = draft.validationErrors
        if compare {
            var other = draft; other.baseURL = draft.comparisonBaseURL
            errors += other.validationErrors.map { "Comparison: " + $0 }
        }
        guard errors.isEmpty else { requestErrors[key] = errors.joined(separator: "\n"); return }
        let token = UUID()
        let started = Date()
        requestTokens[key] = token
        runningDrafts[key] = draft
        runningRequests.insert(key)
        requestErrors[key] = nil
        requestTasks[key] = Task { [weak self] in
            var result: RequestResult
            do {
                let request = try draft.endpoint(from: endpoint)
                let primary = try await APICollection.execute(request, base: draft.baseURL, headers: draft.headers, root: project.url, environment: environment)
                result = RequestResult(endpointID: key, request: draft, primary: APIResponsePreview(output: primary), date: started)
                if compare {
                    do {
                        let other = try await APICollection.execute(request, base: draft.comparisonBaseURL, headers: draft.headers, root: project.url, environment: environment)
                        result.comparison = APIResponsePreview(output: other)
                        result.difference = APICollection.differences(primary, other)
                    } catch { result.comparison = APIResponsePreview(error: error) }
                    result.comparisonTarget = draft.requestURL(base: draft.comparisonBaseURL)
                }
            } catch { result = RequestResult(endpointID: key, request: draft, primary: APIResponsePreview(error: error), date: started) }
            guard !Task.isCancelled, let self, requestTokens[key] == token else { return }
            record(result)
            runningRequests.remove(key)
            requestTasks[key] = nil
            requestTokens[key] = nil
            runningDrafts[key] = nil
        }
    }

    func cancel(_ id: String) {
        requestTasks.removeValue(forKey: id)?.cancel()
        requestTokens[id] = nil
        runningRequests.remove(id)
        if let draft = runningDrafts.removeValue(forKey: id) ?? drafts[id] {
            record(RequestResult(endpointID: id, request: draft, primary: APIResponsePreview(error: "The request was cancelled.", cancelled: true)))
        }
    }

    func compose(_ action: [String], project: Project, environment: [String: String]) async {
        guard !busy, let plan = project.apiCollection, !(plan.composeFiles ?? []).isEmpty else { return }
        busy = true
        defer { busy = false }
        log = "Running docker compose " + action.joined(separator: " ") + "…"
        do {
            for path in plan.composeFiles ?? [] { _ = try APICollection.projectFile(path, root: project.url) }
            guard let docker = ShellEnvironment.locate("docker", in: environment) else { throw AgentError.launchFailed("Docker CLI was not found.") }
            let args = plan.composeArguments(projectID: project.id)
            let result = try await Command.run(docker, args + action, workingDirectory: project.url,
                                               environment: environment, timeout: 900)
            log = String((result.output + result.errorOutput).suffix(16000))
            if !result.succeeded { log = "Compose failed (exit \(result.status))\n" + log }
            else if action.first == "up" {
                let status = try await Command.run(docker, args + ["ps"], workingDirectory: project.url, environment: environment)
                log = status.output + "\n" + log
            }
        } catch { log = error.localizedDescription }
    }

    func generate(_ project: Project, model: AppModel) async {
        guard !generating, let session = model.selectedSession, session.projectID == project.id else { return }
        generating = true
        generatingError = nil
        defer { generating = false }
        do {
            let prompt = """
            Generate this project's API collection for Marika. Inspect the actual application entrypoints, mounted route prefixes, handlers, schemas and tests; use OpenAPI if available. Discover HTTP, GraphQL and gRPC. For GraphQL inspect runtime schema construction, resolvers and mounted endpoint as well as SDL; publish separate named queries and mutations with valid selection sets and sample variables. For gRPC inspect .proto definitions AND registered services, transitive imports, server bindings and Compose port mappings. Publish fully qualified RPC paths, sample protobuf JSON, protoFile and project-relative importPaths; use grpc:// for plaintext or grpcs:// for TLS. Use each service's target so mixed collections support different ports. Document streaming or subscription requirements. Include path/query parameters, safe example headers and request bodies. Cite a real project-relative source path and line on every endpoint. Use {placeholders} and notes for unresolved values and authentication. Never publish secret values. Inspect README, Compose, profiles, port mappings and startup configuration. Identify the file(s) and profiles for the whole runnable app and its dependencies and its host API address. If no usable Compose definition exists, create a dedicated compose.marika.yaml only if the repository supplies enough evidence to run the app. Explain missing prerequisites. Do not start services, send requests or change application code. Call project_publish_api to populate the API tab (batches if necessary). If there are no HTTP routes, publish an empty endpoints array and explain. Report what was discovered.
            """
            let agent = try await model.launchAgent(in: project, agent: session.agent, settings: session.settings,
                prompt: prompt, parentSessionID: session.id, isolated: false)
            model.updateProject(project.id) { $0.apiAgentID = agent.id }
        } catch { generatingError = error.localizedDescription }
    }
}
