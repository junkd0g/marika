import MarikaCore
import SwiftUI

struct ContainerMetricsConnectionView: View {
    let workspace: ContainerWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var config: ContainerMetricsConnection
    @State private var token = ""
    @State private var removeToken = false
    @State private var error: String?
    init(workspace: ContainerWorkspace) {
        self.workspace = workspace; _config = State(initialValue: workspace.settings.metricsConnection ?? ContainerMetricsConnection())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prometheus metrics").font(.title2.weight(.semibold))
            Text("Use your existing Prometheus or Grafana Cloud metrics endpoint. Queries must return one series, scoped to the service you want to monitor.").font(.callout).foregroundStyle(.secondary)
            TextField("Base URL, including any API prefix", text: $config.authentication.endpoint)
            HStack { TextField("Username (optional)", text: $config.authentication.username); TextField("Tenant (optional)", text: $config.authentication.tenant) }
            SecureField("Token (blank keeps saved token)", text: $token)
            Toggle("Remove saved token", isOn: $removeToken).toggleStyle(.checkbox)
            Text("Latency query — return milliseconds").font(.caption)
            TextEditor(text: $config.latencyQuery).font(.system(.caption, design: .monospaced)).frame(height: 60).border(Theme.hairline)
            Text("Error query — return percentage, 0–100").font(.caption)
            TextEditor(text: $config.errorQuery).font(.system(.caption, design: .monospaced)).frame(height: 60).border(Theme.hairline)
            Text("Tokens stay in Keychain. These charts show the configured query scope; selecting a resource does not rewrite PromQL.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save") { save() }.buttonStyle(WorkspaceButtonStyle(kind: .primary)) }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 620)
    }
    private func save() {
        do {
            guard config.latencyQuery.count <= 8000, config.errorQuery.count <= 8000 else { throw ContainerHubError("Limit each query to 8,000 characters.") }
            config.authentication = try ContainerConnectionSettings(service: "prometheus").save(config.authentication, projectID: workspace.projectID, token: token, removingToken: removeToken)
            workspace.metrics.reset(); workspace.settings.metricsConnection = config; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
