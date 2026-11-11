import Foundation
import MarikaCore
import Observation

@MainActor @Observable final class ContainerLogsWorkspace {
    var backend: ContainerLogBackend = .runtime
    var sourceID = ""
    var container = ""
    var since = 900
    var live = false
    var follow = true
    var search = ""
    var severity: ContainerLogSeverityFilter = .all
    var query = #"{namespace="default"}"#
    var buffer = ContainerLogBuffer()
    var isRunning = false
    var isLoading = false
    var error: String?
    var note: String?
    var selectedID: String?
    var start = Date().addingTimeInterval(-900)
    var end = Date()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var streams: [ProcessGroup] = []
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private let cli: ContainerCLI
    @ObservationIgnored let loki: ContainerLoki

    init(root: URL, environment: [String: String], cli: ContainerCLI, loki: ContainerLoki = ContainerLoki()) {
        self.root = root; self.environment = environment; self.cli = cli; self.loki = loki
    }
    var entries: [ContainerLogEntry] {
        ContainerLogFilter(text: search, severity: severity, start: start, end: end).apply(to: buffer.entries)
    }

    var selected: ContainerLogEntry? { buffer.entries.first { $0.id == selectedID } }
    func reset() { stop(); buffer.clear(); sourceID = ""; container = ""; selectedID = nil; error = nil; note = nil }
    func stop() {
        generation += 1; task?.cancel(); task = nil
        streams.forEach { $0.stop() }; streams = []; isRunning = false; isLoading = false
    }
    func runRuntime(_ resources: [ContainerResource], target: ContainerTarget) {
        stop(); buffer.clear(); error = nil; selectedID = nil
        let sources = Array(resources.prefix(8)), container = container.isEmpty ? nil : container, since = since, follow = live, token = generation
        note = resources.count > 8 ? "Showing the first 8 of \(resources.count) sources. Select a workload to narrow the stream." : nil
        guard !sources.isEmpty else { error = "Choose a running container, pod or workload with retained pods."; return }
        start = Date().addingTimeInterval(-Double(since)); end = Date(); isRunning = true; isLoading = true
        task = Task { [self] in
            if follow {
                for resource in sources {
                    do {
                        if resource.kind == .pod { try await cli.verify(resource, target: target) }
                        guard generation == token, !Task.isCancelled else { return }
                        let command = try ContainerPlans.logs(resource, target: target, container: container, since: since, follow: true)
                        let launch = try ContainerProcessLaunch(command: command, directory: root, environment: environment)
                        let name = resource.namespace.isEmpty ? resource.name : resource.namespace + "/" + resource.name
                        let stream = ProcessGroup(output: { [weak self] bytes in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.buffer.append(bytes, source: name); self.end = Date(); self.start = self.end.addingTimeInterval(-Double(since))
                            }
                        }, completion: { [weak self] status in
                            Task { @MainActor in
                                guard let self, self.generation == token else { return }
                                self.buffer.append(Data(), source: name, flush: true)
                                if status != 0 { self.error = "Log stream for \(name) ended with status \(status)." }
                                self.isRunning = self.streams.contains { $0.isRunning }
                            }
                        })
                        streams.append(stream)
                        try launch.start(stream)
                    } catch { if generation == token { self.error = error.localizedDescription } }
                }
                if generation == token { isLoading = false; isRunning = streams.contains { $0.isRunning } }
            } else {
                await withTaskGroup(of: (String, String, Bool).self) { group in
                    let cli = cli
                    for resource in sources {
                        group.addTask {
                            let name = resource.namespace.isEmpty ? resource.name : resource.namespace + "/" + resource.name
                            do {
                                if resource.kind == .pod { try await cli.verify(resource, target: target) }
                                let result = try await cli.execute(ContainerPlans.logs(resource, target: target, container: container, since: since, follow: false))
                                return (name, result.output + result.error, false)
                            } catch { return (name, error.localizedDescription, true) }
                        }
                    }
                    for await (name, text, failed) in group {
                        guard generation == token, !Task.isCancelled else { group.cancelAll(); return }
                        if failed { error = "\(name): \(text)" }
                        else { buffer.append(Data(text.utf8), source: name, flush: true) }
                    }
                }
                if generation == token { isLoading = false; isRunning = false }
            }
        }
    }
    func runLoki(_ connection: ContainerLogConnection, token credential: String?) {
        stop(); buffer.clear(); error = nil; note = "Latest 1,000 entries per query. The chart counts the loaded lines."; selectedID = nil
        let token = generation, query = query, duration = since, live = live
        start = Date().addingTimeInterval(-Double(duration)); end = Date(); isRunning = true; isLoading = true
        task = Task { [self] in
            repeat {
                do {
                    let now = Date(), start = now.addingTimeInterval(-Double(duration))
                    let result = try await loki.query(connection, token: credential, query: query, start: start, end: now)
                    guard !Task.isCancelled, generation == token else { return }
                    buffer.merge(result); self.start = start; end = now; isLoading = false
                    if result.count >= 1_000 { note = "Result limit reached. Narrow the query or time range. The chart counts loaded lines." }
                    if !live { break }
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    if generation == token, !Task.isCancelled { self.error = error.localizedDescription }
                    break
                }
            } while !Task.isCancelled
            if generation == token { isRunning = false; isLoading = false }
        }
    }
}
