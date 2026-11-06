import Foundation

extension APICollection {
    static func validRPC(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][\w.]*/[A-Za-z_]\w*$"#, options: .regularExpression) != nil
    }

    public static func execute(_ entry: APIEndpoint, base: String, headers: String, root: URL, environment: [String: String]) async throws -> String {
        if entry.method == "GRPC" { return try await rpc(entry, base: base, headers: headers, root: root, environment: environment) }
        if entry.method == "GRAPHQL" {
            guard let document = entry.body, !document.isEmpty else { throw AgentError.launchFailed("Enter a GraphQL operation.") }
            let variables = entry.variables?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let values = try JSONSerialization.jsonObject(with: Data((variables.isEmpty ? "{}" : variables).utf8)) as? [String: Any] else {
                throw AgentError.launchFailed("GraphQL variables must be a JSON object.")
            }
            let payload = try JSONSerialization.data(withJSONObject: ["query": document, "variables": values])
            let fields = try parseHeaders(headers)
            let hasType = fields.keys.contains { $0.lowercased() == "content-type" }
            return try await send(base: base, path: entry.path, method: "POST", headers: hasType ? headers : headers + "\nContent-Type: application/json", body: String(decoding: payload, as: UTF8.self))
        }
        return try await send(base: base, path: entry.path, method: entry.method, headers: headers, body: entry.body ?? "")
    }

    private static func rpc(_ entry: APIEndpoint, base: String, headers: String, root: URL, environment: [String: String]) async throws -> String {
        guard let binary = ShellEnvironment.locate("grpcurl", in: environment) else { throw AgentError.launchFailed("Install grpcurl with brew install grpcurl to send RPCs.") }
        guard validRPC(entry.path), let url = URLComponents(string: base), let host = url.host, !host.isEmpty,
              let scheme = url.scheme, ["grpc","grpcs","http","https"].contains(scheme), url.path.isEmpty || url.path == "/" else {
            throw AgentError.launchFailed("Enter grpc://host:port or grpcs://host:port and a package.Service/Method.")
        }
        let tls = ["https","grpcs"].contains(scheme)
        var args = ["-max-time","30","-max-msg-sz","1048576","-expand-headers"]
        if !tls { args += ["-plaintext"] }
        if let proto = entry.protoFile {
            let file = try projectFile(proto, root: root)
            let directory = root.resolvingSymlinksInPath().standardizedFileURL
            for path in (entry.importPaths ?? []) {
                let dir = directory.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
                guard (dir.path == directory.path || dir.path.hasPrefix(directory.path + "/")),
                      (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    throw AgentError.launchFailed("Invalid proto import directory: " + path)
                }
                args += ["-import-path",dir.path]
            }
            args += ["-import-path",directory.path,"-import-path",file.deletingLastPathComponent().path,"-proto",file.path]
        }
        var env = environment
        for (index, field) in try parseHeaders(headers).enumerated() {
            let key = "MARIKA_RPC_METADATA_\(index)"
            env[key] = field.value
            args += ["-H", field.key + ": " + "${" + key + "}"]
        }
        let address = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        let body = entry.body ?? ""
        args += ["-d",body.isEmpty ? "{}" : body, address + ":" + String(url.port ?? (tls ? 443 : 80)), entry.path]
        let start = Date()
        let result = try await Command.run(binary, args, workingDirectory: root, environment: env, timeout: 35)
        let status = result.succeeded ? "OK" : "Failed (\(result.status))"
        return "gRPC \(status) · \(Int(Date().timeIntervalSince(start) * 1000)) ms\n\n" + String((result.output + result.errorOutput).prefix(1_000_000))
    }
}
