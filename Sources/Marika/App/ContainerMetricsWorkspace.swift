import Foundation
import MarikaCore
import Observation

@MainActor @Observable final class ContainerMetricsWorkspace {
    var history = ContainerMetricHistory()
    var recording = false
    var isLoading = false
    var error: String?
    var queryError: String?
    var selectedDate: Date?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored let prometheus: ContainerPrometheus
    init(fetch: ContainerLoki.Fetch? = nil) { prometheus = ContainerPrometheus(fetch: fetch) }
    func reset() { generation += 1; history = ContainerMetricHistory(); isLoading = false; selectedDate = nil; error = nil; queryError = nil }
    func pause() { recording = false; generation += 1; isLoading = false }
    func sample(_ workspace: ContainerWorkspace) async {
        guard !isLoading, let target = workspace.target else { return }
        let token = generation, scope = workspace.scope
        isLoading = true
        let now = Date()
        history.append(workspace.inventory.resources.filter { $0.kind == .pod }.map {
            ContainerMetricPoint(resourceID: $0.id, metric: .restarts, date: now, value: Double($0.restarts))
        })
        defer { if token == generation { isLoading = false } }
        do {
            let points = try await workspace.cli.metricSamples(workspace.settings.provider, target: target, namespace: workspace.settings.namespace, resources: workspace.inventory.resources)
            guard !Task.isCancelled, generation == token, scope == workspace.scope else { return }
            history.append(points); error = nil
        } catch {
            if token == generation { self.error = "Resource metrics unavailable: " + error.localizedDescription + (workspace.settings.provider == .kubernetes ? " Metrics Server must already be available in this cluster." : "") }
        }
        guard !Task.isCancelled, generation == token, let config = workspace.settings.metricsConnection, !config.authentication.endpoint.isEmpty else { return }
        do {
            let credential = ContainerConnectionSettings(service: "prometheus").token(for: config.authentication, projectID: workspace.projectID)
            let end = Date(), start = end.addingTimeInterval(-900)
            var points: [ContainerMetricPoint] = []
            for (query, metric) in [(config.latencyQuery, ContainerMetric.latency), (config.errorQuery, .errorRate)] where !query.isEmpty {
                points += try await prometheus.query(config.authentication, token: credential, expression: query, metric: metric, start: start, end: end)
            }
            guard !Task.isCancelled, generation == token, scope == workspace.scope else { return }
            history.append(points); queryError = nil
        } catch { if token == generation { queryError = error.localizedDescription } }
    }
    func series(_ metric: ContainerMetric, ids: Set<String>) -> [ContainerMetricPoint] {
        let matches = history.points.filter { $0.metric == metric && (ids.contains($0.resourceID) || $0.resourceID == "prometheus") }
        return Dictionary(grouping: matches, by: \.date).map { date, values in
            ContainerMetricPoint(resourceID: "total", metric: metric, date: date, value: values.reduce(0) { $0 + $1.value })
        }.sorted { $0.date < $1.date }
    }
}
