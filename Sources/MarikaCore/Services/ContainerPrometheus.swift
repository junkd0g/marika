import Foundation

public actor ContainerPrometheus {
    private let http: ContainerMonitoringHTTP
    public init(fetch: ContainerLoki.Fetch? = nil) { http = ContainerMonitoringHTTP(fetch: fetch) }
    public func query(_ connection: ContainerLogConnection, token: String?, expression: String, metric: ContainerMetric, start: Date, end: Date) async throws -> [ContainerMetricPoint] {
        guard [.latency, .errorRate].contains(metric), !expression.isEmpty, expression.count <= 8_000,
              end > start, end.timeIntervalSince(start) <= 3600 else { throw ContainerHubError("Enter a metric query and a time range up to one hour.") }
        let request = try await http.request(connection, token: token, path: "api/v1/query_range", query: [
            URLQueryItem(name: "query", value: expression), URLQueryItem(name: "start", value: String(start.timeIntervalSince1970)),
            URLQueryItem(name: "end", value: String(end.timeIntervalSince1970)), URLQueryItem(name: "step", value: "15")])
        let response = try await http.perform(request)
        guard response["data"]?["resultType"]?.string == "matrix", let series = response["data"]?["result"]?.array,
              series.count <= 1 else { throw ContainerHubError("Each chart needs a query returning one series. Aggregate or filter the query in Prometheus.") }
        return (series.first?["values"]?.array ?? []).compactMap { value in
            guard let stamp = value[0]?.double, stamp.isFinite, stamp >= start.timeIntervalSince1970, stamp <= end.timeIntervalSince1970,
                  let raw = value[1]?.string, let number = Double(raw), number.isFinite, number >= 0 else { return nil }
            return ContainerMetricPoint(resourceID: "prometheus", metric: metric, date: Date(timeIntervalSince1970: stamp), value: number)
        }
    }
}
