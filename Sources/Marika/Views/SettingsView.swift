import MarikaCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AgentsSettings()
                .tabItem { Label("Agents", systemImage: "person.2") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "textformat.size") }
            UpdatesView().frame(height: 480)
                .tabItem { Label("Updates", systemImage: "arrow.down.app") }
        }
        .frame(width: 540)
    }
}

private struct AgentsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var showsKeySaved = false
    @State private var apiKeyError: String?

    private var billing: Binding<ClaudeBilling> {
        Binding(
            get: { model.workspace.preferences.claudeBilling },
            set: { model.setClaudeBilling($0) })
    }

    var body: some View {
        Form {
            Section {
                AgentRow(
                    agent: .claude,
                    installHint: "curl -fsSL https://claude.ai/install.sh | bash",
                    detail: "Runs the Claude Code CLI on your Mac. Sign-in happens in the CLI, so your Claude plan works without Marika ever seeing your credentials.")
                Picker("Billing", selection: billing) {
                    ForEach(ClaudeBilling.allCases) { Text($0.title).tag($0) }
                }
                if model.workspace.preferences.claudeBilling == .apiKey {
                    HStack {
                        SecureField(hasStoredKey ? "Key saved in your Keychain" : "Anthropic API key", text: $apiKey)
                        Button(showsKeySaved ? "Saved" : "Save") {
                            do {
                                try model.setAnthropicAPIKey(apiKey)
                                hasStoredKey = true
                                apiKey = ""
                                apiKeyError = nil
                                showsKeySaved = true
                            } catch {
                                showsKeySaved = false
                                apiKeyError = error.localizedDescription
                            }
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .onChange(of: apiKey) { _, value in
                        if !value.isEmpty { showsKeySaved = false }
                        apiKeyError = nil
                    }
                    if let apiKeyError {
                        Text(apiKeyError).font(.caption).foregroundStyle(.red)
                    }
                    Text("Charged per token by Anthropic at API rates. Stored only in your Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(AgentKind.claude.displayName)
            }

            Section {
                AgentRow(
                    agent: .codex,
                    installHint: "brew install --cask codex",
                    detail: "Runs Codex on your Mac, from the ChatGPT desktop app or a separate install. Sign-in happens in Codex, so your ChatGPT plan works without Marika ever seeing your credentials.")
            } header: {
                Text(AgentKind.codex.displayName)
            }
        }
        .formStyle(.grouped)
        .frame(height: 430)
        .task {
            if model.workspace.preferences.claudeBilling == .apiKey {
                hasStoredKey = Keychain.read(account: Keychain.anthropicAPIKey) != nil
            }
        }
    }
}

private struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: AgentKind
    let installHint: String
    let detail: LocalizedStringKey

    private var status: AgentStatus { model.statuses[agent] ?? AgentStatus() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AgentStatusLine(agent: agent, linksToSettings: false)
                Spacer()
                if status.readiness == .ready {
                    AgentSignInButton(agent: agent, title: "Switch Account…")
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status.readiness == .notInstalled {
                HStack {
                    Text(installHint)
                        .font(Theme.codeSmall)
                        .textSelection(.enabled)
                    Spacer()
                    CopyButton(text: installHint)
                }
                .padding(7)
                .surface(cornerRadius: 6)
            } else if let path = status.executable?.path {
                Text([path, status.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.codeSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Toggle("Task notification banners", isOn: Binding(get: { model.workspace.preferences.taskNotifications ?? true }, set: { enabled in model.setPreferences { $0.taskNotifications = enabled } }))
            Text("Background banners open the related task or approval. Activity remains saved when banners are off.").font(.caption).foregroundStyle(.secondary)
            Picker(
                "New projects use",
                selection: Binding(
                    get: { model.workspace.preferences.defaultAgent },
                    set: { value in model.setPreferences { $0.defaultAgent = value } })
            ) {
                ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
            }
            Picker(
                "Approvals",
                selection: Binding(
                    get: { model.workspace.preferences.defaultMode },
                    set: { value in model.setPreferences { $0.defaultMode = value } })
            ) {
                ForEach(ApprovalMode.allCases.filter { $0 != .bypass }) { mode in
                    Text(mode.title(for: model.workspace.preferences.defaultAgent)).tag(mode)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 230)
    }
}
