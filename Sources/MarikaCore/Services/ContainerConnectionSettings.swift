import Foundation

/// Credential access is injectable so validation and failure handling never need a real Keychain in tests.
public struct ContainerCredentialAccess: Sendable {
    public let read: @Sendable (String) -> String?
    public let write: @Sendable (String?, String) -> Bool

    public init(read: @escaping @Sendable (String) -> String?, write: @escaping @Sendable (String?, String) -> Bool) {
        self.read = read; self.write = write
    }
    public static let keychain = ContainerCredentialAccess(
        read: { Keychain.read(account: $0) },
        write: { Keychain.write($0, account: $1) })
}

public struct ContainerConnectionSettings: Sendable {
    private let credentials: ContainerCredentialAccess
    public init(credentials: ContainerCredentialAccess = .keychain) { self.credentials = credentials }

    public func token(for connection: ContainerLogConnection, projectID: UUID, replacement: String = "", removing: Bool = false) -> String? {
        removing ? nil : replacement.isEmpty ? credentials.read(connection.credentialAccount(projectID: projectID)) : replacement
    }

    /// Validates everything before touching credentials. Callers publish settings only after this succeeds.
    public func save(_ draft: ContainerLogConnection, projectID: UUID, token: String, removingToken: Bool) throws -> ContainerLogConnection {
        var connection = draft
        connection.endpoint = connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.grafanaURL = connection.grafanaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !connection.endpoint.isEmpty || token.isEmpty else { throw ContainerHubError("Enter a Loki URL before saving a token.") }
        guard connection.endpoint.isEmpty || ContainerLoki.url(connection.endpoint) != nil else { throw ContainerHubError("Enter a valid Loki base URL.") }
        if !connection.grafanaURL.isEmpty {
            guard let url = URL(string: connection.grafanaURL), ["https", "http"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil else {
                throw ContainerHubError("Enter a valid Grafana URL without embedded credentials.")
            }
        }
        if !token.isEmpty || removingToken {
            guard credentials.write(removingToken ? nil : token, connection.credentialAccount(projectID: projectID)) else {
                throw ContainerHubError("Keychain could not save this token. Connection settings were kept open.")
            }
        }
        return connection
    }
}

extension ContainerCLI {
    public func grafanaCloudURL(_ target: ContainerTarget) async throws -> String? {
        let result = try await execute(ContainerPlans.kubectl(target, namespace: "monitoring", ["get", "configmap", "grafana", "-o", "json"]))
        let values = try JSONValue(parsing: result.data)["data"]?.object?.values.compactMap(\.string).joined(separator: "\n") ?? ""
        let pattern = #"https://[a-zA-Z0-9.-]+\.grafana\.net(?:/explore)?"#
        return values.range(of: pattern, options: .regularExpression).map { String(values[$0]) }
    }
}
