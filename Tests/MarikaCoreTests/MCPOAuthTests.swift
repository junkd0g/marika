import Foundation
import Testing
@testable import MarikaCore

actor MemoryMCPVault: MCPCredentialVault {
    var values: [String: MCPOAuthCredential] = [:]
    func read(_ key: String) -> MCPOAuthCredential? { values[key] }
    func write(_ credential: MCPOAuthCredential?, key: String) { values[key] = credential }
}

struct MCPOAuthTests {
    private func server(_ mode: String = "normal") async throws -> (LineProcess, URL) {
        let process = LineProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [try Fixture.url("fake-oauth.py").path, mode],
            environment: ProcessInfo.processInfo.environment, workingDirectory: FileManager.default.temporaryDirectory)
        try process.start()
        var iterator = process.output.makeAsyncIterator()
        guard case .line(let data) = await iterator.next(), let url = URL(string: String(decoding: data, as: UTF8.self)) else { throw AgentError.launchFailed("OAuth fixture did not start") }
        return (process, url)
    }

    @Test func pkceMatchesThePublishedS256VectorAndRejectsInsecureEndpoints() throws {
        #expect(MCPOAuthClient.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        for address in ["http://example.com/token", "https://user:password@example.com/token", "file:///tmp/token", "https://example.com/token#fragment"] {
            #expect(throws: AgentError.self) { try MCPOAuthClient.validatedURL(address) }
        }
        #expect(try MCPOAuthClient.validatedURL("http://127.0.0.1:1234/mcp").host == "127.0.0.1")
        #expect(MCPOAuthClient.randomSecret().count >= 43)
    }

    @Test(arguments: ["wrong-issuer", "wrong-resource", "no-pkce"])
    func invalidDiscoveryIsRefused(mode: String) async throws {
        let (process, url) = try await server(mode)
        defer { process.terminate(); process.forceKill() }
        await #expect(throws: AgentError.self) { try await MCPOAuthClient().discover(server: url) }
    }

    @Test func browserCallbackExchangeRefreshAndTokenIsolation() async throws {
        let (process, serverURL) = try await server()
        defer { process.terminate(); process.forceKill() }
        let client = MCPOAuthClient(), state = MCPOAuthClient.randomSecret(), verifier = MCPOAuthClient.randomSecret()
        let callback = try OAuthCallbackServer(state: state)
        defer { callback.stop() }
        let redirect = try await callback.start()
        let discovery = try await client.discover(server: serverURL)
        let clientID = try await client.register(discovery, redirect: redirect)
        #expect(clientID == "fixture-client")
        let authorization = MCPOAuthClient.authorizationURL(discovery, clientID: clientID, redirect: redirect, verifier: verifier, state: state)
        let (_, response) = try await URLSession.shared.data(from: authorization)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let code = try await callback.code(timeout: 2)
        let credential = try await client.exchange(discovery, clientID: clientID, redirect: redirect, verifier: verifier, code: code)
        #expect(credential.accessToken == "fixture-access")
        let vault = MemoryMCPVault(), credentials = MCPCredentials(vault: vault)
        try await credentials.save(credential, key: "project-one")
        #expect(try await credentials.token(key: "project-one", server: serverURL) == "fixture-refreshed")
        #expect(try await vault.read("project-one")?.refreshToken == "fixture-rotated")
        #expect(try await credentials.token(key: "project-two", server: serverURL) == nil)
        await #expect(throws: AgentError.self) { try await credentials.token(key: "project-one", server: URL(string: "https://other.example/mcp")!) }
        try await credentials.save(nil, key: "project-one")
        #expect(await credentials.isSignedIn("project-one") == false)
    }

    @Test func incorrectCallbackStateIsIgnoredAndCancellationReturns() async throws {
        let callback = try OAuthCallbackServer(state: "expected-state")
        defer { callback.stop() }
        let redirect = try await callback.start()
        var parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "code", value: "forged"), URLQueryItem(name: "state", value: "incorrect")]
        let (_, response) = try await URLSession.shared.data(from: parts.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        let task = Task { try await callback.code(timeout: 10) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled callback returned a code") }
        catch { #expect(error is CancellationError) }
    }

    @Test func signingOutDuringRefreshDoesNotRestoreTheCredential() async throws {
        let (process, url) = try await server("slow-refresh")
        defer { process.terminate(); process.forceKill() }
        let discovery = try await MCPOAuthClient().discover(server: url)
        let expired = MCPOAuthCredential(resource: discovery.resource, issuer: discovery.issuer, tokenEndpoint: discovery.tokenEndpoint,
            clientID: "fixture-client", accessToken: "expired", refreshToken: "fixture-refresh", expiresAt: .distantPast, scope: nil)
        let vault = MemoryMCPVault(), credentials = MCPCredentials(vault: vault)
        try await credentials.save(expired, key: "project")
        let first = Task { try await credentials.token(key: "project", server: url) }
        let second = Task { try await credentials.token(key: "project", server: url) }
        try await Task.sleep(for: .milliseconds(40))
        try await credentials.save(nil, key: "project")
        #expect((try? await first.value) == nil)
        #expect((try? await second.value) == nil)
        #expect(await vault.read("project") == nil)
    }

    @Test func providerConfigurationKeepsOAuthTokensOutOfArguments() throws {
        let servers: [String: JSONValue] = ["fixture": ["url": "https://example.test/mcp", "bearer_token_env_var": "MARIKA_MCP_OAUTH_TEST"]]
        let environment = ["MARIKA_MCP_OAUTH_TEST": "private-fixture-value"]
        let claude = try ProjectMCP.claudeServers(servers, environment: environment, deferCredentials: true)
        let arguments = try ProjectMCP.codexArguments(servers).joined(separator: " ")
        #expect(claude["fixture"]?["headers"]?["Authorization"]?.string == "Bearer ${MARIKA_MCP_OAUTH_TEST}")
        #expect(!String(decoding: try JSONValue.object(claude).serialized(), as: UTF8.self).contains("private-fixture-value"))
        #expect(!arguments.contains("private-fixture-value"))
        #expect(arguments.contains("MARIKA_MCP_OAUTH_TEST"))
    }
}
