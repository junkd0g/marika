import Charts
import MarikaCore
import SwiftUI

struct ContainerMetricsView: View {
    @Bindable var workspace: ContainerWorkspace
    @Bindable var metrics: ContainerMetricsWorkspace
    @State private var showsConnection = false
    private var ids: Set<String> {
        guard let selected = workspace.selected else { return Set(workspace.inventory.resources.map(\.id)).union(metrics.history.points.map(\.resourceID)) }
        return Set(([selected] + workspace.relatedPods(selected)).map(\.id))
    }
    private var events: [ContainerEvent] {
        let uids = Set(workspace.inventory.resources.filter { ids.contains($0.id) }.map(\.uid))
        return workspace.inventory.events.filter { uids.contains($0.resourceUID) }.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls
                Text("Resource metrics are recorded every 15 seconds while this view is visible. Up to one hour stays in memory. Missing metrics stay blank.")
                    .font(.caption).foregroundStyle(.secondary)
                if workspace.settings.metricsConnection != nil {
                    Text("Latency and errors use the configured Prometheus query scope. The resource picker filters CPU, memory and restarts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = metrics.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if let error = metrics.queryError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(ContainerMetric.allCases, id: \.self) { chart($0) }
                }
                if let date = metrics.selectedDate {
                    HStack {
                        Text(date, format: .dateTime.hour().minute().second()).monospacedDigit()
                        Text("±2 minutes").foregroundStyle(.secondary)
                        Spacer()
                        Button("Open logs at this time") { correlate(date) }.disabled(workspace.selected == nil)
                    }.font(.callout)
                }
                Text("Deployment and resource events").font(.headline)
                if events.isEmpty { Text("No retained events for this selection.").foregroundStyle(.secondary) }
                ForEach(events.prefix(60)) { event in
                    Button { if let date = event.timestamp { metrics.selectedDate = date } } label: {
                        HStack(alignment: .top) {
                            Image(systemName: event.warning ? "exclamationmark.triangle" : "circle.fill").foregroundStyle(event.warning ? .orange : .secondary)
                            VStack(alignment: .leading) { Text(event.reason).fontWeight(.medium); Text(event.message).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); if let date = event.timestamp { Text(date, style: .time).font(.caption).monospacedDigit() }
                        }.padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }.padding(18)
        }
        .task(id: metrics.recording) {
            guard metrics.recording else { return }
            while !Task.isCancelled {
                await metrics.sample(workspace)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onDisappear { metrics.pause() }
        .sheet(isPresented: $showsConnection) { ContainerMetricsConnectionView(workspace: workspace) }
        #if DEBUG
        .background(DebugViewMarker(name: "container-metrics"))
        #endif
    }
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { resourcePicker; Spacer(minLength: 0); recordingActions }
            VStack(alignment: .leading, spacing: 12) { resourcePicker; recordingActions }
        }
    }
    private var resourcePicker: some View {
        WorkspaceSelect(title: "Resource", selection: Binding(get: { workspace.selectedID ?? "" }, set: { workspace.selectedID = $0.isEmpty ? nil : $0 }),
            options: [""] + workspace.resources.filter { $0.kind != .image }.map(\.id),
            label: { id in workspace.resources.first(where: { $0.id == id })?.name ?? "All resources" }, symbol: "shippingbox", height: 34)
            .frame(minWidth: 180, maxWidth: 300)
    }
    private var recordingActions: some View {
        HStack(spacing: 8) {
            Button(metrics.recording ? "Pause" : "Record metrics") { metrics.recording.toggle() }
                .buttonStyle(WorkspaceButtonStyle(kind: .primary, compact: true))
            Button("Sample now") { Task { await metrics.sample(workspace) } }.disabled(metrics.isLoading)
                .buttonStyle(WorkspaceButtonStyle(compact: true))
            Button("Prometheus…") { showsConnection = true }.buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
        }.fixedSize()
    }
    private func chart(_ metric: ContainerMetric) -> some View {
        let values = metrics.series(metric, ids: ids)
        return VStack(alignment: .leading, spacing: 8) {
            HStack { Text(metric.title).font(.headline); Spacer(); if let last = values.last { Text(format(last.value, metric: metric)).monospacedDigit().font(.caption) } }
            if values.isEmpty {
                Text([ContainerMetric.latency, .errorRate].contains(metric) ? "Configure a Prometheus query for this chart." : "No samples yet.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 135)
            } else {
                Chart {
                    ForEach(values) { point in
                        LineMark(x: .value("Time", point.date), y: .value(metric.title, point.value)).foregroundStyle(Theme.action)
                    }
                    if let date = metrics.selectedDate { RuleMark(x: .value("Selected", date)).foregroundStyle(.secondary) }
                }.chartXSelection(value: $metrics.selectedDate).frame(height: 135)
            }
        }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func format(_ value: Double, metric: ContainerMetric) -> String {
        metric == .memory ? ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max - 1024))), countStyle: .memory) : value.formatted(.number.precision(.fractionLength(0...2)))
    }
    private func correlate(_ date: Date) {
        guard let selected = workspace.selected, let target = workspace.target else { return }
        let pods = selected.kind == .container ? [selected] : workspace.relatedPods(selected)
        workspace.logs.sourceID = selected.id; workspace.logs.container = ""; workspace.logs.live = false
        workspace.logs.backend = .runtime
        workspace.display = .logs
        workspace.logs.runRuntime(pods, target: target, window: date.addingTimeInterval(-120)...date.addingTimeInterval(120))
    }
}
