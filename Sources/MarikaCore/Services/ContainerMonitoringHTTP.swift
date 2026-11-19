import Foundation

private final class ContainerLogRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

actor ContainerMonitoringHTTP {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let fetch: Fetch
    init(fetch: Fetch? = nil) {
        if let fetch { self.fetch = fetch }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            let session = URLSession(configuration: configuration, delegate: ContainerLogRedirects(), delegateQueue: nil)
            self.fetch = { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw ContainerHubError("Monitoring server returned an invalid response.") }
                return (data, response)
            }
        }
    }
    static func url(_ text: String) -> URL? {
        guard let value = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(value.scheme),
              value.host != nil, value.user == nil, value.password == nil, value.query == nil, value.fragment == nil else { return nil }
        return value
    }
    func request(_ connection: ContainerLogConnection, token: String?, path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let endpoint = Self.url(connection.endpoint),
              ![connection.tenant, connection.username, token ?? ""].contains(where: { $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw ContainerHubError("Enter a valid Monitoring server URL and credentials without control characters.") }
        if token?.isEmpty == false, endpoint.scheme != "https", !["localhost", "127.0.0.1", "::1"].contains(endpoint.host ?? "") {
            throw ContainerHubError("Use HTTPS for an authenticated remote Monitoring server connection.")
        }
        var parts = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            let auth = connection.username.isEmpty ? "Bearer " + token : "Basic " + Data((connection.username + ":" + token).utf8).base64EncodedString()
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if !connection.tenant.isEmpty { request.setValue(connection.tenant, forHTTPHeaderField: "X-Scope-OrgID") }
        return request
    }
    func perform(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await fetch(request)
        guard response.statusCode == 200 else {
            throw ContainerHubError(response.statusCode == 401 || response.statusCode == 403 ? "Monitoring server denied access. Check the username, token and tenant." : "Monitoring server returned HTTP \(response.statusCode). Check the endpoint and query.")
        }
        guard data.count <= 8_000_000 else { throw ContainerHubError("The monitoring response is too large. Narrow the query or time range.") }
        let result = try JSONValue(parsing: data)
        guard result["status"]?.string == "success" else { throw ContainerHubError("Monitoring server did not accept this query.") }
        return result
    }
}
