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
                    Text("MCP servers").font(.system(size: 18, weight: .semibold))
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
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.attention).textSelection(.enabled) }
            if let configurationError {
                Label(configurationError + " Open Advanced JSON to correct it.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.attention)
            } else if servers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor)
                    Text("Add your first MCP server").font(.system(size: 14, weight: .medium))
                    Text("Use a local command or connect to an HTTP endpoint.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Add server") { editing = MCPServerDraft() }
                }.frame(maxWidth: .infinity).padding(.vertical, 25).surface()
            } else {
                ForEach(servers) { server in serverCard(server) }
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
        .sheet(item: $editing) { draft in
            MCPServerEditor(draft: draft) { server in
                configuration = try MCPConfigurationEditor.save(server, replacing: draft.originalName, in: configuration)
                reports[server.name] = nil; failures[server.name] = nil; error = nil; editing = nil
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
                            configuration = result; importText = ""; error = nil; importing = false
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
            if server.transport != "stdio" { authorizationRow(server) }
            if let report = reports[server.name] {
                DisclosureGroup("Server details and tools") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("\(report.server) \(report.version) · MCP \(report.protocolVersion)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        if report.resources > 0 || report.prompts > 0 { Text("\(report.resources) resources · \(report.prompts) prompts").font(.system(size: 11)).foregroundStyle(.secondary) }
                        ForEach(report.tools) { tool in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tool.name).font(.system(size: 11, weight: .medium, design: .monospaced))
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
                Text("Signed in · Keychain").foregroundStyle(.secondary)
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
                Text("Browser sign-in for servers that support OAuth").foregroundStyle(.secondary)
                Spacer()
                Button("Sign in") { signIn(server) }.disabled(!server.enabled)
                    #if DEBUG
                    .background(DebugViewMarker(name: "mcp-sign-in-" + server.name))
                    #endif
            }
        }.font(.system(size: 11)).controlSize(.small)
        if let key, let message = model.mcpAccounts.errors[key] {
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.attention).textSelection(.enabled)
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
            model.mcpAccounts.signIn(key: key, server: url, clientID: fields["marikaOAuthClientID"]?.string) {
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
            for key in ["url", "type", "headers", "http_headers", "marikaOAuthID", "marikaOAuthClientID"] { config[key] = nil }
            config["command"] = .string(command.trimmingCharacters(in: .whitespacesAndNewlines))
            config["args"] = .array(arguments.map { .string($0.value) })
            config["env"] = try fields(environment)
        } else {
            for key in ["command", "args", "env", "http_headers"] { config[key] = nil }
            config["url"] = .string(url.trimmingCharacters(in: .whitespacesAndNewlines))
            config["type"] = .string(transport)
            config["headers"] = try fields(headers)
            config["marikaOAuthClientID"] = oauthClientID.isEmpty ? nil : .string(oauthClientID)
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
