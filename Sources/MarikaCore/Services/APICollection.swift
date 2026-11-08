import Foundation

public struct APIEndpoint: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var method: String
    public var path: String
    public var source: String
    public var line: Int?
    public var headers: [String: String]?
    public var body: String?
    public var target: String?
    public var variables: String?
    public var protoFile: String?
    public var importPaths: [String]?
    public var note: String?
    /// Values entered in the playground, retained separately from the route template.
    public var pathParameters: [String: String]?
    public var id: String {
        let route = method + " " + path.components(separatedBy: "?")[0]
        let operation = method == "GRAPHQL" ? route + " " + name : route
        return target.map { operation + " @ " + $0 } ?? operation
    }
}

public struct APICollection: Codable, Hashable, Sendable {
    public var baseURL: String
    public var endpoints: [APIEndpoint]
    public var composeFiles: [String]?
    public var profiles: [String]?
    public var startupNote: String?

    public static func projectFile(_ path: String, root: URL) throws -> URL {
        let directory = root.resolvingSymlinksInPath().standardizedFileURL
        let url = directory.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard !path.hasPrefix("/"), url.path.hasPrefix(directory.path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw AgentError.launchFailed("File must exist inside the project: " + path)
        }
        return url
    }

    public func validate(at root: URL) throws {
        guard ["http","https","grpc","grpcs"].contains(URL(string: baseURL)?.scheme), URL(string: baseURL)?.host != nil else {
            throw AgentError.launchFailed("Provide a base URL with a scheme and host.")
        }
        for entry in endpoints {
            _ = try Self.projectFile(entry.source, root: root)
            if entry.method == "GRPC" {
                guard Self.validRPC(entry.path) else { throw AgentError.launchFailed("Expected package.Service/Method for " + entry.name) }
                if let proto = entry.protoFile { _ = try Self.projectFile(proto, root: root) }
                continue
            }
            guard entry.path.hasPrefix("/"), !entry.path.hasPrefix("//"), (Self.methods.contains(entry.method) || entry.method == "GRAPHQL") else {
                throw AgentError.launchFailed("Invalid method or relative request path: " + entry.id)
            }
        }
        for path in composeFiles ?? [] {
            let url = try Self.projectFile(path, root: root)
            guard ["yaml","yml"].contains(url.pathExtension.lowercased()) else { throw AgentError.launchFailed("Expected a Compose YAML file.") }
        }
    }

    public static let methods = ["GET","POST","PUT","PATCH","DELETE","HEAD","OPTIONS"]
    public func composeArguments(projectID: UUID) -> [String] {
        ["compose", "-p", "marika-" + projectID.uuidString.lowercased()] +
        (composeFiles ?? []).flatMap { ["-f", $0] } + (profiles ?? []).flatMap { ["--profile", $0] }
    }

    public static func parseHeaders(_ headers: String) throws -> [String: String] {
        var parsed: [String: String] = [:]
        for raw in headers.split(whereSeparator: \.isNewline) {
            let fields = raw.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { throw AgentError.launchFailed("Write one Name: value header per line.") }
            parsed[String(fields[0])] = fields[1].trimmingCharacters(in: .whitespaces)
        }
        return parsed
    }

    public static func send(base: String, path: String, method: String, headers: String, body: String) async throws -> String {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("{"), !path.contains("}"),
              let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path),
              ["http","https"].contains(url.scheme), url.host != nil else {
            throw AgentError.launchFailed("Enter a base URL and replace any placeholders in the request path.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        for (name, value) in try parseHeaders(headers) { request.setValue(value, forHTTPHeaderField: name) }
        if !body.isEmpty { request.httpBody = Data(body.utf8) }
        let start = Date()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in stream {
            data.append(byte)
            if data.count > 1_000_000 { break }
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let truncated = data.count > 1_000_000
        let content: String
        if let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted,.sortedKeys]) {
            content = String(decoding: pretty, as: UTF8.self)
        } else { content = String(decoding: data.prefix(1_000_000), as: UTF8.self) }
        let fields = (response as? HTTPURLResponse)?.allHeaderFields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n") ?? ""
        return "HTTP \(code) · \(Int(Date().timeIntervalSince(start) * 1000)) ms\n\(fields)\n\n\(content)" + (truncated ? "\n[Preview truncated]" : "")
    }
}

extension APICollection {
    public static func differences(_ first: String, _ second: String) -> String {
        func payload(_ value: String) -> String {
            guard let boundary = value.range(of: "\n\n") else { return value }
            return String(value[boundary.upperBound...])
        }
        let left = payload(first), right = payload(second)
        if left == right { return "Response bodies match." }
        guard let a = try? JSONDecoder().decode(JSONValue.self, from: Data(left.utf8)),
              let b = try? JSONDecoder().decode(JSONValue.self, from: Data(right.utf8)) else {
            return "Response bodies differ."
        }
        var paths: [String] = []
        func compare(_ a: JSONValue?, _ b: JSONValue?, _ path: String) {
            guard a != b, paths.count < 40 else { return }
            switch (a, b) {
            case let (.object(x), .object(y)):
                for key in Set(x.keys).union(y.keys).sorted() { compare(x[key], y[key], path + "." + key) }
            case let (.array(x), .array(y)):
                for i in 0..<max(x.count,y.count) where paths.count < 40 {
                    compare(i < x.count ? x[i] : nil, i < y.count ? y[i] : nil, path + "[\(i)]")
                }
            default: paths.append(path)
            }
        }
        compare(a, b, "$")
        return paths.isEmpty ? "JSON values match." : "Changed fields · " + paths.joined(separator: ", ")
    }
}
