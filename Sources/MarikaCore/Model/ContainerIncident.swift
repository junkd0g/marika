import Foundation

public struct ContainerIncident: Codable, Equatable, Sendable {
    public let context: String
    public let namespace: String
    public let workload: String
    public let window: ClosedRange<Date>
    public let metrics: [ContainerMetricPoint]
    public let events: [ContainerEvent]
    public let logs: [ContainerLogEntry]
    public let notes: [String]

    public init(context: String, namespace: String, workload: String, window: ClosedRange<Date>,
                metrics: [ContainerMetricPoint], events: [ContainerEvent], logs: [ContainerLogEntry], notes: [String]) {
        self.context = context
        self.namespace = namespace
        self.workload = workload
        self.window = window
        let matchingMetrics = metrics.filter { window.contains($0.date) }
        let matchingEvents = events.filter { $0.timestamp.map(window.contains) ?? false }
        let matchingLogs = logs.filter { window.contains($0.timestamp) }
        self.metrics = Array(matchingMetrics.suffix(2_000))
        self.events = matchingEvents.prefix(30).map {
            var event = $0
            event.message = String(event.message.prefix(1_000))
            return event
        }
        self.logs = matchingLogs.suffix(100).map {
            var entry = $0
            entry.message = String(entry.message.prefix(1_000))
            return entry
        }
        var details = notes
        if self.logs.count < matchingLogs.count { details.append("Saved the latest 100 matching log lines.") }
        if self.metrics.count < matchingMetrics.count { details.append("Saved the latest 2,000 matching chart samples.") }
        if self.events.count < matchingEvents.count { details.append("Saved the latest 30 matching events.") }
        self.notes = details
    }

    public var summary: String {
        """
        ## Kubernetes incident
        Context: \(context)
        Namespace: \(namespace)
        Workload: \(workload)
        Window (UTC): \(window.lowerBound.ISO8601Format()) – \(window.upperBound.ISO8601Format())

        Saved \(metrics.count) chart points, \(events.count) events and \(logs.count) log lines. Open Work → Incident evidence to review the snapshot.
        """
    }
}
