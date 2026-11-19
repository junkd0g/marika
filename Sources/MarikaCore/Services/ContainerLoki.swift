import Foundation
import CryptoKit

public actor ContainerLoki {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let http: ContainerMonitoringHTTP
    public init(fetch: Fetch? = nil) { http = ContainerMonitoringHTTP(fetch: fetch) }
    public static func url(_ text: String) -> URL? { ContainerMonitoringHTTP.url(text) }
    public func labels(_ connection: ContainerLogConnection, token: String?) async throws -> [String] {
        let response = try await http.perform(http.request(connection, token: token, path: "loki/api/v1/labels"))
        return response["data"]?.array?.compactMap(\.string).sorted() ?? []
    }
    public func query(_ connection: ContainerLogConnection, token: String?, query: String, start: Date, end: Date, limit: Int = 1_000) async throws -> [ContainerLogEntry] {
        guard !query.isEmpty, query.count <= 8_000, end > start, end.timeIntervalSince(start) <= 604_800,
              start.timeIntervalSince1970 > Double(Int64.min) / 1_000_000_000, end.timeIntervalSince1970 < Double(Int64.max) / 1_000_000_000,
              (1...5_000).contains(limit) else { throw ContainerHubError("Use a log query and a time range of up to seven days.") }
        func nanos(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970 * 1_000_000_000)) }
        let response = try await http.perform(http.request(connection, token: token, path: "loki/api/v1/query_range", query: [URLQueryItem(name: "query", value: query),
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
