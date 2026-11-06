import CryptoKit
import Foundation

public struct MCPOAuthDiscovery: Sendable {
    public let resource: URL
    public let issuer: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL?
    public let scope: String?
}

public struct MCPOAuthCredential: Codable, Sendable {
    public var resource: URL
    public var issuer: URL
    public var tokenEndpoint: URL
    public var clientID: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
}

private final class OAuthRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Public OAuth clients use S256 PKCE, resource indicators and exact issuer validation.
/// This type never opens a browser, stores credentials, or logs response bodies.
public struct MCPOAuthClient: Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: OAuthRedirectPolicy(), delegateQueue: nil)
    }

    public static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return base64url(Data(bytes))
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func challenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public static func canonical(_ url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        parts.fragment = nil
        if parts.path == "/" { parts.path = "" }
        return parts.url!
    }
    public static func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil, url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()))
        else { throw AgentError.launchFailed("OAuth requires HTTPS endpoints, or a local loopback server.") }
        return url
    }
    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
    private struct Response { var value: JSONValue; var http: HTTPURLResponse }
    private func request(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil) async throws -> Response {
        _ = try Self.validatedURL(url.absoluteString)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.protocolError("The authorization server did not return HTTP.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation(); data.append(byte)
            guard data.count <= 1_048_576 else { throw AgentError.protocolError("OAuth response exceeded the size limit.") }
        }
        return Response(value: (try? JSONValue(parsing: data)) ?? .null, http: http)
    }
    private func json(_ url: URL) async throws -> JSONValue {
        let response = try await request(url)
        guard response.http.statusCode == 200, response.value.object != nil else { throw AgentError.protocolError("OAuth discovery failed (HTTP \(response.http.statusCode)).") }
        return response.value
    }
    private static func metadataURL(_ url: URL, name: String, appendPath: Bool) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.query = nil; parts.fragment = nil
        let path = parts.path == "/" ? "" : parts.path
        parts.path = "/.well-known/" + name + (appendPath ? path : "")
        return parts.url!
    }
    private static func challengeField(_ name: String, header: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[,\\s])" + name + #"\s*=\s*\"([^\"]*)\""#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        return (header as NSString).substring(with: match.range(at: 1))
    }
    public func discover(server: URL) async throws -> MCPOAuthDiscovery {
        _ = try Self.validatedURL(server.absoluteString)
        var metadata: JSONValue?
        var challengedScope: String?
        for url in [Self.metadataURL(server, name: "oauth-protected-resource", appendPath: true), Self.metadataURL(server, name: "oauth-protected-resource", appendPath: false)] {
            if let value = try? await json(url) { metadata = value; break }
            try Task.checkCancellation()
        }
        if metadata == nil {
            let probe: JSONValue = ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Marika", "version": "1"]]]
            let response = try await request(server, method: "POST", body: probe.serialized(), contentType: "application/json")
            let header = response.http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
            challengedScope = Self.challengeField("scope", header: header)
            if let address = Self.challengeField("resource_metadata", header: header) { metadata = try await json(Self.validatedURL(address)) }
        }
        guard let metadata, let resourceText = metadata["resource"]?.string,
              let issuerText = metadata["authorization_servers"]?.array?.first?.string else {
            throw AgentError.launchFailed("This server does not publish OAuth discovery metadata. Use its documented authorization headers instead.")
        }
        let resource = try Self.validatedURL(resourceText), issuer = try Self.validatedURL(issuerText)
        let resourcePath = Self.canonical(resource).path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let serverPath = Self.canonical(server).path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard Self.sameOrigin(resource, server), resourcePath.isEmpty || serverPath == resourcePath || serverPath.hasPrefix(resourcePath + "/") else {
            throw AgentError.protocolError("The OAuth resource does not match this MCP server.")
        }
        var authorization: JSONValue?
        for url in [Self.metadataURL(issuer, name: "oauth-authorization-server", appendPath: true), issuer.appendingPathComponent(".well-known/openid-configuration")] {
            if let value = try? await json(url) { authorization = value; break }
            try Task.checkCancellation()
        }
        guard let authorization, let returnedIssuer = authorization["issuer"]?.string,
              Self.canonical(try Self.validatedURL(returnedIssuer)) == Self.canonical(issuer),
              let authorize = authorization["authorization_endpoint"]?.string, let token = authorization["token_endpoint"]?.string else {
            throw AgentError.protocolError("The authorization server's discovery metadata has a missing or mismatched issuer.")
        }
        guard authorization["code_challenge_methods_supported"]?.array?.contains(.string("S256")) == true else {
            throw AgentError.protocolError("This authorization server does not advertise S256 PKCE support.")
        }
        if let methods = authorization["token_endpoint_auth_methods_supported"]?.array, !methods.contains("none") {
            throw AgentError.protocolError("This server requires a confidential OAuth client. Marika supports public clients with PKCE.")
        }
        let registration = try authorization["registration_endpoint"]?.string.map(Self.validatedURL)
        return MCPOAuthDiscovery(resource: Self.canonical(resource), issuer: Self.canonical(issuer),
            authorizationEndpoint: try Self.validatedURL(authorize), tokenEndpoint: try Self.validatedURL(token), registrationEndpoint: registration,
            scope: challengedScope ?? metadata["scopes_supported"]?.array?.compactMap(\.string).joined(separator: " "))
    }
    public func register(_ discovery: MCPOAuthDiscovery, redirect: URL) async throws -> String {
        guard let endpoint = discovery.registrationEndpoint else {
            throw AgentError.launchFailed("This server needs a registered public client ID. Add it in the server's OAuth settings, then try again.")
        }
        let metadata: JSONValue = ["client_name": "Marika", "redirect_uris": [.string(redirect.absoluteString)],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"]
        let response = try await request(endpoint, method: "POST", body: metadata.serialized(), contentType: "application/json")
        guard (200..<300).contains(response.http.statusCode), let id = response.value["client_id"]?.string, !id.isEmpty,
              response.value["token_endpoint_auth_method"]?.string ?? "none" == "none" else {
            throw AgentError.launchFailed("Automatic OAuth client registration failed. Add a registered public client ID in this server's settings.")
        }
        return id
    }
    public static func authorizationURL(_ discovery: MCPOAuthDiscovery, clientID: String, redirect: URL, verifier: String, state: String) -> URL {
        var parts = URLComponents(url: discovery.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString), URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "resource", value: discovery.resource.absoluteString)]
            + (discovery.scope.flatMap { $0.isEmpty ? nil : URLQueryItem(name: "scope", value: $0) }.map { [$0] } ?? [])
        return parts.url!
    }
    private static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.keys.sorted().map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + fields[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
    }
    public func exchange(_ discovery: MCPOAuthDiscovery, clientID: String, redirect: URL, verifier: String, code: String) async throws -> MCPOAuthCredential {
        let response = try await request(discovery.tokenEndpoint, method: "POST", body: Self.form([
            "grant_type": "authorization_code", "client_id": clientID, "redirect_uri": redirect.absoluteString,
            "code_verifier": verifier, "code": code, "resource": discovery.resource.absoluteString]), contentType: "application/x-www-form-urlencoded")
        return try credential(response, resource: discovery.resource, issuer: discovery.issuer, endpoint: discovery.tokenEndpoint, clientID: clientID, fallbackRefresh: nil)
    }
    public func refresh(_ previous: MCPOAuthCredential) async throws -> MCPOAuthCredential {
        guard let refresh = previous.refreshToken else { throw AgentError.launchFailed("MCP sign-in expired. Sign in again in Project → MCP Servers.") }
        let response = try await request(previous.tokenEndpoint, method: "POST", body: Self.form([
            "grant_type": "refresh_token", "client_id": previous.clientID, "refresh_token": refresh, "resource": previous.resource.absoluteString]), contentType: "application/x-www-form-urlencoded")
        return try credential(response, resource: previous.resource, issuer: previous.issuer, endpoint: previous.tokenEndpoint, clientID: previous.clientID, fallbackRefresh: refresh)
    }
    private func credential(_ response: Response, resource: URL, issuer: URL, endpoint: URL, clientID: String, fallbackRefresh: String?) throws -> MCPOAuthCredential {
        guard (200..<300).contains(response.http.statusCode), let token = response.value["access_token"]?.string, !token.isEmpty,
              response.value["token_type"]?.string?.lowercased() == "bearer" else {
            throw AgentError.launchFailed("OAuth token exchange failed (HTTP \(response.http.statusCode)). Sign in again to reconnect.")
        }
        return MCPOAuthCredential(resource: resource, issuer: issuer, tokenEndpoint: endpoint, clientID: clientID, accessToken: token,
            refreshToken: response.value["refresh_token"]?.string ?? fallbackRefresh,
            expiresAt: Date().addingTimeInterval(max(0, response.value["expires_in"]?.double ?? 300)), scope: response.value["scope"]?.string)
    }
}

public protocol MCPCredentialVault: Sendable {
    func read(_ key: String) async throws -> MCPOAuthCredential?
    func write(_ credential: MCPOAuthCredential?, key: String) async throws
}

public actor MCPKeychainVault: MCPCredentialVault {
    public init() {}
    public func read(_ key: String) throws -> MCPOAuthCredential? {
        guard let value = Keychain.read(account: "mcp-oauth." + key) else { return nil }
        return try JSONDecoder().decode(MCPOAuthCredential.self, from: Data(value.utf8))
    }
    public func write(_ credential: MCPOAuthCredential?, key: String) throws {
        let text = try credential.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        guard Keychain.write(text, account: "mcp-oauth." + key) else { throw AgentError.launchFailed("Couldn't save the MCP sign-in to Keychain.") }
    }
}

public actor MCPCredentials {
    private let vault: any MCPCredentialVault
    private let client = MCPOAuthClient()
    private var refreshing: [String: Task<MCPOAuthCredential, Error>] = [:]
    private var versions: [String: Int] = [:]
    public init(vault: any MCPCredentialVault = MCPKeychainVault()) { self.vault = vault }
    public func isSignedIn(_ key: String) async -> Bool { (try? await vault.read(key)) != nil }
    public func save(_ credential: MCPOAuthCredential?, key: String) async throws {
        versions[key, default: 0] += 1
        if let task = refreshing[key] { task.cancel(); _ = await task.result; refreshing[key] = nil }
        try await vault.write(credential, key: key)
    }
    public func token(key: String, server: URL) async throws -> String? {
        guard var credential = try await vault.read(key) else { return nil }
        let resource = credential.resource
        guard server.scheme?.lowercased() == resource.scheme?.lowercased(), server.host?.lowercased() == resource.host?.lowercased(),
              server.port == resource.port, server.path == resource.path || server.path.hasPrefix(resource.path.hasSuffix("/") ? resource.path : resource.path + "/") else {
            throw AgentError.launchFailed("This MCP server changed. Sign in again before reconnecting.")
        }
        if credential.expiresAt.timeIntervalSinceNow <= 30 {
            let version = versions[key, default: 0]
            if let task = refreshing[key] {
                let refreshed = try await task.value
                guard versions[key, default: 0] == version else { throw CancellationError() }
                return refreshed.accessToken
            }
            let task = Task { [client, credential] in try await client.refresh(credential) }
            refreshing[key] = task
            defer { refreshing[key] = nil }
            credential = try await task.value
            guard versions[key, default: 0] == version else { throw CancellationError() }
            try await vault.write(credential, key: key)
        }
        return credential.accessToken
    }
}
