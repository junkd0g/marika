import AppKit
import MarikaCore
import SwiftUI

struct ContainerDiagnosticRequest: Identifiable {
    let id = UUID()
    let resource: ContainerResource
    let pods: [ContainerResource]
    let target: ContainerTarget
    let scope: String
}

struct ContainerDiagnosticsView: View {
    let workspace: ContainerWorkspace
    let request: ContainerDiagnosticRequest
    @Environment(\.dismiss) private var dismiss
    @State private var podID = ""
    @State private var container = ""
    @State private var previous = false
    @State private var output = ""
    @State private var loading = false
    @State private var reload = 0
    private var pod: ContainerResource? { request.pods.first { $0.id == podID } ?? request.pods.first }
    private var key: String { (pod?.id ?? "") + ":" + container + ":" + String(previous) + ":" + String(reload) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.resource.name).font(.title2.weight(.semibold))
            Text(request.target.name + " · " + request.resource.namespace).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if request.pods.isEmpty {
                ContentUnavailableView("No retained pods", systemImage: "doc.text.magnifyingglass", description: Text("The Job may not have started, or its pods may have been cleaned up. Check its events and last run status."))
            } else {
                Picker("Pod", selection: Binding(get: { pod?.id ?? "" }, set: { podID = $0; container = ""; previous = false })) {
                    ForEach(request.pods) { Text($0.name + " · " + $0.status).tag($0.id) }
                }
                HStack {
                    Picker("Container", selection: $container) {
                        Text("All containers").tag("")
                        ForEach(pod?.containers ?? [], id: \.name) { Text($0.name + ($0.isInit ? " (init)" : "")).tag($0.name) }
                    }
                    Toggle("Previous instance", isOn: $previous).toggleStyle(.checkbox)
                        .onChange(of: previous) { _, value in if value && container.isEmpty { container = pod?.containers.first(where: { $0.restarts > 0 })?.name ?? pod?.containers.first?.name ?? "" } }
                        #if DEBUG
                        .background(DebugViewMarker(name: "container-previous-logs"))
                        #endif
                }
                if let source = pod?.containers.first(where: { $0.name == container }), let exit = source.exitCode {
                    Text("Last exit: \(exit) · \(source.reason) · \(source.restarts) restarts").font(.caption).foregroundStyle(exit == 0 ? Color.secondary : .orange)
                }
                HStack { Text(previous ? "Previous container logs" : "Container logs").font(.headline); if loading { ProgressView().controlSize(.small) }; Spacer(); Button("Reload") { reload += 1 }; Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) } }
                ScrollView { Text(output.isEmpty ? "Loading logs…" : output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                let events = workspace.inventory.events.filter { $0.resourceUID == pod?.uid || $0.resourceUID == request.resource.uid }.suffix(5)
                if !events.isEmpty {
                    DisclosureGroup("Related events (\(events.count))") { ForEach(events) { Text($0.reason + ": " + $0.message).font(.caption).frame(maxWidth: .infinity, alignment: .leading) } }
                }
            }
            HStack { Text("Read-only · latest 300 lines").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 760, height: 600)
        .task(id: key) { await load() }
        #if DEBUG
        .background(DebugViewMarker(name: "container-diagnostics"))
        #endif
    }
    private func load() async {
        guard let pod else { return }
        loading = true; output = ""
        do {
            guard workspace.scope == request.scope else { throw ContainerHubError("The context changed. Reopen diagnostics.") }
            let command = try ContainerPlans.podLogs(pod, target: request.target, container: container.isEmpty ? nil : container, previous: previous)
            try await workspace.cli.verify(pod, target: request.target)
            let result = try await workspace.cli.execute(command)
            guard !Task.isCancelled else { return }
            output = result.output.isEmpty ? "No log output returned." : result.output
        } catch { if !Task.isCancelled { output = error.localizedDescription } }
        if !Task.isCancelled { loading = false }
    }
}
