import Foundation
import CryptoKit

private final class ContainerLogRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor ContainerLoki {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let fetch: Fetch
    public init(fetch: Fetch? = nil) {
        if let fetch { self.fetch = fetch }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            let session = URLSession(configuration: configuration, delegate: ContainerLogRedirects(), delegateQueue: nil)
            self.fetch = { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw ContainerHubError("Loki returned an invalid response.") }
                return (data, response)
            }
        }
    }
    public static func url(_ text: String) -> URL? {
        guard let value = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(value.scheme),
              value.host != nil, value.user == nil, value.password == nil, value.query == nil, value.fragment == nil else { return nil }
        return value
    }
    private func request(_ connection: ContainerLogConnection, token: String?, path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let endpoint = Self.url(connection.endpoint),
              ![connection.tenant, connection.username, token ?? ""].contains(where: { $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw ContainerHubError("Enter a valid Loki URL and credentials without control characters.") }
        if token?.isEmpty == false, endpoint.scheme != "https", !["localhost", "127.0.0.1", "::1"].contains(endpoint.host ?? "") {
            throw ContainerHubError("Use HTTPS for an authenticated remote Loki connection.")
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
    private func perform(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await fetch(request)
        guard response.statusCode == 200 else {
            throw ContainerHubError(response.statusCode == 401 || response.statusCode == 403 ? "Loki denied access. Check the username, token and tenant." : "Loki returned HTTP \(response.statusCode). Check the endpoint and query.")
        }
        guard data.count <= 8_000_000 else { throw ContainerHubError("The log response is too large. Narrow the query or time range.") }
        let result = try JSONValue(parsing: data)
        guard result["status"]?.string == "success" else { throw ContainerHubError("Loki did not accept this query.") }
        return result
    }
    public func labels(_ connection: ContainerLogConnection, token: String?) async throws -> [String] {
        let response = try await perform(request(connection, token: token, path: "loki/api/v1/labels"))
        return response["data"]?.array?.compactMap(\.string).sorted() ?? []
    }
    public func query(_ connection: ContainerLogConnection, token: String?, query: String, start: Date, end: Date, limit: Int = 1_000) async throws -> [ContainerLogEntry] {
        guard !query.isEmpty, query.count <= 8_000, end > start, end.timeIntervalSince(start) <= 604_800,
              start.timeIntervalSince1970 > Double(Int64.min) / 1_000_000_000, end.timeIntervalSince1970 < Double(Int64.max) / 1_000_000_000,
              (1...5_000).contains(limit) else { throw ContainerHubError("Use a log query and a time range of up to seven days.") }
        func nanos(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970 * 1_000_000_000)) }
        let response = try await perform(request(connection, token: token, path: "loki/api/v1/query_range", query: [URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "start", value: nanos(start)), URLQueryItem(name: "end", value: nanos(end)), URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "direction", value: "backward")]))
        guard response["data"]?["resultType"]?.string == "streams" else { throw ContainerHubError("Use a LogQL log-stream query, rather than a metric expression.") }
        var entries: [ContainerLogEntry] = []
        for stream in response["data"]?["result"]?.array ?? [] {
            let labels = stream["stream"]?.object?.compactMapValues(\.string) ?? [:]
            let identity = labels.keys.sorted().map { $0 + "=" + labels[$0]! }.joined(separator: ",")
            let source = [labels["namespace"] ?? labels["k8s_namespace_name"], labels["pod"] ?? labels["k8s_pod_name"], labels["container"] ?? labels["k8s_container_name"]].compactMap { $0 }.joined(separator: "/")
            var occurrences: [String: Int] = [:]
            for line in stream["values"]?.array ?? [] {
                guard let stamp = line[0]?.string, let nanoseconds = Double(stamp), nanoseconds.isFinite, let message = line[1]?.string else { continue }
                let digest = SHA256.hash(data: Data((identity + ":" + stamp + ":" + message).utf8)).map { String(format: "%02x", $0) }.joined()
                let occurrence = occurrences[digest, default: 0]; occurrences[digest] = occurrence + 1
                let id = digest + ":" + String(occurrence)
                entries.append(ContainerLogEntry(id: id, timestamp: Date(timeIntervalSince1970: nanoseconds / 1_000_000_000), source: source.isEmpty ? identity : source, message: message))
            }
        }
        return Array(entries.sorted { $0.timestamp < $1.timestamp }.suffix(limit))
    }
}
