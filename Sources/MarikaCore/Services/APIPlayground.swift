import Foundation

/// Editable values stay keyed by the collection endpoint, even if its method or path changes.
public struct APIRequestDraft: Equatable, Sendable {
    public var method: String
    public var path: String
    public var baseURL: String
    public var headers: String
    public var body: String
    public var variables: String
    public var pathParameters: [String: String]
    public var comparisonBaseURL = ""

    public init(endpoint: APIEndpoint, baseURL: String) {
        method = endpoint.method
        path = endpoint.path
        self.baseURL = endpoint.target ?? baseURL
        headers = (endpoint.headers ?? [:]).sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator: "\n")
        body = endpoint.body ?? ""
        variables = endpoint.variables ?? "{}"
        pathParameters = endpoint.pathParameters ?? [:]
    }

    public func endpoint(from source: APIEndpoint) throws -> APIEndpoint {
        var result = source
        result.method = method; result.path = resolvedPath; result.target = baseURL
        result.pathParameters = pathParameters.isEmpty ? nil : pathParameters
        result.headers = try APICollection.parseHeaders(headers)
        result.body = body
        if method == "GRAPHQL" { result.variables = variables }
        return result
    }

    public func savedEndpoint(from source: APIEndpoint) throws -> APIEndpoint {
        var result = try endpoint(from: source)
        result.path = path
        return result
    }

    public var pathParameterNames: [String] { Self.placeholders(in: path.components(separatedBy: "?")[0]) }
    public var resolvedPath: String {
        var result = path
        for name in pathParameterNames {
            if let value = pathParameters[name], !value.isEmpty {
                let encoded = value.addingPercentEncoding(withAllowedCharacters: Self.parameterCharacters) ?? value
                result = result.replacingOccurrences(of: "{" + name + "}", with: encoded)
            }
        }
        return result
    }

    public struct QueryParameter: Equatable, Sendable {
        public var name: String
        public var value: String
        public init(name: String = "", value: String = "") { self.name = name; self.value = value }
    }

    public var queryParameters: [QueryParameter] {
        get {
            let query = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first ?? ""
            return query.split(separator: "&").map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return QueryParameter(name: String(parts[0]).removingPercentEncoding ?? String(parts[0]),
                                      value: parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : "")
            }
        }
        set {
            let query = newValue.map {
                ($0.name.addingPercentEncoding(withAllowedCharacters: Self.parameterCharacters) ?? $0.name) + "=" +
                ($0.value.addingPercentEncoding(withAllowedCharacters: Self.parameterCharacters) ?? $0.value)
            }.joined(separator: "&")
            path = path.components(separatedBy: "?")[0] + (query.isEmpty ? "" : "?" + query)
        }
    }

    public var validationErrors: [String] {
        var errors: [String] = []
        let schemes = method == "GRPC" ? ["grpc", "grpcs", "http", "https"] : ["http", "https"]
        if let url = URLComponents(string: baseURL), schemes.contains(url.scheme ?? ""), let host = url.host, !host.isEmpty {
            if method == "GRPC", !url.path.isEmpty && url.path != "/" { errors.append("Use a gRPC address without a path.") }
        } else { errors.append("Enter a valid " + (method == "GRPC" ? "gRPC address." : "HTTP base URL.")) }
        let missing = Self.placeholders(in: resolvedPath)
        if !missing.isEmpty { errors.append("Enter values for " + missing.joined(separator: ", ") + ".") }
        if queryParameters.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            errors.append("Name each query parameter or remove its row.")
        }
        if method == "GRPC" {
            if !APICollection.validRPC(resolvedPath) { errors.append("Use package.Service/Method for the RPC path.") }
        } else if !resolvedPath.hasPrefix("/") || resolvedPath.hasPrefix("//") || resolvedPath.contains("{") || resolvedPath.contains("}") {
            if missing.isEmpty { errors.append("Enter a relative request path beginning with /.") }
        }
        do { _ = try APICollection.parseHeaders(headers) } catch { errors.append(error.localizedDescription) }
        if let error = bodyValidationError { errors.append(error) }
        if method == "GRAPHQL" {
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("Enter a GraphQL operation.") }
            let json = variables.trimmingCharacters(in: .whitespacesAndNewlines)
            if (try? JSONSerialization.jsonObject(with: Data((json.isEmpty ? "{}" : json).utf8))) as? [String: Any] == nil {
                errors.append("GraphQL variables must be a JSON object.")
            }
        }
        return errors
    }

    public var isJSONBody: Bool {
        if method == "GRPC" { return true }
        guard method != "GRAPHQL", let fields = try? APICollection.parseHeaders(headers),
              let type = fields.first(where: { $0.key.lowercased() == "content-type" })?.value
                .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return type == "application/json" || type.hasSuffix("+json")
    }

    public var bodyValidationError: String? {
        guard isJSONBody, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])
            return nil
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            return "Invalid JSON body: " + String(detail.prefix(240))
        }
    }

    private static let parameterCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    private static func placeholders(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#) else { return [] }
        let value = text as NSString
        var names: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: value.length)) {
            let name = value.substring(with: match.range(at: 1))
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    public func requestURL(base: String? = nil) -> String {
        (base ?? baseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (method == "GRPC" ? "/" : "") + resolvedPath
    }

    public func hasRequestChanges(comparedTo saved: Self) -> Bool {
        var left = self, right = saved
        left.comparisonBaseURL = ""; right.comparisonBaseURL = ""
        return left != right
    }
}

/// Navigation keeps the collection identity while showing the request the user actually edits.
public struct APIRequestItem: Identifiable, Sendable {
    public let source: APIEndpoint
    public let request: APIEndpoint
    public var id: String { source.id }
    public var name: String { request.name }
    public var method: String { request.method }
    public var path: String { request.path }

    public init(source: APIEndpoint, saved: APIEndpoint? = nil, draft: APIRequestDraft? = nil) {
        self.source = source
        let draft = draft ?? APIRequestDraft(endpoint: saved ?? source, baseURL: "")
        var display = saved ?? source
        display.method = draft.method; display.path = draft.resolvedPath; display.target = draft.baseURL
        request = display
    }

    public func matches(_ query: String) -> Bool { APICollection.matches(request, query: query) }
}

public struct APIResponsePreview: Equatable, Sendable {
    public let raw: String
    public let status: String
    public let headers: String
    public let body: String
    public let isFailure: Bool
    public private(set) var isConnectionFailure = false
    public var bodyBytes: Int { body.utf8.count }

    public init(output: String) {
        raw = output
        let boundary = output.range(of: "\n\n")
        let head = boundary.map { String(output[..<$0.lowerBound]) } ?? output
        let lines = head.components(separatedBy: "\n")
        status = lines.first ?? "Response"
        headers = lines.dropFirst().joined(separator: "\n")
        body = boundary.map { String(output[$0.upperBound...]) } ?? ""
        if status.hasPrefix("HTTP "), let code = Int(status.split(separator: " ").dropFirst().first ?? "") { isFailure = code >= 400 }
        else { isFailure = status.hasPrefix("gRPC Failed") }
    }

    public init(error: String, cancelled: Bool = false) {
        raw = error; status = cancelled ? "Cancelled" : "Request failed"
        headers = ""; body = error; isFailure = true
    }

    public init(error: any Error) {
        self.init(error: error.localizedDescription)
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return }
        isConnectionFailure = [URLError.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(URLError.Code(rawValue: value.code))
    }
}

extension APICollection {
    public static func isLocalTarget(_ target: String) -> Bool {
        guard let host = URLComponents(string: target)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) || host.hasSuffix(".localhost")
    }
    public static func matches(_ endpoint: APIEndpoint, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let text = endpoint.method + " " + endpoint.name + " " + endpoint.path
        return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
}

public struct APIRequestRun: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let endpointID: String
    public let request: APIRequestDraft
    public var primary: APIResponsePreview
    public let target: String
    public var comparison: APIResponsePreview?
    public var comparisonTarget: String?
    public var difference = ""

    public init(endpointID: String, request: APIRequestDraft, primary: APIResponsePreview, date: Date = Date()) {
        id = UUID(); self.date = date; self.endpointID = endpointID; self.request = request
        self.primary = primary; target = request.requestURL()
    }
}

/// Session-only history: bounded across the project, including large response previews.
public struct APIRequestHistory: Sendable {
    public private(set) var runs: [APIRequestRun] = []
    public init() {}
    public mutating func record(_ run: APIRequestRun) {
        runs.insert(run, at: 0)
        while runs.count > 20 || (runs.count > 1 && runs.reduce(0, { $0 + $1.primary.raw.utf8.count + ($1.comparison?.raw.utf8.count ?? 0) }) > 8_000_000) {
            runs.removeLast()
        }
    }
    public func runs(for endpointID: String) -> [APIRequestRun] { runs.filter { $0.endpointID == endpointID } }
    public func latest(for endpointID: String) -> APIRequestRun? { runs.first { $0.endpointID == endpointID } }
}
