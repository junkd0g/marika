import Foundation
import Testing
@testable import MarikaCore

struct ContainerIncidentTests {
    @Test func incidentRoundTripsWithOnlyEvidenceWithinWindow() throws {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let outside = time.addingTimeInterval(-121)
        let incident = ContainerIncident(context: "uat", namespace: "default", workload: "Deployment api",
            window: time.addingTimeInterval(-120)...time.addingTimeInterval(120),
            metrics: [
                ContainerMetricPoint(resourceID: "api", metric: .cpu, date: outside, value: 2),
                ContainerMetricPoint(resourceID: "api", metric: .cpu, date: time, value: 1)
            ],
            events: [ContainerEvent(id: "rollout", resourceUID: "api", reason: "Updated", message: "Release v2", warning: false, timestamp: time)],
            logs: [ContainerLogEntry(id: "retained", timestamp: time, source: "api", message: "error: upstream unavailable"),
                   ContainerLogEntry(id: "outside", timestamp: outside, source: "api", message: "Out of scope")],
            notes: [])
        var ticket = SpaceTicket(key: "OPS-1")
        ticket.containerIncident = incident
        let decoded = try JSONDecoder().decode(SpaceTicket.self, from: JSONEncoder().encode(ticket))
        #expect(decoded.containerIncident == incident)
        #expect(decoded.containerIncident?.metrics.map(\.value) == [1])
        #expect(decoded.containerIncident?.events.count == 1)
        #expect(decoded.containerIncident?.logs.map(\.id) == ["retained"])
    }
}
