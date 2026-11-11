import Foundation
import Testing
@testable import MarikaCore

private actor LogRequests {
    var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}

struct ContainerLogsTests {
    @Test func splitUTF8AndInterleavedSourcesProduceWholeLines() throws {
        var buffer = ContainerLogBuffer(limit: 3)
        let text = "[pod/api-one/api] 2026-11-11T12:00:00.123456789Z {\"level\":\"error\",\"msg\":\"failed 🧪\"}\n"
        let bytes = Data(text.utf8)
        buffer.append(bytes.prefix(bytes.count - 4), source: "api")
        buffer.append(Data("2026-11-11T12:00:01Z [WARN] queue full\n".utf8), source: "worker")
        buffer.append(bytes.suffix(4), source: "api")
        #expect(buffer.entries.count == 2)
        let api = try #require(buffer.entries.first { $0.source == "pod/api-one/api" })
        #expect(api.level == .error && api.message.contains("🧪") && !api.message.contains("�"))
        #expect(api.fields.contains { $0.0 == "msg" && $0.1 == "failed 🧪" })
        #expect(buffer.entries.last?.level == .warning)
        buffer.append(Data("one\ntwo\nthree\nfour\n".utf8), source: "extra")
        #expect(buffer.entries.count == 3 && buffer.dropped == 3)
    }
    @Test func partialFinalLinesAndOversizedLinesAreBounded() {
        var buffer = ContainerLogBuffer(limit: 2)
        buffer.append(Data("final without newline".utf8), source: "one")
        #expect(buffer.entries.isEmpty)
        buffer.append(Data(), source: "one", flush: true)
        #expect(buffer.entries.first?.message == "final without newline")
        buffer.append(Data((String(repeating: "x", count: 300_000)).utf8), source: "two")
        #expect(buffer.entries.count == 2 && buffer.entries.last!.message.count < 33_000)
    }
    @Test func histogramUsesOnlyLoadedLinesInsideTheRange() {
        let start = Date(timeIntervalSince1970: 100), end = start.addingTimeInterval(60)
        let lines = [ContainerLogEntry(id: "a", timestamp: start, source: "a", message: "INFO ready"),
                     ContainerLogEntry(id: "b", timestamp: end, source: "a", message: "ERROR failed"),
                     ContainerLogEntry(id: "c", timestamp: end.addingTimeInterval(1), source: "a", message: "ERROR outside"),
                     ContainerLogEntry(id: "d", timestamp: end.addingTimeInterval(0.0002), source: "a", message: "ERROR rounded timestamp")]
        let buckets = ContainerLogChart.buckets(lines, start: start, end: end, count: 3)
        #expect(buckets.count == 3 && buckets.map(\.count).reduce(0, +) == 3 && buckets.last?.errors == 2)
    }
    @Test func logCommandsKeepContextContainerAndRangeExplicit() throws {
        var pod = ContainerResource(id: "p", name: "api-one", kind: .pod); pod.namespace = "app"; pod.containers = [ContainerLogSource(name: "api")]
        let command = try ContainerPlans.logs(pod, target: ContainerTarget(name: "cluster"), container: "api", since: 900, follow: true)
        #expect(command.arguments.contains("--context") && command.arguments.contains("app") && command.arguments.contains("--since=900s") && command.arguments.contains("--follow=true"))
        #expect(throws: ContainerHubError.self) { try ContainerPlans.logs(pod, target: ContainerTarget(name: "cluster"), container: "api", since: 900, follow: true, previous: true) }
        var docker = ContainerResource(id: "d", name: "web", kind: .container); docker.uid = String(repeating: "a", count: 64)
        let tail = try ContainerPlans.logs(docker, target: ContainerTarget(name: "desktop"), container: nil, since: 3_600, follow: true)
        #expect(tail.arguments.contains("3600s") && tail.arguments.contains("--follow") && tail.arguments.last == docker.uid)
    }
    @Test func lokiQueriesEncodeLogQLAndUseConfiguredAuthentication() async throws {
        let requests = LogRequests()
        let service = ContainerLoki(fetch: { request in
            await requests.append(request)
            let text = #"{"status":"success","data":{"resultType":"streams","result":[{"stream":{"namespace":"app","pod":"api","container":"main"},"values":[["1794398400000000000","{\"level\":\"error\",\"msg\":\"request failed\"}"],["1794398400000000000","{\"level\":\"error\",\"msg\":\"request failed\"}"]]}]}}"#
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let connection = ContainerLogConnection(endpoint: "https://logs.example.test/prefix", username: "1234", tenant: "team")
        let start = Date(timeIntervalSince1970: 1_794_398_000), end = start.addingTimeInterval(1_000)
        let query = #"{namespace="app"} |= "bad & worse""#
        let lines = try await service.query(connection, token: "fixture-token", query: query, start: start, end: end)
        #expect(lines.count == 2 && Set(lines.map(\.id)).count == 2 && lines[0].level == .error)
        let request = try #require(await requests.values.first)
        let parts = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(parts.path == "/prefix/loki/api/v1/query_range" && parts.queryItems?.first { $0.name == "query" }?.value == query)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("1234:fixture-token".utf8).base64EncodedString())
        #expect(request.value(forHTTPHeaderField: "X-Scope-OrgID") == "team")
        var buffer = ContainerLogBuffer(); buffer.merge(lines); buffer.merge(lines)
        #expect(buffer.entries.count == 2)
    }
    @Test func credentialsAreNotStoredInSettingsOrLeakedThroughErrors() async throws {
        let connection = ContainerLogConnection(endpoint: "https://logs.example.test", username: "1234", grafanaURL: "https://dash.example.test")
        var settings = ContainerHubSettings(); settings.logConnection = connection
        let data = try JSONEncoder().encode(settings)
        #expect(!String(decoding: data, as: UTF8.self).contains("fixture-token"))
        let legacy = Data(#"{"provider":"Docker","dockerContext":"","kubeContext":"","namespace":"default","composeFile":"","clusters":[]}"#.utf8)
        #expect(try JSONDecoder().decode(ContainerHubSettings.self, from: legacy).logConnection == nil)
        let service = ContainerLoki(fetch: { request in (Data("fixture-token".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!) })
        do { _ = try await service.labels(connection, token: "fixture-token"); Issue.record("Expected unauthorized error") }
        catch { #expect(!error.localizedDescription.contains("fixture-token")) }
        #expect(ContainerLoki.url("https://username:password@example.test") == nil)
        await #expect(throws: ContainerHubError.self) { try await service.labels(ContainerLogConnection(endpoint: "http://remote.example.test"), token: "fixture-token") }
    }
}
