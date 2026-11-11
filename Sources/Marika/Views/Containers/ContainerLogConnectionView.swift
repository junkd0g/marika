import MarikaCore
import SwiftUI

struct ContainerLogConnectionView: View {
    let workspace: ContainerWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var model: ContainerLogConnectionModel

    init(workspace: ContainerWorkspace, projectID: UUID) {
        self.workspace = workspace
        _model = State(initialValue: ContainerLogConnectionModel(workspace: workspace, projectID: projectID))
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 15) {
            Text("Log connections").font(.title2.weight(.semibold))
            Text("Container logs work through your existing Docker or Kubernetes connection. Add Loki for retained history and LogQL searches.").font(.callout).foregroundStyle(.secondary)
            field("Loki base URL", "https://logs.example.com", text: $model.connection.endpoint)
            HStack { field("Username (optional)", "Grafana Cloud user ID", text: $model.connection.username); field("Tenant (optional)", "X-Scope-OrgID", text: $model.connection.tenant) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Loki token / password").font(.caption).foregroundStyle(.secondary)
                SecureField("Leave blank to keep the saved token", text: $model.token).textFieldStyle(.roundedBorder)
                Toggle("Remove saved token", isOn: $model.removeToken).toggleStyle(.checkbox).font(.caption)
            }
            Text("Tokens are stored in your macOS Keychain. A username uses Basic authentication; without one, the token uses Bearer authentication.").font(.caption).foregroundStyle(.secondary)
            Divider()
            field("Grafana URL (optional)", "https://your-stack.grafana.net/explore", text: $model.connection.grafanaURL)
            HStack {
                Button("Find Grafana link in cluster") { Task { await model.discover() } }.disabled(model.busy || workspace.target == nil || workspace.settings.provider != .kubernetes)
                Spacer()
                Button("Test Loki") { Task { await model.test() } }.disabled(model.busy || model.connection.endpoint.isEmpty)
                    #if DEBUG
                    .background(DebugViewMarker(name: "container-log-test-connection"))
                    #endif
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(model.success ? .green : .orange).textSelection(.enabled)
                    #if DEBUG
                    .background(DebugViewMarker(name: model.success ? "container-log-connected" : "container-log-connection-error"))
                    #endif
            }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save") { if model.save() { dismiss() } }.buttonStyle(WorkspaceButtonStyle(kind: .primary)).disabled(model.busy) }
        }.padding(24).frame(width: 600)
        #if DEBUG
        .background(DebugViewMarker(name: "container-log-connections"))
        #endif
    }
    private func field(_ label: String, _ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); TextField(placeholder, text: text).textFieldStyle(.roundedBorder) }
    }
}
