import Foundation
import Testing
@testable import MarikaCore

struct APIPlaygroundTests {
    private func endpoint() throws -> APIEndpoint {
        try JSONDecoder().decode(APIEndpoint.self, from: Data(#"{"name":"List tasks","method":"GET","path":"/tasks?page=1","source":"Sources/Routes.swift","line":12}"#.utf8))
    }

    @Test func editingARequestPreservesItsSourceAndDoesNotChangeTheCollection() throws {
        let source = try endpoint()
        var draft = APIRequestDraft(endpoint: source, baseURL: "http://localhost:8080")
        draft.method = "POST"; draft.path = "/tasks"
        draft.headers = "Content-Type: application/json\nX-Trace: demo:123"
        draft.body = #"{"title":"Ship it"}"#
        let saved = try draft.endpoint(from: source)
        #expect(saved.method == "POST" && saved.path == "/tasks")
        #expect(saved.headers?["X-Trace"] == "demo:123" && saved.body == draft.body)
        #expect(saved.source == source.source && saved.line == 12)
        #expect(source.method == "GET" && source.path == "/tasks?page=1")
    }

    @Test func comparisonDestinationDoesNotMarkARequestAsUnsaved() throws {
        let saved = APIRequestDraft(endpoint: try endpoint(), baseURL: "http://localhost:8080")
        var draft = saved
        draft.comparisonBaseURL = "http://localhost:9090"
        #expect(!draft.hasRequestChanges(comparedTo: saved))
        draft.headers = "Accept: application/json"
        #expect(draft.hasRequestChanges(comparedTo: saved))
    }

    @Test func destinationIncludesTheRequestPathQueryAndProtocol() throws {
        var draft = APIRequestDraft(endpoint: try endpoint(), baseURL: "http://localhost:8080/api/")
        #expect(draft.requestURL() == "http://localhost:8080/api/tasks?page=1")
        #expect(draft.requestURL(base: "https://example.invalid/") == "https://example.invalid/tasks?page=1")
        draft.method = "GRPC"; draft.path = "demo.Tasks/List"; draft.baseURL = "grpc://localhost:9090/"
        #expect(draft.requestURL() == "grpc://localhost:9090/demo.Tasks/List")
    }

    @Test func graphQLAndRPCDraftsKeepTheirProtocolFields() throws {
        var source = try endpoint()
        source.method = "GRAPHQL"; source.path = "/graphql"; source.body = "query { tasks { id } }"
        source.variables = #"{"limit":10}"#; source.target = "https://example.invalid"
        let draft = APIRequestDraft(endpoint: source, baseURL: "http://localhost:8080")
        #expect(draft.baseURL == "https://example.invalid")
        #expect(try draft.endpoint(from: source).variables == source.variables)
        source.method = "GRPC"; source.protoFile = "api.proto"; source.importPaths = ["proto"]
        #expect(try APIRequestDraft(endpoint: source, baseURL: "grpc://localhost:9090").endpoint(from: source).protoFile == "api.proto")
    }

    @Test func responseTabsSeparateStatusHeadersAndTheCompleteBody() {
        let raw = "HTTP 200 · 23 ms\nContent-Type: application/json\nX-Trace: demo\n\n{\n  \"title\": \"Hello 🦊\"\n}\n\n"
        let preview = APIResponsePreview(output: raw)
        #expect(preview.status == "HTTP 200 · 23 ms")
        #expect(preview.headers == "Content-Type: application/json\nX-Trace: demo")
        #expect(preview.body == "{\n  \"title\": \"Hello 🦊\"\n}\n\n")
        #expect(preview.raw == raw && !preview.isFailure)
        #expect(preview.bodyBytes == preview.body.utf8.count)
    }

    @Test func failedHTTPAndRPCResponsesAreDistinctFromEmptySuccessAndCancellation() {
        #expect(APIResponsePreview(output: "HTTP 404 · 2 ms\n\nNot found").isFailure)
        #expect(APIResponsePreview(output: "gRPC Failed (1) · 4 ms\n\nUnavailable").isFailure)
        #expect(!APIResponsePreview(output: "gRPC OK · 4 ms\n\n{}").isFailure)
        #expect(APIResponsePreview(output: "HTTP 204 · 2 ms\n\n").body.isEmpty)
        let cancelled = APIResponsePreview(error: "Request cancelled", cancelled: true)
        #expect(cancelled.status == "Cancelled" && cancelled.isFailure)
        #expect(APIResponsePreview(error: "Connection refused").body == "Connection refused")
    }

    @Test func requestSearchMatchesMethodsNamesAndPathsAcrossTerms() throws {
        let source = try endpoint()
        #expect(APICollection.matches(source, query: " get TASKS "))
        #expect(APICollection.matches(source, query: "list page=1"))
        #expect(APICollection.matches(source, query: "  "))
        #expect(!APICollection.matches(source, query: "POST"))
        #expect(!APICollection.matches(source, query: "tasks missing"))
    }

    @Test func savedAndLiveRoutesAreSearchableWithoutChangingCollectionIdentity() throws {
        let source = try endpoint()
        var draft = APIRequestDraft(endpoint: source, baseURL: "https://example.invalid")
        draft.method = "POST"; draft.path = "/tasks/2026-11-08"
        let saved = try draft.savedEndpoint(from: source)
        let reopened = APIRequestItem(source: source, saved: saved)
        #expect(reopened.id == source.id && reopened.request.id != source.id)
        #expect(reopened.method == "POST" && reopened.path == draft.path)
        #expect(reopened.matches("POST 2026-11-08"))
        #expect(!reopened.matches("page=1"))
        draft.path = "/tasks/unsaved"
        #expect(APIRequestItem(source: source, saved: saved, draft: draft).matches("unsaved"))
    }

    @Test func namedParametersEncodeValuesAndSurviveSaveReopen() throws {
        var source = try endpoint(); source.path = "/fixtures/{date}/{league}?filter={filter}"
        var draft = APIRequestDraft(endpoint: source, baseURL: "http://localhost:8080")
        #expect(draft.pathParameterNames == ["date", "league"])
        #expect(draft.validationErrors.contains { $0.contains("date, league, filter") })
        draft.pathParameters = ["date": "2026-11-08", "league": "A/B 🦊"]
        draft.queryParameters = [.init(name: "filter", value: "a+b & c=1"), .init(name: "filter", value: "second")]
        #expect(draft.validationErrors.isEmpty)
        let sent = try draft.endpoint(from: source)
        #expect(sent.path == "/fixtures/2026-11-08/A%2FB%20%F0%9F%A6%8A?filter=a%2Bb%20%26%20c%3D1&filter=second")
        let saved = try JSONDecoder().decode(APIEndpoint.self, from: JSONEncoder().encode(draft.savedEndpoint(from: source)))
        let reopened = APIRequestDraft(endpoint: saved, baseURL: "http://elsewhere.invalid")
        #expect(reopened.pathParameterNames == ["date", "league"])
        #expect(reopened.resolvedPath == sent.path && reopened.queryParameters == draft.queryParameters)
    }

    @Test func requestValidationCatchesDestinationHeadersAndProtocolFields() throws {
        var draft = APIRequestDraft(endpoint: try endpoint(), baseURL: "localhost:8080")
        #expect(draft.validationErrors.contains { $0.contains("base URL") })
        draft.baseURL = "https://example.invalid"; draft.path = "//other.invalid/tasks"
        #expect(!draft.validationErrors.isEmpty)
        draft.path = "/tasks"; draft.headers = "Missing colon"
        #expect(!draft.validationErrors.isEmpty)
        draft.headers = ""; draft.queryParameters = [.init()]
        #expect(draft.validationErrors.contains { $0.contains("Name each query") })
        draft.queryParameters = []; draft.method = "GRAPHQL"; draft.body = "query { tasks { id } }"; draft.variables = "[]"
        #expect(draft.validationErrors == ["GraphQL variables must be a JSON object."])
        draft.variables = "{}"
        #expect(draft.validationErrors.isEmpty)
        draft.method = "GRPC"; draft.baseURL = "grpc://localhost:9090"; draft.path = "demo.Tasks/List"; draft.body = "{}"
        #expect(draft.validationErrors.isEmpty)
    }

    @Test func historyKeepsIndependentSnapshotsInOrderAndBoundsProjectMemory() throws {
        var draft = APIRequestDraft(endpoint: try endpoint(), baseURL: "http://localhost:8080")
        let first = APIRequestRun(endpointID: "first", request: draft, primary: APIResponsePreview(output: "HTTP 200 · 1 ms\n\n{}"))
        var history = APIRequestHistory(); history.record(first)
        draft.path = "/changed"; draft.body = "new body"
        let second = APIRequestRun(endpointID: "first", request: draft, primary: APIResponsePreview(output: "HTTP 500 · 2 ms\n\nFailed"))
        history.record(second)
        #expect(history.runs(for: "first").map(\.id) == [second.id, first.id])
        #expect(history.latest(for: "first")?.request.path == "/changed")
        #expect(history.runs.last?.request.body == "")
        for index in 0..<25 {
            history.record(APIRequestRun(endpointID: "\(index)", request: draft, primary: APIResponsePreview(output: "HTTP 200\n\n{}")))
        }
        #expect(history.runs.count == 20 && history.latest(for: "first") == nil)
        let large = APIResponsePreview(output: "HTTP 200\n\n" + String(repeating: "x", count: 3_000_000))
        for _ in 0..<3 { history.record(APIRequestRun(endpointID: "large", request: draft, primary: large)) }
        #expect(history.runs.count == 2)
    }

    @Test func jsonValidationUsesContentTypeWithoutRejectingTextOrValidJSONScalars() throws {
        var draft = APIRequestDraft(endpoint: try endpoint(), baseURL: "http://localhost:8080")
        draft.headers = "content-type: application/problem+json; charset=utf-8"
        draft.body = #"{"label":"straight quotes -- stay intact 🦊"}"#
        #expect(draft.isJSONBody && draft.bodyValidationError == nil)
        draft.body = "{“label”:”second”}"
        #expect(draft.bodyValidationError?.hasPrefix("Invalid JSON body:") == true)
        #expect(draft.validationErrors.contains { $0.hasPrefix("Invalid JSON body:") })
        draft.headers = "Content-Type: text/plain"
        #expect(!draft.isJSONBody && draft.bodyValidationError == nil)
        draft.headers = "Content-Type: APPLICATION/JSON"
        for body in ["42", "true", #""string""#, "[]", "{}", ""] {
            draft.body = body
            #expect(draft.bodyValidationError == nil)
        }
        draft.method = "GRAPHQL"; draft.body = "query { tasks { id } }"
        #expect(!draft.isJSONBody && draft.bodyValidationError == nil)
        draft.method = "GRPC"; draft.headers = ""; draft.body = "not JSON"
        #expect(draft.isJSONBody && draft.bodyValidationError != nil)
    }

    @Test func connectionFailuresAreTypedAndDoNotConfuseHTTPOrCertificateFailures() {
        for code in [URLError.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet, .timedOut] {
            #expect(APIResponsePreview(error: URLError(code)).isConnectionFailure)
        }
        #expect(!APIResponsePreview(error: URLError(.serverCertificateUntrusted)).isConnectionFailure)
        #expect(!APIResponsePreview(error: CancellationError()).isConnectionFailure)
        #expect(!APIResponsePreview(error: "Could not connect to the server.").isConnectionFailure)
        #expect(!APIResponsePreview(output: "HTTP 500\n\nServer error").isConnectionFailure)
    }

    @Test func recoveryOnlyTreatsLoopbackDestinationsAsLocal() {
        for target in ["http://localhost:8005/healthcheck", "http://127.0.0.1:80", "http://[::1]:8080", "http://app.localhost:8005"] {
            #expect(APICollection.isLocalTarget(target))
        }
        for target in ["https://localhost.example.com", "https://localhost@remote.example.com", "https://127.0.0.1.example.com", "/healthcheck"] {
            #expect(!APICollection.isLocalTarget(target))
        }
    }
}
