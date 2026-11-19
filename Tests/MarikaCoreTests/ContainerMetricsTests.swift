import Foundation
import Testing
@testable import MarikaCore

struct ContainerMetricsTests {
    @Test func quantitiesAndDockerCPUUseExplicitUnits() throws {
        #expect(ContainerMetricDecoding.quantity("500m") == 0.5)
        #expect(ContainerMetricDecoding.quantity("100000000n") == 0.1)
        #expect(ContainerMetricDecoding.quantity("32Mi") == 33_554_432)
        #expect(ContainerMetricDecoding.quantity("2.5GiB") == 2_684_354_560)
        #expect(ContainerMetricDecoding.quantity("NaN") == nil)
        let item = ContainerResource(id: "docker:abc", name: "web", kind: .container)
        let data = Data(#"{"Name":"web","CPUPerc":"125%","MemUsage":"32MiB / 1GiB"}"#.utf8)
        let points = try ContainerMetricDecoding.docker(data, resources: [item], date: Date())
        #expect(points.first { $0.metric == .cpu }?.value == 1.25)
        #expect(points.first { $0.metric == .memory }?.value == 33_554_432)
    }
    @Test func missingContainerUsageDoesNotBecomeZero() throws {
        var pod = ContainerResource(id: "pod:1", name: "api", kind: .pod); pod.namespace = "prod"
        let data = Data(#"{"items":[{"metadata":{"name":"api","namespace":"prod"},"containers":[{"usage":{"cpu":"100m","memory":"10Mi"}},{"usage":{"cpu":"200m"}}]}]}"#.utf8)
        let points = try ContainerMetricDecoding.kubernetes(data, resources: [pod], date: Date())
        #expect(points.count == 1)
        #expect(abs(points[0].value - 0.3) < 0.000001)
    }
    @Test func historyDeduplicatesBoundsAndDiscardsInvalidSamples() {
        let now = Date(), point = ContainerMetricPoint(resourceID: "pod", metric: .cpu, date: now, value: 1)
        var history = ContainerMetricHistory()
        history.append([point, point, ContainerMetricPoint(resourceID: "pod", metric: .cpu, date: now.addingTimeInterval(-4000), value: 1), ContainerMetricPoint(resourceID: "bad", metric: .cpu, date: now, value: .nan)], now: now)
        #expect(history.points == [point])
        history.append((0..<12_010).map { ContainerMetricPoint(resourceID: String($0), metric: .cpu, date: now, value: 1) }, now: now)
        #expect(history.points.count == 12_000)
    }
    @Test func prometheusQueryIsEncodedAndHasNoImplicitAggregation() async throws {
        let end = Date(timeIntervalSince1970: 2000), start = end.addingTimeInterval(-60)
        let client = ContainerPrometheus(fetch: { request in
            #expect(request.url?.path == "/prometheus/api/v1/query_range")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
            #expect(query == #"sum(rate(errors{service="api"}[5m]))"#)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"status":"success","data":{"resultType":"matrix","result":[{"values":[[1990,"12.5"],[2000,"NaN"]]}]}}"#.utf8), response)
        })
        let result = try await client.query(ContainerLogConnection(endpoint: "https://metrics.example/prometheus"), token: nil, expression: #"sum(rate(errors{service="api"}[5m]))"#, metric: .errorRate, start: start, end: end)
        #expect(result.count == 1 && result[0].value == 12.5)
    }
}
