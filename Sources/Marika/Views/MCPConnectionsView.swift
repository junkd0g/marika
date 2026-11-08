import MarikaCore
import SwiftUI

struct MCPConnectionsView: View {
    @Environment(AppModel.self) private var model
    @Binding var configuration: String
    let root: URL
    let projectID: UUID
    let environment: [String: String]
    @State private var editing: MCPServerDraft?
    @State private var removal: MCPServerConfiguration?
    @State private var importing = false
    @State private var importText = ""
    @State private var error: String?
    @State private var advanced = false
    @State private var catalogSelection: ConnectionCatalogEntry?
    @State private var catalogClientID = ""
    @State private var catalogToken = ""
    @State private var catalogRedirect = "http://127.0.0.1:8765/oauth/slack"
    @State private var connecting = false
    @State private var query = ""
    @State private var showsCatalog = true
    @State private var reports: [String: MCPConnectionReport] = [:]
    @State private var failures: [String: String] = [:]
    @State private var checks: [String: Task<Void, Never>] = [:]

    private var servers: [MCPServerConfiguration] { (try? MCPConfigurationEditor.servers(in: configuration)) ?? [] }
    private var configurationError: String? {
        do { _ = try MCPConfigurationEditor.servers(in: configuration); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connections").font(.system(size: 18, weight: .semibold))
                    Text("Connect this project's agents to external tools and data.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import JSON") { importing = true }
                Button("Add server", systemImage: "plus") { editing = MCPServerDraft() }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mcp-add-server")
                    #if DEBUG
                    .background(DebugViewMarker(name: "mcp-add-server"))
                    #endif
            }
            Text("Changes apply on the next agent connection after you save. Testing starts a temporary connection and lists capabilities; it does not call any tools.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search connections", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Search connections")
            Picker("Connections", selection: $showsCatalog) {
                Text("Catalog").tag(true)
                Text("Configured (\(servers.count))").tag(false)
            }.pickerStyle(.segmented)
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.attention).textSelection(.enabled) }
            if let configurationError {
                Label(configurationError + " Open Advanced JSON to correct it.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.attention)
            } else if showsCatalog {
                ForEach(ConnectionCatalogEntry.entries.filter { $0.matches(query) }) { entry in
                    if let configured = entry.configuredServer(in: servers) { serverCard(configured) }
                    else { catalogCard(entry) }
                }
                if ConnectionCatalogEntry.entries.filter({ $0.matches(query) }).isEmpty {
                    Text("No catalog matches. Use Add server for another service.").foregroundStyle(.secondary).padding(.vertical, 12)
                }
            } else if servers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor)
                    Text("Add your first MCP server").font(.system(size: 14, weight: .medium))
                    Text("Use a local command or connect to an HTTP endpoint.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Add server") { editing = MCPServerDraft() }
                }.frame(maxWidth: .infinity).padding(.vertical, 25).surface()
            } else {
                ForEach(servers.filter { query.isEmpty || ($0.name + " " + $0.summary).localizedStandardContains(query) }) { server in serverCard(server) }
                if !query.isEmpty, !servers.contains(where: { ($0.name + " " + $0.summary).localizedStandardContains(query) }) {
                    Text("No configured connections match your search.").foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Advanced JSON", isExpanded: $advanced) {
                TextEditor(text: $configuration).font(.system(size: 11, design: .monospaced)).frame(height: 220)
                    .scrollContentBackground(.hidden).padding(8).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))
                Button("Validate JSON") {
                    do { _ = try ProjectMCP.servers(configuration); error = nil }
                    catch { self.error = error.localizedDescription }
                }.padding(.top, 5)
            }.font(.system(size: 12)).padding(.top, 3)
        }
        .sheet(item: $catalogSelection) { entry in
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect \(entry.name)").font(.title2.bold())
                Text(entry.summary)
                Label("Access to review", systemImage: "lock.shield").font(.headline)
                Text(entry.permissions).fixedSize(horizontal: false, vertical: true)
                Text(entry.endpoint).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let setup = entry.setup {
                    ScrollView { Text(setup).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                    CopyButton(text: setup)
                }
                if entry.requiresClientID {
                    TextField("Approved OAuth client ID", text: $catalogClientID).textFieldStyle(.roundedBorder)
                    TextField("Registered loopback redirect", text: $catalogRedirect).textFieldStyle(.roundedBorder)
                }
                if entry.usesToken { SecureField("Personal access token", text: $catalogToken).textFieldStyle(.roundedBorder) }
                Link("Official setup guide", destination: URL(string: entry.documentation)!)
                Text(entry.usesToken ? "Connect stores the token in Keychain. Save Project Settings to retain the credential reference." : entry.usesOAuth ? "Connect opens the service's sign-in page. Credentials stay in Keychain. Save Project Settings to keep this connection." : "Connect adds the server. Use Test connection to check access, then Save Project Settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).foregroundStyle(Theme.attention) }
                HStack {
                    Button("Cancel") { catalogSelection = nil }.disabled(connecting)
                    Spacer()
                    Button(connecting ? "Connecting…" : "Connect") { connectCatalog(entry) }
                        .buttonStyle(.borderedProminent).disabled(connecting || (entry.requiresClientID && catalogClientID.isEmpty) || (entry.usesToken && catalogToken.isEmpty))
                }
            }.padding(24).frame(width: 520)
                .onDisappear { catalogToken = ""; catalogClientID = "" }.interactiveDismissDisabled(connecting)
        }
        .sheet(item: $editing) { draft in
            MCPServerEditor(draft: draft) { server in
                configuration = try MCPConfigurationEditor.save(server, replacing: draft.originalName, in: configuration)
                reports[server.name] = nil; failures[server.name] = nil; error = nil; editing = nil; showsCatalog = false; query = ""
            }
        }
        .sheet(isPresented: $importing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import MCP servers").font(.headline)
                Text("Paste an mcpServers JSON object. Existing names are kept; rename duplicates before importing.").font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: $importText).font(.system(size: 12, design: .monospaced)).frame(height: 250).padding(6).background(Theme.canvas)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Cancel") { importing = false; error = nil }
                    Spacer()
                    Button("Import") {
                        do {
                            var result = configuration
                            for server in try MCPConfigurationEditor.servers(in: importText) { result = try MCPConfigurationEditor.save(server, in: result) }
                            configuration = result; importText = ""; error = nil; importing = false; showsCatalog = false; query = ""
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(20).frame(width: 520)
        }
        .confirmationDialog("Remove \(removal?.name ?? "this server") from this project?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Remove server", role: .destructive) {
                guard let removal else { return }
                do { configuration = try MCPConfigurationEditor.remove(removal.name, from: configuration); checks[removal.name]?.cancel() }
                catch { self.error = error.localizedDescription }
                self.removal = nil
            }
        }
        .onDisappear { for task in checks.values { task.cancel() } }
        .task(id: configuration) {
            for server in servers { if let key = MCPAccounts.key(projectID: projectID, configuration: server.configuration) { await model.mcpAccounts.load(key) } }
        }
        .onChange(of: configuration) { oldValue, newValue in
            let old = (try? ProjectMCP.servers(oldValue)) ?? [:]
            let new = (try? ProjectMCP.servers(newValue)) ?? [:]
            for name in old.keys where old[name] != new[name] {
                checks[name]?.cancel(); reports[name] = nil; failures[name] = nil
            }
        }
        #if DEBUG
        .background(DebugViewMarker(name: "mcp-connections"))
        #endif
    }

    private func catalogCard(_ entry: ConnectionCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.system(size: 14, weight: .semibold))
                    Text(entry.category).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect") { error = nil; catalogClientID = ""; catalogToken = ""; catalogSelection = entry }.buttonStyle(.borderedProminent)
                    .accessibilityLabel("Connect " + entry.name)
            }
            Text(entry.summary)
            Text("Not configured · " + entry.setupLabel).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Permissions") { Text(entry.permissions).font(.caption).foregroundStyle(.secondary).padding(.top, 5) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
    }

    private func serverCard(_ server: MCPServerConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: server.transport == "stdio" ? "terminal" : "network").foregroundStyle(Color.accentColor).frame(width: 23).padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(server.name).font(.system(size: 13, weight: .semibold))
                        Text(server.transport == "stdio" ? "Local" : server.transport == "sse" ? "Legacy SSE" : "HTTP")
                            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2).background(Theme.surface, in: Capsule())
                    }
                    Text(server.summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Toggle("Enable \(server.name)", isOn: Binding(get: { server.enabled }, set: { enabled in
                    do { configuration = try MCPConfigurationEditor.enabled(enabled, name: server.name, in: configuration); reports[server.name] = nil; failures[server.name] = nil }
                    catch { self.error = error.localizedDescription }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    #if DEBUG
                    .background(DebugViewMarker(name: "mcp-toggle-" + server.name))
                    #endif
                Button { editing = MCPServerDraft(server) } label: { Image(systemName: "pencil") }.help("Edit server")
                    #if DEBUG
                    .background(DebugViewMarker(name: "mcp-edit-" + server.name))
                    #endif
                Button { removal = server } label: { Image(systemName: "trash") }.help("Remove server")
            }
            HStack(spacing: 8) {
                if checks[server.name] != nil {
                    ProgressView().controlSize(.mini)
                    Text("Checking connection…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { checks[server.name]?.cancel() }
                } else if let report = reports[server.name] {
                    Label("Connected · \(report.tools.count) \(report.tools.count == 1 ? "tool" : "tools")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        #if DEBUG
                        .background(DebugViewMarker(name: "mcp-connected-" + server.name))
                        #endif
                    Spacer()
                    Text("Checked \(report.checkedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    Button("Check again") { test(server) }.disabled(!server.enabled)
                } else {
                    Label(server.enabled ? "Not checked" : "Disabled", systemImage: server.enabled ? "circle.dashed" : "pause.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Test connection") { test(server) }.disabled(!server.enabled)
                        #if DEBUG
                        .background(DebugViewMarker(name: "mcp-test-" + server.name))
                        #endif
                }
            }.font(.system(size: 11)).controlSize(.small)
            if let failure = failures[server.name] { Text(failure).font(.system(size: 11)).foregroundStyle(Theme.attention).textSelection(.enabled) }
            let catalog = ConnectionCatalogEntry.entries.first(where: { $0.configuredServer(in: [server]) != nil })
            if let setup = catalog?.setup { DisclosureGroup("Setup instructions") { Text(setup).font(.caption).textSelection(.enabled); Link("Setup guide", destination: URL(string: catalog!.documentation)!) } }
            if server.transport != "stdio", catalog?.usesOAuth != false || catalog?.usesToken == true { authorizationRow(server) }
            if let report = reports[server.name] {
                DisclosureGroup("Permissions and tools (\(report.tools.count))") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Access labels are reported by the server. They describe tools, not an additional permission restriction.").font(.caption).foregroundStyle(.secondary)
                        Text("\(report.server) \(report.version) · MCP \(report.protocolVersion)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        if report.resources > 0 || report.prompts > 0 { Text("\(report.resources) resources · \(report.prompts) prompts").font(.system(size: 11)).foregroundStyle(.secondary) }
                        ForEach(report.tools) { tool in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tool.name).font(.system(size: 11, weight: .medium, design: .monospaced))
                                Text(tool.permissionsSummary + (tool.openWorld == true ? " · External services" : "")).font(.caption2).foregroundStyle(.secondary)
                                if !tool.description.isEmpty { Text(tool.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.top, 8)
                }.font(.system(size: 11))
            }
        }.padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
    }

    @ViewBuilder private func authorizationRow(_ server: MCPServerConfiguration) -> some View {
        let key = MCPAccounts.key(projectID: projectID, configuration: server.configuration)
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.secondary)
            if let key, model.mcpAccounts.busy.contains(key) {
                ProgressView().controlSize(.mini)
                Text("Complete sign-in in your browser").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.mcpAccounts.cancel(key) }
            } else if let key, model.mcpAccounts.signedIn.contains(key) {
                Text(server.configuration["marikaAuthKind"]?.string == "token" ? "Token saved · Keychain" : "Signed in · Keychain").foregroundStyle(.secondary)
                Spacer()
                Button("Sign out") {
                    Task {
                        guard await model.mcpAccounts.signOut(key) else { return }
                        reports[server.name] = nil
                        if var fields = server.configuration.object {
                            fields["marikaOAuthID"] = nil
                            configuration = (try? MCPConfigurationEditor.save(MCPServerConfiguration(name: server.name, configuration: .object(fields)), replacing: server.name, in: configuration)) ?? configuration
                        }
                    }
                }
            } else {
                Text(server.configuration["marikaAuthKind"]?.string == "token" ? "Token required" : "Browser sign-in for servers that support OAuth").foregroundStyle(.secondary)
                Spacer()
                Button(server.configuration["marikaAuthKind"]?.string == "token" ? "Add token" : "Sign in") {
                    if server.configuration["marikaAuthKind"]?.string == "token", let entry = ConnectionCatalogEntry.entries.first(where: { $0.configuredServer(in: [server]) != nil }) { catalogSelection = entry }
                    else { signIn(server) }
                }.disabled(!server.enabled)
                    #if DEBUG
                    .background(DebugViewMarker(name: "mcp-sign-in-" + server.name))
                    #endif
            }
        }.font(.system(size: 11)).controlSize(.small)
        if let key, let message = model.mcpAccounts.errors[key] {
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.attention).textSelection(.enabled)
        }
    }

    private func connectCatalog(_ entry: ConnectionCatalogEntry) {
        connecting = true
        let token = catalogToken, clientID = catalogClientID, redirect = catalogRedirect
        Task {
            defer { connecting = false }
            do {
                let previous = entry.configuredServer(in: servers)
                var fields = entry.server.configuration.object ?? [:]
                if !clientID.isEmpty { fields["marikaOAuthClientID"] = .string(clientID) }
                if entry.requiresClientID {
                    guard let url = URL(string: redirect) else { throw AgentError.launchFailed("Supply the registered loopback redirect.") }
                    _ = try OAuthCallbackServer(state: "validate", redirect: url)
                    fields["marikaOAuthRedirect"] = .string(redirect)
                }
                if entry.usesToken {
                    guard let url = URL(string: entry.endpoint) else { return }
                    let reference = UUID().uuidString; fields["marikaOAuthID"] = .string(reference)
                    let key = projectID.uuidString + "." + reference
                    try await model.mcpAccounts.credentials.save(MCPOAuthCredential.bearer(token, resource: url), key: key)
                    model.mcpAccounts.signedIn.insert(key)
                }
                let server = MCPServerConfiguration(name: previous?.name ?? entry.id, configuration: .object(fields))
                configuration = try MCPConfigurationEditor.save(server, replacing: previous?.name, in: configuration)
                catalogToken = ""; catalogSelection = nil; showsCatalog = false; query = ""; error = nil
                if entry.usesOAuth { signIn(server) }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func signIn(_ server: MCPServerConfiguration) {
        do {
            var fields = server.configuration.object ?? [:]
            if fields["marikaOAuthID"]?.string.flatMap(UUID.init(uuidString:)) == nil { fields["marikaOAuthID"] = .string(UUID().uuidString) }
            let configured = MCPServerConfiguration(name: server.name, configuration: .object(fields))
            let resolved = try ProjectMCP.resolved([server.name: configured.configuration], environment: environment)
            guard let address = resolved[server.name]?["url"]?.string, let url = URL(string: address),
                  let key = MCPAccounts.key(projectID: projectID, configuration: configured.configuration) else { return }
            configuration = try MCPConfigurationEditor.save(configured, replacing: server.name, in: configuration)
            model.mcpAccounts.signIn(key: key, server: url, clientID: fields["marikaOAuthClientID"]?.string, redirect: fields["marikaOAuthRedirect"]?.string.flatMap(URL.init(string:))) {
                if let updated = servers.first(where: { $0.name == server.name }) { test(updated) }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func test(_ server: MCPServerConfiguration) {
        guard checks[server.name] == nil else { return }
        reports[server.name] = nil; failures[server.name] = nil
        checks[server.name] = Task {
            defer { checks[server.name] = nil }
            do {
                let resolved = try ProjectMCP.resolved([server.name: server.configuration], environment: environment)
                let authorized = try await model.mcpAccounts.authorize(resolved, projectID: projectID, environment: environment)
                let report = try await MCPConnectionProbe.check(name: server.name, configuration: authorized.servers[server.name] ?? server.configuration, root: root, environment: authorized.environment)
                guard !Task.isCancelled, servers.first(where: { $0.name == server.name }) == server else { return }
                reports[server.name] = report
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failures[server.name] = error.localizedDescription } }
        }
    }
}

private struct MCPFieldPair: Identifiable {
    var id = UUID()
    var name: String
    var value: String
}

private struct MCPArgument: Identifiable {
    var id = UUID()
    var value: String
}

private struct MCPServerDraft: Identifiable {
    var id = UUID()
    var originalName: String?
    var name = ""
    var transport = "stdio"
    var command = ""
    var arguments: [MCPArgument] = []
    var url = ""
    var oauthClientID = ""
    var oauthRedirect = ""
    var environment: [MCPFieldPair] = []
    var headers: [MCPFieldPair] = []
    var original: [String: JSONValue] = [:]
    init(_ server: MCPServerConfiguration? = nil) {
        guard let server else { return }
        originalName = server.name; name = server.name; transport = server.transport
        original = server.configuration.object ?? [:]
        command = server.configuration["command"]?.string ?? ""
        arguments = (server.configuration["args"]?.array ?? []).map { MCPArgument(value: $0.string ?? "") }
        url = server.configuration["url"]?.string ?? ""
        oauthClientID = server.configuration["marikaOAuthClientID"]?.string ?? ""
        oauthRedirect = server.configuration["marikaOAuthRedirect"]?.string ?? ""
        environment = (server.configuration["env"]?.object ?? [:]).sorted { $0.key < $1.key }.map { MCPFieldPair(name: $0.key, value: $0.value.string ?? "") }
        headers = (server.configuration["headers"]?.object ?? server.configuration["http_headers"]?.object ?? [:]).sorted { $0.key < $1.key }.map { MCPFieldPair(name: $0.key, value: $0.value.string ?? "") }
    }
    func server() throws -> MCPServerConfiguration {
        func fields(_ pairs: [MCPFieldPair]) throws -> JSONValue {
            var result: [String: JSONValue] = [:]
            for pair in pairs {
                let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, result[name] == nil else { throw AgentError.launchFailed("Use a unique name for every variable or header.") }
                result[name] = .string(pair.value)
            }
            return .object(result)
        }
        var config = original
        if transport == "stdio" {
            for key in ["url", "type", "headers", "http_headers", "marikaOAuthID", "marikaOAuthClientID", "marikaOAuthRedirect", "marikaAuthKind"] { config[key] = nil }
            config["command"] = .string(command.trimmingCharacters(in: .whitespacesAndNewlines))
            config["args"] = .array(arguments.map { .string($0.value) })
            config["env"] = try fields(environment)
        } else {
            for key in ["command", "args", "env", "http_headers"] { config[key] = nil }
            config["url"] = .string(url.trimmingCharacters(in: .whitespacesAndNewlines))
            config["type"] = .string(transport)
            config["headers"] = try fields(headers)
            config["marikaOAuthClientID"] = oauthClientID.isEmpty ? nil : .string(oauthClientID)
            if !oauthRedirect.isEmpty {
                guard let url = URL(string: oauthRedirect) else { throw AgentError.launchFailed("Supply a valid loopback redirect.") }
                _ = try OAuthCallbackServer(state: "validate", redirect: url)
            }
            config["marikaOAuthRedirect"] = oauthRedirect.isEmpty ? nil : .string(oauthRedirect)
        }
        return MCPServerConfiguration(name: name.trimmingCharacters(in: .whitespacesAndNewlines), configuration: .object(config))
    }
}

private struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: MCPServerDraft
    let save: (MCPServerConfiguration) throws -> Void
    @State private var error: String?
    @State private var showsValues = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.originalName == nil ? "Add MCP server" : "Edit MCP server").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save server") { do { try save(draft.server()) } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent)
                    #if DEBUG
                    .background(DebugViewMarker(name: "mcp-save-server"))
                    #endif
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.attention) }
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    TextField("Server name", text: $draft.name)
                    Picker("Transport", selection: $draft.transport) {
                        Text("Local command").tag("stdio")
                        Text("HTTP").tag("http")
                        Text("Legacy SSE").tag("sse")
                    }.pickerStyle(.segmented)
                    if draft.transport == "stdio" {
                        TextField("Command, e.g. npx or /path/to/server", text: $draft.command)
                        HStack { Text("Arguments").fontWeight(.medium); Spacer(); Button("Add argument", systemImage: "plus") { draft.arguments.append(MCPArgument(value: "")) } }
                        ForEach($draft.arguments) { $argument in
                            HStack { TextField("Argument", text: $argument.value); Button { draft.arguments.removeAll { $0.id == argument.id } } label: { Image(systemName: "minus.circle") } }
                        }
                        pairs("Environment variables", values: $draft.environment)
                    } else {
                        TextField("https://server.example/mcp", text: $draft.url)
                        pairs("HTTP headers", values: $draft.headers)
                        TextField("OAuth public client ID (optional)", text: $draft.oauthClientID)
                        TextField("Registered loopback redirect (optional)", text: $draft.oauthRedirect)
                        Text("Leave the client ID empty for automatic registration. Sign-in credentials are stored in Keychain.").font(.system(size: 11)).foregroundStyle(.secondary)
                        if draft.transport == "sse" { Text("Use streamable HTTP for new servers; SSE is a legacy transport.").foregroundStyle(.secondary) }
                    }
                    Text("Use ${VARIABLE} references for values supplied by your environment. Additional settings imported through JSON are preserved.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.vertical, 3)
            }
        }.font(.system(size: 12)).controlSize(.small).textFieldStyle(.roundedBorder).padding(20).frame(width: 550, height: 460).background(Theme.canvas)
            #if DEBUG
            .background(DebugViewMarker(name: "mcp-server-editor"))
            #endif
    }
    private func pairs(_ title: String, values: Binding<[MCPFieldPair]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Button { showsValues.toggle() } label: { Image(systemName: showsValues ? "eye.slash" : "eye") }.help("Show or hide values")
                Button("Add", systemImage: "plus") { values.wrappedValue.append(MCPFieldPair(name: "", value: "")) }
            }
            ForEach(values) { $pair in
                HStack {
                    TextField("Name", text: $pair.name).frame(width: 150)
                    if showsValues { TextField("Value or ${VARIABLE}", text: $pair.value) }
                    else { SecureField("Value or ${VARIABLE}", text: $pair.value) }
                    Button { values.wrappedValue.removeAll { $0.id == pair.id } } label: { Image(systemName: "minus.circle") }
                }
            }
        }
    }
}
