import Foundation

public actor ContainerCLI {
    public typealias Runner = @Sendable (ContainerCommand) async throws -> ContainerCommandResult
    private let root: URL
    private let environment: [String: String]
    private let runner: Runner?
    public init(root: URL, environment: [String: String], runner: Runner? = nil) { self.root = root; self.environment = environment; self.runner = runner }
    public func execute(_ command: ContainerCommand, accepting: Set<Int32> = [0]) async throws -> ContainerCommandResult {
        try Task.checkCancellation()
        let result: ContainerCommandResult
        if let runner { result = try await runner(command) }
        else {
            guard let executable = ShellEnvironment.locate(command.tool, in: environment) else { throw ContainerHubError("\(command.tool) is not installed or is not on PATH.") }
            let env = environment.merging(command.environment) { _, requested in requested }
            let output = try await Command.run(executable, command.arguments, workingDirectory: root, environment: env, timeout: command.timeout, outputLimit: 8_000_000)
            guard !output.timedOut else { throw ContainerHubError("\(command.tool) timed out. Check the connection and try again.") }
            result = ContainerCommandResult(status: output.status, output: output.output, error: output.errorOutput)
        }
        try Task.checkCancellation()
        guard accepting.contains(result.status) else { throw ContainerHubError(String((result.error.isEmpty ? result.output : result.error).suffix(12_000)).trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "\(command.tool) exited with status \(result.status).") }
        return result
    }
    public func dockerContexts() async throws -> [ContainerTarget] {
        try ContainerDecoding.dockerContexts(await execute(ContainerCommand("docker", ["context", "ls", "--format", "{{json .}}"])).data)
    }
    public func kubeContexts() async throws -> [ContainerTarget] {
        let names = try await execute(ContainerCommand("kubectl", ["config", "get-contexts", "-o", "name"]))
        let current = try? await execute(ContainerCommand("kubectl", ["config", "current-context"]))
        let selected = current?.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.output.split(whereSeparator: \.isNewline).map { ContainerTarget(name: String($0), isCurrent: String($0) == selected) }
    }
    public func namespaces(_ target: ContainerTarget) async throws -> [String] {
        let result = try await execute(ContainerPlans.kubectl(target, ["get", "namespaces", "-o", "json"]))
        return try JSONValue(parsing: result.data)["items"]?.array?.compactMap { $0["metadata"]?["name"]?.string }.sorted() ?? []
    }
    public func inventory(_ provider: ContainerProvider, target: ContainerTarget, namespace: String) async throws -> ContainerInventory {
        var result = ContainerInventory()
        if provider == .docker {
            async let containers = execute(ContainerPlans.docker(target, ["ps", "--all", "--no-trunc", "--format", "{{json .}}"]))
            async let images = execute(ContainerPlans.docker(target, ["image", "ls", "--no-trunc", "--format", "{{json .}}"] ))
            async let statistics = try? execute(ContainerPlans.docker(target, ["stats", "--no-stream", "--format", "{{json .}}"]))
            let values = try await (containers, images, statistics)
            result.resources = try ContainerDecoding.dockerContainers(values.0.data, stats: values.2?.data ?? Data()) + ContainerDecoding.dockerImages(values.1.data)
        } else {
            let all = namespace == "*"
            let ns: String? = all ? nil : namespace
            let args = ["get", "deployments,statefulsets,daemonsets,jobs,cronjobs,replicasets,pods,services"] + (all ? ["--all-namespaces"] : []) + ["-o", "json"]
            let response = try await execute(ContainerPlans.kubectl(target, namespace: ns, args), accepting: [0, 1])
            if response.status != 0 && response.output.isEmpty { throw ContainerHubError(response.error) }
            result.resources = try ContainerDecoding.kubernetes(response.data)
            if response.status != 0 { result.warning = String(response.error.prefix(2_000)) }
            do {
                let events = try await execute(ContainerPlans.kubectl(target, namespace: ns, ["get", "events"] + (all ? ["--all-namespaces"] : []) + ["-o", "json"]))
                result.events = try ContainerDecoding.events(events.data)
            } catch { result.warning = (result.warning.map { $0 + "\n" } ?? "") + "Events unavailable: " + error.localizedDescription }
        }
        return result
    }
    public func healthSnapshot(_ target: ContainerTarget) async -> ContainerHealthSnapshot {
        do { return ContainerHealthSnapshot(target: target, inventory: try await inventory(.kubernetes, target: target, namespace: "*")) }
        catch { return ContainerHealthSnapshot(target: target, error: error.localizedDescription) }
    }
    public func verify(_ resource: ContainerResource, target: ContainerTarget) async throws {
        guard resource.kind != .container, resource.kind != .image, !resource.uid.isEmpty else { return }
        let current = try await execute(ContainerPlans.kubectl(target, namespace: resource.namespace, ["get", resource.kind.kubectlName, resource.name, "-o", "jsonpath={.metadata.uid}"]))
        guard current.output.trimmingCharacters(in: .whitespacesAndNewlines) == resource.uid else { throw ContainerHubError("This resource was replaced. Refresh before changing it.") }
    }
    public func previewManifest(_ file: String, target: ContainerTarget, namespace: String) async throws -> ContainerManifestReview {
        let url = try APICollection.projectFile(file, root: root)
        let data = try await Task.detached { () throws -> Data in
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_000_000 else { throw ContainerHubError("Manifest preview is limited to 1 MB.") }
            return try Data(contentsOf: url)
        }.value
        let result = try await manifest(data, target: target, namespace: namespace, operation: "diff", accepting: [0, 1])
        return ContainerManifestReview(data: data, source: file, target: target, namespace: namespace, difference: result.output.isEmpty ? "No changes reported." : result.output)
    }
    public func apply(_ review: ContainerManifestReview) async throws -> ContainerCommandResult {
        try await manifest(review.data, target: review.target, namespace: review.namespace, operation: "apply")
    }
    private func manifest(_ data: Data, target: ContainerTarget, namespace: String, operation: String, accepting: Set<Int32> = [0]) async throws -> ContainerCommandResult {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("marika-manifest-" + UUID().uuidString + ".yaml")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await execute(ContainerPlans.kubectl(target, namespace: namespace, [operation, "-f", file.path], timeout: 90), accepting: accepting)
    }
    public func createCluster(_ cluster: LocalCluster, directory: URL) async throws -> ContainerCommandResult {
        guard ContainerPlans.name(cluster.name), cluster.name.count <= 50, ContainerPlans.value(cluster.dockerContext) else { throw ContainerHubError("Choose a lowercase cluster name, up to 50 characters.") }
        let env = ["DOCKER_CONTEXT": cluster.dockerContext, "KIND_EXPERIMENTAL_PROVIDER": "docker"]
        let existing = try await execute(ContainerCommand("kind", ["get", "clusters"], environment: env))
        guard !existing.output.split(whereSeparator: \.isNewline).contains(Substring(cluster.name)) else { throw ContainerHubError("A kind cluster with that name already exists.") }
        let configuration = cluster.configuration(in: directory)
        try FileManager.default.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = try await execute(ContainerCommand("kind", ["create", "cluster", "--name", cluster.name, "--kubeconfig", configuration.path, "--wait", "120s"], timeout: 240, environment: env))
        if FileManager.default.fileExists(atPath: configuration.path) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path) }
        return result
    }
    public func deleteCluster(_ cluster: LocalCluster, directory: URL) async throws -> ContainerCommandResult {
        guard ContainerPlans.name(cluster.name), ContainerPlans.value(cluster.dockerContext) else { throw ContainerHubError("Invalid cluster.") }
        return try await execute(ContainerCommand("kind", ["delete", "cluster", "--name", cluster.name, "--kubeconfig", cluster.configuration(in: directory).path], timeout: 120,
                                                environment: ["DOCKER_CONTEXT": cluster.dockerContext, "KIND_EXPERIMENTAL_PROVIDER": "docker"]))
    }
}

private extension String { var nonempty: String? { isEmpty ? nil : self } }
