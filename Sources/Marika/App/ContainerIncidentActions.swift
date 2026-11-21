import Foundation
import MarikaCore

extension ContainerWorkspace {
    func captureIncident(at date: Date) async throws -> ContainerIncident {
        guard settings.provider == .kubernetes, let selected, let target else {
            throw ContainerHubError("Select a Kubernetes resource and a point on its chart.")
        }
        let originalScope = scope
        let pods = relatedPods(selected), ids = Set(([selected] + pods).map(\.id))
        let uids = Set(([selected] + pods).map(\.uid))
        let window = date.addingTimeInterval(-120)...date.addingTimeInterval(120)
        let points = ContainerMetric.allCases.flatMap { metrics.series($0, ids: ids) }.sorted { $0.date < $1.date }
        let events = inventory.events.filter { uids.contains($0.resourceUID) }
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        let since = min(604_800, max(1, Int(Date().timeIntervalSince(window.lowerBound)) + 1))
        let sources = Array(pods.prefix(8))
        let results = await ContainerLogsWorkspace.runtimeSnapshot(sources, cli: cli, target: target, container: nil, since: since)
        try Task.checkCancellation()
        guard scope == originalScope, selectedID == selected.id else {
            throw ContainerHubError("The active workload changed. Select the incident time again.")
        }
        var buffer = ContainerLogBuffer()
        var notes = results.compactMap { $0.failure.map { String($0.prefix(500)) } }
        if sources.isEmpty { notes.append("No current pods were available for a runtime log lookup.") }
        if pods.count > sources.count { notes.append("Runtime logs sampled from the first \(sources.count) of \(pods.count) current pods.") }
        if settings.metricsConnection != nil { notes.append("Latency and error rate use the configured Prometheus query scope.") }
        for result in results where result.failure == nil {
            buffer.append(Data(result.output.utf8), source: result.name, flush: true)
        }
        if sources.count > 0, !buffer.entries.contains(where: { window.contains($0.timestamp) }) {
            notes.append("No retained runtime logs found in this window.")
        }
        if buffer.dropped > 0 { notes.append("The runtime log buffer reached its limit.") }
        return ContainerIncident(context: target.name, namespace: selected.namespace, workload: selected.kind.rawValue + " " + selected.name,
                                 window: window, metrics: points, events: events, logs: buffer.entries, notes: notes)
    }
}

extension AppModel {
    func saveContainerIncident(_ incident: ContainerIncident, projectID: UUID) async throws -> UUID {
        guard let spaceID = project(id: projectID)?.spaceID else { throw ContainerHubError("This project's space is unavailable.") }
        guard let ticket = editSpaceContent({ workspace -> SpaceTicket? in
            guard let ticket = workspace.createTicket(in: spaceID) else { return nil }
            workspace.updateTicket(ticket.id, in: spaceID) {
                $0.title = "Incident: " + incident.workload
                $0.body = incident.summary
                $0.projectID = projectID
                $0.priority = .high
                $0.kind = .bug
                $0.containerIncident = incident
            }
            return ticket
        }) else { throw ContainerHubError("This project's space is unavailable.") }
        guard await save() else {
            editSpaceContent { workspace in
                if let i = workspace.spaces.firstIndex(where: { $0.id == spaceID }) { workspace.spaces[i].tickets.removeAll { $0.id == ticket.id } }
            }
            throw ContainerHubError("The incident ticket couldn't be saved.")
        }
        return ticket.id
    }
}
