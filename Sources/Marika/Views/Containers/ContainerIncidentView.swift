import Charts
import MarikaCore
import SwiftUI

struct ContainerIncidentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workspace: ContainerWorkspace
    let date: Date
    @State private var incident: ContainerIncident?
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Kubernetes incident").font(.title2.bold())
            if let incident {
                Text("Review the captured logs and events for sensitive data before saving this ticket.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView { ContainerIncidentEvidenceView(incident: incident) }
            } else if error == nil {
                ProgressView("Collecting incident evidence…")
            }
            if let error { Text(error).foregroundStyle(Theme.attention).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(saving)
                Button("Create ticket") {
                    guard let incident else { return }
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            let id = try await model.saveContainerIncident(incident, projectID: workspace.projectID)
                            dismiss(); model.openTicket(id)
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(WorkspaceButtonStyle(kind: .primary)).disabled(incident == nil || saving)
            }
        }.padding(22).frame(width: 660, height: 530)
            .interactiveDismissDisabled(saving)
            .task {
                do { incident = try await workspace.captureIncident(at: date) }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
    }
}

struct ContainerIncidentEvidenceView: View {
    let incident: ContainerIncident
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text([incident.context, incident.namespace, incident.workload].joined(separator: " · ")).font(.subheadline.bold())
            Text(incident.window.lowerBound.ISO8601Format() + " – " + incident.window.upperBound.ISO8601Format())
                .font(.caption.monospaced()).textSelection(.enabled)
            ForEach(Array(incident.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if incident.metrics.isEmpty { Text("No chart samples in this window.").font(.caption) }
            ForEach(ContainerMetric.allCases, id: \.self) { metric in
                let points = incident.metrics.filter { $0.metric == metric }
                if !points.isEmpty {
                    Text(metric.title).font(.caption.bold())
                    Chart(points) { point in
                        LineMark(x: .value("Time", point.date), y: .value(metric.title, point.value))
                            .symbol(.circle).foregroundStyle(Theme.action)
                    }.chartXScale(domain: incident.window).frame(height: 90)
                }
            }
            if !incident.events.isEmpty {
                DisclosureGroup("Events (\(incident.events.count))") {
                    Text(incident.events.map { ($0.timestamp?.ISO8601Format() ?? "") + " " + $0.reason + " · " + $0.message }.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if !incident.logs.isEmpty {
                DisclosureGroup("Log lines (\(incident.logs.count))") {
                    Text(incident.logs.map { $0.timestamp.ISO8601Format() + " [" + $0.source + "] " + $0.message }.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
