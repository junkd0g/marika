import MarikaCore
import SwiftUI

struct ContainerHealthView: View {
    @Bindable var workspace: ContainerWorkspace
    @State private var width: CGFloat = 900
    private var connected: [ContainerHealth] { workspace.healthSnapshots.filter { $0.error == nil }.compactMap(\.health) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cluster health").font(.title2.weight(.semibold))
                        Text("All configured Kubernetes contexts · all namespaces").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if workspace.isRefreshingHealth { ProgressView().controlSize(.small) }
                    Button("Refresh health") { Task { await workspace.refreshHealth() } }.disabled(workspace.isRefreshingHealth)
                        #if DEBUG
                        .background(DebugViewMarker(name: "containers-health-refresh"))
                        #endif
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: width > 650 ? 4 : 2), spacing: 10) {
                    metric("Unhealthy workloads", connected.reduce(0) { $0 + $1.unhealthyWorkloads }, .orange)
                    metric("Failed jobs", connected.reduce(0) { $0 + $1.failedJobs }, .red)
                    metric("Container restarts", connected.reduce(0) { $0 + $1.restarts }, .orange)
                    metric("Warning events", connected.reduce(0) { $0 + $1.warnings }, .orange)
                }
                if workspace.healthSnapshots.isEmpty {
                    ContentUnavailableView(workspace.isRefreshingHealth ? "Checking clusters…" : "No cluster snapshots", systemImage: "heart.text.square",
                        description: Text("Refresh health to check your configured contexts."))
                }
                ForEach(workspace.healthSnapshots) { snapshot in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: snapshot.error == nil ? "server.rack" : "wifi.exclamationmark").foregroundStyle(snapshot.error == nil ? Color.blue : .orange)
                            Text(snapshot.target.name).font(.headline).textSelection(.enabled)
                            Spacer()
                            Text(snapshot.checkedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                            Button("Open") {
                                workspace.changeTarget(snapshot.target.id); workspace.changeNamespace("*"); workspace.selectedID = nil; workspace.display = .list
                            }.buttonStyle(WorkspaceButtonStyle(compact: true))
                        }
                        if let error = snapshot.error {
                            Text("Unavailable · " + error).font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                        } else if let health = snapshot.health, let inventory = snapshot.inventory {
                            Text("\(health.readyWorkloads)/\(health.totalWorkloads) workloads ready or scaled down · \(health.completedJobs) completed jobs · \(health.suspendedJobs) suspended jobs")
                                .font(.caption).foregroundStyle(.secondary)
                            if let warning = inventory.warning { Text(warning).font(.caption).foregroundStyle(.orange).lineLimit(3) }
                            if health.issues.isEmpty { Label("No workload or job issues in this snapshot", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green) }
                            ForEach(health.issues.prefix(20)) { issue in
                                Button { workspace.reveal(issue.resource, target: snapshot.target) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: issue.resource.kind.symbol).foregroundStyle(issue.category == .job ? .red : .orange).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(issue.resource.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                                            Text(issue.resource.namespace + " · " + issue.category.rawValue + " · " + issue.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                                #if DEBUG
                                .background(DebugViewMarker(name: "health-issue-" + issue.resource.id))
                                #endif
                            }
                            if health.issues.count > 20 { Text("Showing 20 of \(health.issues.count) issues. Open the context to inspect all resources.").font(.caption).foregroundStyle(.secondary) }
                            let events = inventory.events.filter(\.warning).suffix(5)
                            if !events.isEmpty {
                                DisclosureGroup("Recent warning events") {
                                    ForEach(events) { event in Text(event.reason + ": " + event.message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3) }
                                }.font(.caption)
                            }
                        }
                    }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline) }
                }
            }.padding(18)
        }.background(Theme.designCanvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        #if DEBUG
        .background(DebugViewMarker(name: "containers-health"))
        #endif
    }
    private func metric(_ title: String, _ count: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(count)).font(.system(size: 28, weight: .semibold)).foregroundStyle(count == 0 ? Color.green : color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}
