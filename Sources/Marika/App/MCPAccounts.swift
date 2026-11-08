import AppKit
import MarikaCore
import Observation

@MainActor @Observable final class MCPAccounts {
    let credentials: MCPCredentials
    var signedIn = Set<String>()
    var busy = Set<String>()
    var errors: [String: String] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    #if DEBUG
    var openAuthorizationURL: ((URL) async throws -> Void)?
    #endif

    init(credentials: MCPCredentials = MCPCredentials()) { self.credentials = credentials }
    static func key(projectID: UUID, configuration: JSONValue) -> String? {
        guard let id = configuration["marikaOAuthID"]?.string, UUID(uuidString: id) != nil else { return nil }
        return projectID.uuidString + "." + id
    }
    func load(_ key: String) async {
        if await credentials.isSignedIn(key) { signedIn.insert(key) } else { signedIn.remove(key) }
    }
    func signIn(key: String, server: URL, clientID: String?, finished: @escaping () -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key); errors[key] = nil
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { busy.remove(key); tasks[key] = nil }
            do {
                let client = MCPOAuthClient()
                let discovery = try await client.discover(server: server)
                let state = MCPOAuthClient.randomSecret(), verifier = MCPOAuthClient.randomSecret()
                let callback = try OAuthCallbackServer(state: state)
                defer { callback.stop() }
                let redirect = try await callback.start()
                let id: String
                if let clientID, !clientID.isEmpty { id = clientID }
                else { id = try await client.register(discovery, redirect: redirect) }
                let url = MCPOAuthClient.authorizationURL(discovery, clientID: id, redirect: redirect, verifier: verifier, state: state)
                #if DEBUG
                if let openAuthorizationURL { try await openAuthorizationURL(url) }
                else if !NSWorkspace.shared.open(url) { throw AgentError.launchFailed("Couldn't open the sign-in page in your browser.") }
                #else
                guard NSWorkspace.shared.open(url) else { throw AgentError.launchFailed("Couldn't open the sign-in page in your browser.") }
                #endif
                let code = try await callback.code()
                let token = try await client.exchange(discovery, clientID: id, redirect: redirect, verifier: verifier, code: code)
                try Task.checkCancellation()
                try await credentials.save(token, key: key)
                signedIn.insert(key); finished()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { errors[key] = error.localizedDescription } }
        }
    }
    func cancel(_ key: String) { tasks[key]?.cancel() }
    @discardableResult func signOut(_ key: String) async -> Bool {
        tasks[key]?.cancel()
        do { try await credentials.save(nil, key: key); signedIn.remove(key); errors[key] = nil; return true }
        catch { errors[key] = error.localizedDescription; return false }
    }
    func authorize(_ servers: [String: JSONValue], projectID: UUID, environment: [String: String]) async throws -> (servers: [String: JSONValue], environment: [String: String]) {
        var servers = servers, environment = environment
        for (name, value) in servers {
            guard let key = Self.key(projectID: projectID, configuration: value) else { continue }
            guard let address = value["url"]?.string, let url = URL(string: address),
                  let token = try await credentials.token(key: key, server: url), var config = value.object else {
                throw AgentError.launchFailed("Sign in to \(name) in Project → Connections before connecting.")
            }
            let variable = "MARIKA_MCP_OAUTH_" + String(key.filter(\.isLetter).prefix(40)) + String(key.filter(\.isNumber).prefix(32))
            environment[variable] = token
            config["bearer_token_env_var"] = .string(variable)
            servers[name] = .object(config)
        }
        return (servers, environment)
    }
}
