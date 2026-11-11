import AppKit
import MarikaCore
import Observation

enum ContainerOperation {
    case command(ContainerCommand, ContainerResource?, ContainerTarget?)
    case create(LocalCluster), delete(LocalCluster), apply(ContainerManifestReview), recover(ContainerRecoveryReview)
}
struct ContainerOperationPrompt: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let scope: String
    let operation: ContainerOperation
}

@MainActor @Observable final class ContainerWorkspace {
    let projectID: UUID
    let root: URL
    let clusterDirectory: URL
    var settings: ContainerHubSettings { didSet { onSettings?(settings) } }
    var dockerTargets: [ContainerTarget] = []
    var kubeTargets: [ContainerTarget] = []
    var namespaces: [String] = []
    var inventory = ContainerInventory()
    var selectedID: String?
    var filter = ""
    var display: ContainerViewMode = .map
    var isLoading = false
    var isBusy = false
    var discovered = false
    var dockerError: String?
    var kubeError: String?
    var error: String?
    var operationTitle = ""
    var output = ""
    var showsOutput = false
    var review: ContainerManifestReview?
    var forward: ContainerForward?
    var healthSnapshots: [ContainerHealthSnapshot] = []
    var isRefreshingHealth = false
    @ObservationIgnored let cli: ContainerCLI
    let logs: ContainerLogsWorkspace
    @ObservationIgnored let environment: [String: String]
    @ObservationIgnored var onSettings: ((ContainerHubSettings) -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var requestedSelection: (scope: String, id: String)?

    init(project: Project, environment: [String: String], clusterDirectory: URL, runner: ContainerCLI.Runner? = nil, logFetch: ContainerLoki.Fetch? = nil) {
        projectID = project.id; root = project.url; settings = project.containerHub ?? ContainerHubSettings()
        var environment = environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        environment["PATH"] = [environment["PATH"] ?? "/usr/bin:/bin", home + "/.docker/bin", "/Applications/Docker.app/Contents/Resources/bin"].joined(separator: ":")
        self.environment = environment; self.clusterDirectory = clusterDirectory
        cli = ContainerCLI(root: root, environment: environment, runner: runner)
        logs = ContainerLogsWorkspace(root: root, environment: environment, cli: cli, loki: ContainerLoki(fetch: logFetch))
    }
    var targets: [ContainerTarget] { settings.provider == .docker ? dockerTargets : kubeTargets }
    var target: ContainerTarget? { targets.first { $0.id == (settings.provider == .docker ? settings.dockerContext : settings.kubeContext) } }
    var scope: String { settings.provider.rawValue + ":" + (target?.id ?? "") + ":" + settings.namespace }
    var selected: ContainerResource? { inventory.resources.first { $0.id == selectedID } }
    var resources: [ContainerResource] {
        inventory.resources.filter { $0.kind != .replicaSet && (filter.isEmpty || [$0.name, $0.image, $0.namespace, $0.kind.rawValue, $0.status, $0.stack].joined(separator: " ").localizedCaseInsensitiveContains(filter)) }
            .sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.kind.rawValue < $1.kind.rawValue }
    }
    var topology: ContainerTopology {
        // ReplicaSets are ownership metadata, even though they are not visible cards.
        ContainerTopology(resources: resources + inventory.resources.filter { $0.kind == .replicaSet }, provider: settings.provider)
    }
    var composeFiles: [String] {
        ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"].filter {
            (try? root.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
    var selectedCluster: LocalCluster? { settings.clusters.first { $0.id.uuidString == settings.kubeContext } }

    func discover() async {
        do { dockerTargets = try await cli.dockerContexts(); dockerError = nil }
        catch { dockerTargets = []; dockerError = error.localizedDescription }
        do { kubeTargets = try await cli.kubeContexts(); kubeError = nil }
        catch { kubeTargets = []; kubeError = error.localizedDescription }
        kubeTargets += settings.clusters.map {
            ContainerTarget(id: $0.id.uuidString, name: "kind-" + $0.name, endpoint: "Local cluster · managed by Marika", kubeconfig: $0.configuration(in: clusterDirectory).path)
        }
        if !dockerTargets.contains(where: { $0.id == settings.dockerContext }) { settings.dockerContext = (dockerTargets.first { $0.isCurrent } ?? dockerTargets.first)?.id ?? "" }
        if !kubeTargets.contains(where: { $0.id == settings.kubeContext }) { settings.kubeContext = (kubeTargets.first { $0.isCurrent } ?? kubeTargets.first)?.id ?? "" }
        if !composeFiles.contains(settings.composeFile) { settings.composeFile = composeFiles.first ?? "" }
        discovered = true
    }
    func changeProvider(_ provider: ContainerProvider) {
        guard !isBusy else { return }; forward?.stop(); forward = nil
        if provider == .docker && display == .health { display = .map }
        settings.provider = provider; changedTarget()
    }
    func changeTarget(_ id: String) {
        guard !isBusy else { return }; forward?.stop(); forward = nil
        if settings.provider == .docker { settings.dockerContext = id } else { settings.kubeContext = id }
        changedTarget()
    }
    func changeNamespace(_ namespace: String) {
        guard !isBusy else { return }; settings.namespace = namespace; changedTarget()
    }
    private func changedTarget() {
        logs.reset()
        generation += 1; inventory = ContainerInventory(); selectedID = nil; error = nil; namespaces = []
    }
    func refresh() async {
        if !discovered { await discover() }
        guard let target, !isBusy else { return }
        generation += 1; let token = generation, provider = settings.provider, namespace = settings.namespace
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            let next = try await cli.inventory(provider, target: target, namespace: namespace)
            guard !Task.isCancelled, generation == token else { return }
            inventory = next; error = nil
            if let requestedSelection, requestedSelection.scope == scope, next.resources.contains(where: { $0.id == requestedSelection.id }) {
                selectedID = requestedSelection.id; self.requestedSelection = nil
            }
            if !next.resources.contains(where: { $0.id == selectedID }) { selectedID = nil }
            if provider == .kubernetes, namespaces.isEmpty {
                let names = try? await cli.namespaces(target)
                if generation == token { namespaces = names ?? [] }
            }
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            self.error = error.localizedDescription; inventory = ContainerInventory()
        }
    }
    func refreshHealth() async {
        guard !isRefreshingHealth, settings.provider == .kubernetes else { return }
        isRefreshingHealth = true
        defer { isRefreshingHealth = false }
        if !discovered { await discover() }
        let targets = kubeTargets, cli = cli
        healthSnapshots.removeAll { item in !targets.contains(where: { $0.id == item.id }) }
        await withTaskGroup(of: ContainerHealthSnapshot.self) { group in
            var remaining = targets.makeIterator()
            for _ in 0..<min(4, targets.count) { if let target = remaining.next() { group.addTask { await cli.healthSnapshot(target) } } }
            while let snapshot = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                healthSnapshots.removeAll { $0.id == snapshot.id }; healthSnapshots.append(snapshot)
                healthSnapshots.sort { $0.target.name < $1.target.name }
                if let target = remaining.next() { group.addTask { await cli.healthSnapshot(target) } }
            }
        }
    }
    func reveal(_ resource: ContainerResource, target: ContainerTarget) {
        guard !isBusy else { return }
        changeProvider(.kubernetes); changeTarget(target.id); changeNamespace(resource.namespace)
        filter = ""; display = .list; requestedSelection = (scope, resource.id)
        Task { await refresh() }
    }
    func relatedPods(_ resource: ContainerResource) -> [ContainerResource] {
        if resource.kind == .pod { return [resource] }
        var owners: Set<String> = [resource.uid]
        for _ in 0..<4 {
            let next = inventory.resources.filter { $0.kind != .pod && owners.contains($0.ownerUID ?? "") }.map(\.uid)
            let previous = owners.count; owners.formUnion(next)
            if owners.count == previous { break }
        }
        return inventory.resources.filter { $0.kind == .pod && owners.contains($0.ownerUID ?? "") }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
    func resourcePrompt(_ action: String, resource: ContainerResource, replicas: Int? = nil) throws -> ContainerOperationPrompt {
        guard let target else { throw ContainerHubError("Choose a target.") }
        let command = try settings.provider == .docker ? ContainerPlans.dockerAction(action, resource: resource, target: target)
            : ContainerPlans.kubeAction(action, resource: resource, target: target, replicas: replicas)
        return ContainerOperationPrompt(title: action.capitalized + " " + resource.name,
            detail: target.name + (resource.namespace.isEmpty ? "" : " · namespace " + resource.namespace) + "\n\n" + command.display,
            scope: scope, operation: .command(command, settings.provider == .kubernetes ? resource : nil, target))
    }
    func submit(_ prompt: ContainerOperationPrompt) {
        guard !isBusy, prompt.scope == scope else { error = "The target changed. Review the operation again."; return }
        if case .apply(let review) = prompt.operation, review.target != target || review.namespace != settings.namespace {
            error = "The manifest target changed. Review it again."; return
        }
        if case .recover(let review) = prompt.operation, review.target != target {
            error = "The recovery target changed. Review it again."; return
        }
        isBusy = true; error = nil; operationTitle = prompt.title; output = ""
        operationTask = Task {
            var failure: String?
            do {
                let result: ContainerCommandResult
                switch prompt.operation {
                case .command(let command, let resource, let target):
                    if let resource, let target { try await cli.verify(resource, target: target) }
                    result = try await cli.execute(command)
                case .create(let cluster):
                    do { result = try await cli.createCluster(cluster, directory: clusterDirectory) }
                    catch {
                        // kind can leave a partial cluster after failing or being cancelled. Keep
                        // its record so the user can inspect or delete it from this project.
                        if FileManager.default.fileExists(atPath: cluster.configuration(in: clusterDirectory).deletingLastPathComponent().path) {
                            settings.clusters.append(cluster)
                            if !Task.isCancelled { await discover() }
                        }
                        throw error
                    }
                    settings.clusters.append(cluster); settings.provider = .kubernetes; settings.kubeContext = cluster.id.uuidString
                    await discover()
                case .delete(let cluster):
                    result = try await cli.deleteCluster(cluster, directory: clusterDirectory)
                    settings.clusters.removeAll { $0.id == cluster.id }; try? FileManager.default.removeItem(at: cluster.configuration(in: clusterDirectory).deletingLastPathComponent())
                    await discover()
                case .apply(let review): result = try await cli.apply(review)
                case .recover(let review): result = try await cli.recover(review)
                }
                output = result.output + (result.error.isEmpty ? "" : "\n" + result.error)
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = "Completed." }
            } catch is CancellationError { output = "Cancelled. Refresh to check the current state." }
            catch { failure = error.localizedDescription; output = error.localizedDescription }
            isBusy = false; operationTask = nil
            await refresh()
            if let failure { self.error = failure }
        }
    }
    func loadLogs(_ resource: ContainerResource) {
        do {
            let prompt = try resourcePrompt("logs", resource: resource)
            showsOutput = true; submit(prompt)
        } catch { self.error = error.localizedDescription }
    }
    func loadStatus(_ resource: ContainerResource) {
        do { showsOutput = true; submit(try resourcePrompt("status", resource: resource)) }
        catch { self.error = error.localizedDescription }
    }
    func previewManifest(_ path: String) {
        guard !isBusy, let target, settings.provider == .kubernetes else { return }
        let namespace = settings.namespace, token = scope
        isBusy = true; operationTitle = "Preview manifest"; error = nil
        operationTask = Task {
            do {
                let prepared = try await cli.previewManifest(path, target: target, namespace: namespace)
                if scope == token { review = prepared }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            isBusy = false; operationTask = nil
        }
    }
    func cancelOperation() { operationTask?.cancel() }
    func startForward(_ resource: ContainerResource, localPort: Int, remotePort: Int) throws {
        guard let target else { throw ContainerHubError("Choose a target.") }
        let command = try ContainerPlans.portForward(resource, target: target, localPort: localPort, remotePort: remotePort)
        let launch = try ContainerProcessLaunch(command: command, directory: root, environment: environment)
        forward?.stop()
        let next = ContainerForward(name: resource.name, port: localPort)
        try next.start(launch)
        forward = next
    }
    func stop() { generation += 1; cancelOperation(); logs.stop(); forward?.stop(); forward = nil }

    func queryLoki(_ connection: ContainerLogConnection) {
        let token = ContainerConnectionSettings().token(for: connection, projectID: projectID)
        logs.runLoki(connection, token: token)
    }
}

extension AppModel {
    func containers(for project: Project) -> ContainerWorkspace {
        if let existing = containerWorkspaces[project.id] { return existing }
        let workspace = ContainerWorkspace(project: project, environment: toolEnvironment, clusterDirectory: store.root.appendingPathComponent("local-clusters"))
        workspace.onSettings = { [weak self] settings in self?.updateProject(project.id) { $0.containerHub = settings } }
        containerWorkspaces[project.id] = workspace
        return workspace
    }
}
