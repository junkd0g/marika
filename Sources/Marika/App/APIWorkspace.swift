import Foundation
import MarikaCore
import Observation

@MainActor @Observable final class APIWorkspace {
    var busy = false
    var log = ""
    var generating = false
    var generatingError: String?

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
