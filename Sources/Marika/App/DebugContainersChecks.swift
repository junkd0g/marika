#if DEBUG
import Foundation
import MarikaCore

private actor DebugContainerEngine {
    let root: URL
    var commands: [ContainerCommand] = []
    var stopped = false
    var ranImage = false
    init(root: URL) { self.root = root }
    func run(_ command: ContainerCommand) throws -> ContainerCommandResult {
        commands.append(command)
        let args = command.arguments
        func file(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
        if args.contains("offline") { return ContainerCommandResult(status: 1, error: "Fixture cluster is offline") }
        if command.tool == "docker" {
            if args.starts(with: ["context", "ls"]) { return try ContainerCommandResult(output: file("contexts.json")) }
            if args.contains("ps") {
                var rows = try JSONSerialization.jsonObject(with: Data(file("containers.json").utf8)) as! [[String: Any]]
                if stopped { rows[0]["State"] = "exited"; rows[0]["Status"] = "Exited (0)" }
                if ranImage { rows.append(["ID": String(repeating: "e", count: 64), "Names": "new-container", "Image": "nginx:alpine", "State": "running", "Status": "Up 1 second", "Ports": "127.0.0.1:8080->80/tcp"]) }
                return ContainerCommandResult(output: String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
            }
            if args.contains("stats") { return ContainerCommandResult(output: #"{"Name":"web","CPUPerc":"0.24%","MemUsage":"42MiB / 8GiB"}"#) }
            if args.contains("image") { return try ContainerCommandResult(output: file("images.json")) }
            if args.contains("logs") { return ContainerCommandResult(output: "2026-11-11T12:00:00Z Listening on port 80\n2026-11-11T12:00:01Z GET /health 200") }
            if args.contains("stop") { stopped = true }
            if args.contains("start") { stopped = false }
            if args.contains("run") { ranImage = true }
            return ContainerCommandResult(output: "Completed in the fixture engine.")
        }
        if args.starts(with: ["config", "get-contexts"]) { return ContainerCommandResult(output: "kind-studio\n") }
        if args.starts(with: ["config", "current-context"]) { return ContainerCommandResult(output: "kind-studio\n") }
        if let index = args.firstIndex(of: "get"), args.indices.contains(index + 1), args[index + 1] != "events", args[index + 1] != "namespaces" {
            let kind = args[index + 1]
            let doc = try JSONValue(parsing: Data(file("kubernetes.json").utf8))
            if kind == "replicasets" {
                let matches = doc["items"]?.array?.filter { $0["kind"]?.string == "ReplicaSet" } ?? []
                return ContainerCommandResult(output: String(decoding: try JSONValue.object(["items": .array(matches)]).serialized(), as: UTF8.self))
            }
            if !kind.contains(","), args.indices.contains(index + 2), let value = doc["items"]?.array?.first(where: {
                $0["kind"]?.string?.lowercased() == kind && $0["metadata"]?["name"]?.string == args[index + 2]
            }) {
                return ContainerCommandResult(output: args.contains("jsonpath={.metadata.uid}") ? value["metadata"]?["uid"]?.string ?? "" : String(decoding: try value.serialized(), as: UTF8.self))
            }
        }
        if args.contains("namespaces") { return ContainerCommandResult(output: #"{"items":[{"metadata":{"name":"default"}},{"metadata":{"name":"studio"}}]}"#) }
        if args.contains("events") { return try ContainerCommandResult(output: file("events.json")) }
        if args.contains("deployments,statefulsets,daemonsets,jobs,cronjobs,replicasets,pods,services") { return try ContainerCommandResult(output: file("kubernetes.json")) }
        if args.contains("diff") { return ContainerCommandResult(status: 1, output: "Deployment/api\n spec:\n-  replicas: 2\n+  replicas: 3\n") }
        if args.contains("logs") {
            if args.contains("--previous=true") { return ContainerCommandResult(output: "Previous instance: fixture upstream HTTP 500") }
            let now = Date().ISO8601Format()
            return ContainerCommandResult(output: "\(now) {\"level\":\"info\",\"msg\":\"Request completed\"}\n\(now) {\"level\":\"error\",\"msg\":\"upstream HTTP 500\",\"request_id\":\"demo-42\"}\n\(now) {\"level\":\"warn\",\"msg\":\"Retry scheduled\"}\n")
        }
        return ContainerCommandResult(output: "deployment.apps/api configured")
    }
    func logQuery(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        if request.url?.path.hasSuffix("/labels") == true {
            return (Data(#"{"status":"success","data":["namespace","pod","container"]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let now = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "end" })?.value ?? String(Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        let value: JSONValue = ["status": "success", "data": ["resultType": "streams", "result": [["stream": ["namespace": "studio", "pod": "api-one", "container": "api"], "values": [[.string(now), "{\"level\":\"error\",\"msg\":\"Historical upstream failure\",\"request_id\":\"demo-42\"}"]]]]]]
        return ((try? value.serialized()) ?? Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor enum DebugContainersChecks {
    private static var engine: DebugContainerEngine?
    private static var workspace: ContainerWorkspace?

    static func prepare(_ model: AppModel) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject ?? model.spaceProjects.first else {
            throw ContainerHubError("Container checks require an isolated fixture")
        }
        let engine = DebugContainerEngine(root: project.url)
        let bin = project.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("kubectl")
        let command = """
        #!/bin/sh
        trap 'exit 0' TERM INT
        case " $* " in
          *" port-forward "*) printf 'Forwarding from 127.0.0.1:8080 -> 80\\n'; while :; do /bin/sleep 1; done ;;
          *) while :; do printf '%s {"level":"error","msg":"upstream live fixture failure","request_id":"stream-42"}\\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"; /bin/sleep 0.2; done ;;
        esac
        """
        try command.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        try FileManager.default.copyItem(at: fake, to: bin.appendingPathComponent("docker"))
        let workspace = ContainerWorkspace(project: project, environment: ["PATH": bin.path + ":/usr/bin:/bin"], clusterDirectory: project.url.appendingPathComponent("clusters"), runner: { try await engine.run($0) }, logFetch: { await engine.logQuery($0) })
        workspace.onSettings = { [weak model] settings in model?.updateProject(project.id) { $0.containerHub = settings } }
        self.engine = engine; self.workspace = workspace
        model.containerWorkspaces[project.id] = workspace
        await workspace.refresh()
        guard workspace.resources.count == 7, workspace.target?.name == "desktop-linux" else { throw ContainerHubError("Fixture inventory failed") }
    }
    static func check(_ phase: String, _ model: AppModel) async throws {
        guard let workspace, let engine else { throw ContainerHubError("Container fixture missing") }
        switch phase {
        case "kubernetes":
            guard workspace.settings.provider == .kubernetes, workspace.resources.contains(where: { $0.kind == .pod }) else { throw ContainerHubError("Engine picker did not load Kubernetes") }
        case "docker":
            guard workspace.settings.provider == .docker, workspace.resources.contains(where: { $0.kind == .container }) else { throw ContainerHubError("Engine picker did not load Docker") }
        case "selected":
            guard workspace.selected?.name == "web" else { throw ContainerHubError("Map did not select the container") }
        case "logs":
            await idle(workspace)
            guard workspace.showsOutput, workspace.output.contains("Listening on port 80") else { throw ContainerHubError("Log action failed") }
        case "run":
            await idle(workspace)
            let commands = await engine.commands
            guard commands.contains(where: { $0.arguments.contains("run") && $0.arguments.contains("127.0.0.1:8080:80") }),
                  workspace.resources.contains(where: { $0.name == "new-container" }) else { throw ContainerHubError("Run form did not execute and refresh") }
        case "workflow":
            guard let web = workspace.resources.first(where: { $0.name == "web" }) else { throw ContainerHubError("Missing web fixture") }
            let stop = try workspace.resourcePrompt("stop", resource: web)
            workspace.changeTarget("remote")
            let count = await engine.commands.count
            workspace.submit(stop)
            guard !workspace.isBusy, workspace.error != nil, await engine.commands.count == count else { throw ContainerHubError("Stale context action was executed") }
            workspace.changeTarget("desktop-linux"); await workspace.refresh()
            workspace.submit(try workspace.resourcePrompt("stop", resource: web)); await idle(workspace)
            guard workspace.resources.first(where: { $0.name == "web" })?.condition == .stopped else { throw ContainerHubError("Container stop did not refresh") }
            workspace.submit(try workspace.resourcePrompt("start", resource: web)); await idle(workspace)
            workspace.changeProvider(.kubernetes); workspace.changeNamespace("studio"); await workspace.refresh()
            guard workspace.resources.count >= 7, let deployment = workspace.resources.first(where: { $0.uid == "api-deploy" }) else { throw ContainerHubError("Kubernetes inventory failed") }
            guard workspace.topology.edges.contains(where: { $0.from == "kube:api-deploy" && $0.to == "kube:api-pod-1" && !$0.isRouting }) else {
                throw ContainerHubError("Hidden ReplicaSet lost its deployment ownership")
            }
            workspace.submit(try workspace.resourcePrompt("scale", resource: deployment, replicas: 3)); await idle(workspace)
            let commands = await engine.commands
            guard commands.contains(where: { $0.arguments.contains("scale") && $0.arguments.contains("studio") && $0.arguments.contains("--current-replicas=2") }) else { throw ContainerHubError("Scale was not scoped") }
            workspace.output = ""
        case "preview":
            workspace.previewManifest("deploy.yaml"); await idle(workspace)
            guard workspace.review?.difference.contains("replicas: 3") == true else { throw ContainerHubError("Manifest preview failed") }
        case "applied":
            await idle(workspace)
            guard workspace.review == nil, await engine.commands.contains(where: { $0.arguments.contains("apply") && $0.arguments.contains("studio") }) else { throw ContainerHubError("Reviewed manifest did not apply") }
        case "forward":
            guard let service = workspace.resources.first(where: { $0.kind == .service }) else { throw ContainerHubError("Service missing") }
            try workspace.startForward(service, localPort: 8080, remotePort: 80)
            for _ in 0..<100 where workspace.forward?.ready != true { try await Task.sleep(for: .milliseconds(20)) }
            guard workspace.forward?.ready == true else { throw ContainerHubError("Forward did not report ready") }
            let forward = workspace.forward
            workspace.changeTarget("missing")
            guard forward?.running == false, workspace.forward == nil else { throw ContainerHubError("Forward survived context change") }
            workspace.changeTarget("kind-studio"); await workspace.refresh()
            guard await model.save() else { throw ContainerHubError("Container settings did not save") }
        case "health":
            workspace.kubeTargets.append(ContainerTarget(name: "offline"))
            await workspace.refreshHealth()
            guard workspace.healthSnapshots.count == 2,
                  workspace.healthSnapshots.first(where: { $0.id == "offline" })?.error != nil,
                  let health = workspace.healthSnapshots.first(where: { $0.id == "kind-studio" })?.health,
                  health.failedJobs == 1, health.completedJobs == 1, health.suspendedJobs == 1 else { throw ContainerHubError("Health classifications or offline context failed") }
        case "health-selected":
            guard workspace.selected?.uid == "job-failed", workspace.display == .list else { throw ContainerHubError("Health issue did not reveal its job") }
        case "previous-logs":
            guard await engine.commands.contains(where: { $0.arguments.contains("--previous=true") && $0.arguments.contains("worker") }) else { throw ContainerHubError("Previous container logs were not requested") }
        case "no-recovery":
            guard !(await engine.commands.contains(where: { $0.arguments.contains("create") || $0.arguments.contains("undo") })) else { throw ContainerHubError("Opening a recovery review mutated a workload") }
        case "retry-confirmed":
            await idle(workspace)
            guard await engine.commands.contains(where: { $0.arguments.contains("create") && $0.arguments.contains("studio") && $0.arguments.contains("kind-studio") }) else { throw ContainerHubError("Reviewed retry was not scoped") }
        case "select-deployment": workspace.selectedID = "kube:api-deploy"
        case "rollback-confirmed":
            await idle(workspace)
            guard await engine.commands.contains(where: { $0.arguments.contains("undo") && $0.arguments.contains("--to-revision=2") && $0.arguments.contains("kind-studio") }) else { throw ContainerHubError("Explicit revision rollback failed") }
        case "logs-prepare":
            workspace.logs.sourceID = "kube:job-failed"; workspace.logs.live = false; workspace.display = .logs
        case "logs-query":
            for _ in 0..<100 where workspace.logs.isRunning { try await Task.sleep(for: .milliseconds(20)) }
            guard workspace.logs.buffer.entries.count == 3, workspace.logs.buffer.entries.filter({ $0.level == .error }).count == 1 else { throw ContainerHubError("Log query did not parse structured lines") }
        case "logs-filter":
            guard workspace.logs.entries.count == 1, workspace.logs.buffer.entries.count == 3 else { throw ContainerHubError("Log filtering changed the underlying stream") }
        case "logs-live":
            guard workspace.logs.isRunning, workspace.logs.entries.count > 1 else { throw ContainerHubError("Live log stream did not start") }
        case "logs-stopped":
            guard !workspace.logs.isRunning else { throw ContainerHubError("Live log stream did not stop") }
            let count = workspace.logs.buffer.entries.count
            try await Task.sleep(for: .milliseconds(400))
            guard workspace.logs.buffer.entries.count == count else { throw ContainerHubError("Stopped stream kept appending data") }
        case "logs-context":
            guard let target = workspace.target, let pod = workspace.inventory.resources.first(where: { $0.uid == "job-pod" }) else { throw ContainerHubError("Log source missing") }
            workspace.logs.runRuntime([pod], target: target)
            try await Task.sleep(for: .milliseconds(150))
            workspace.changeTarget("offline")
            guard !workspace.logs.isRunning, workspace.logs.buffer.entries.isEmpty else { throw ContainerHubError("Context change did not clear and stop logs") }
            workspace.changeTarget("kind-studio"); await workspace.refresh()
        case "logs-loki":
            workspace.logs.stop(); workspace.logs.live = false; workspace.logs.search = ""
            workspace.settings.logConnection = ContainerLogConnection(endpoint: "https://loki.example.test", grafanaURL: "https://grafana.example.test/explore")
            workspace.logs.backend = .loki; workspace.logs.query = #"{namespace="studio"}"#
        case "logs-history":
            for _ in 0..<100 where workspace.logs.isRunning { try await Task.sleep(for: .milliseconds(20)) }
            guard workspace.logs.entries.count == 1, workspace.logs.entries.first?.message.contains("Historical") == true else { throw ContainerHubError("Loki history did not load: \(workspace.logs.buffer.entries.count) buffered; \(workspace.logs.entries.count) visible; \(workspace.logs.error ?? "no error")") }
        case "logs-entry": workspace.logs.selectedID = workspace.logs.entries.first(where: { $0.level == .error })?.id
        default: throw ContainerHubError("Unknown fixture phase")
        }
    }
    static func previewLogs(_ model: AppModel, name: String) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject else { throw ContainerHubError("A preview workspace is required") }
        let workspace = model.containers(for: project)
        await workspace.refresh()
        guard let resource = workspace.resources.first(where: { $0.name == name }) else { throw ContainerHubError("Preview source is unavailable") }
        workspace.logs.sourceID = resource.id; workspace.logs.since = 86_400; workspace.logs.live = false; workspace.display = .logs
    }
    private static func idle(_ workspace: ContainerWorkspace) async {
        for _ in 0..<500 where workspace.isBusy { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
#endif
