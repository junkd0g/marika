import Foundation
import MarikaCore
import Observation

/// Owns connection editing and side effects; the sheet only renders this state.
@MainActor @Observable final class ContainerLogConnectionModel {
    var connection: ContainerLogConnection
    var token = ""
    var removeToken = false
    private(set) var busy = false
    private(set) var message: String?
    private(set) var success = false
    private let workspace: ContainerWorkspace
    private let projectID: UUID
    private let settings: ContainerConnectionSettings

    init(workspace: ContainerWorkspace, projectID: UUID, settings: ContainerConnectionSettings = ContainerConnectionSettings()) {
        self.workspace = workspace; self.projectID = projectID; self.settings = settings
        connection = workspace.settings.logConnection ?? ContainerLogConnection()
    }

    func test() async {
        busy = true; defer { busy = false }
        do {
            let credential = settings.token(for: connection, projectID: projectID, replacement: token, removing: removeToken)
            let labels = try await workspace.logs.loki.labels(connection, token: credential)
            message = "Connected. Available labels: " + (labels.isEmpty ? "none in retention window" : labels.prefix(15).joined(separator: ", "))
            success = true
        } catch { message = error.localizedDescription; success = false }
    }

    func discover() async {
        guard let target = workspace.target else { return }
        busy = true; defer { busy = false }
        do {
            if let url = try await workspace.cli.grafanaCloudURL(target) {
                connection.grafanaURL = url
                message = "Found the Grafana Cloud link. Add the Loki endpoint and access token separately to query history here."; success = true
            } else {
                message = "No Grafana Cloud link found in monitoring/grafana. You can enter an existing Grafana URL above."; success = false
            }
        } catch { message = "Could not read monitoring/grafana. Enter your Grafana URL manually."; success = false }
    }

    func save() -> Bool {
        do {
            let saved = try settings.save(connection, projectID: projectID, token: token, removingToken: removeToken)
            workspace.logs.stop(); workspace.logs.buffer.clear(); workspace.logs.selectedID = nil
            workspace.settings.logConnection = saved
            return true
        } catch { message = error.localizedDescription; success = false; return false }
    }
}
