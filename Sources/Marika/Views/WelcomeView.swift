import MarikaCore
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    private var agent: AgentKind { model.welcomeAgent }
    private var status: AgentStatus { model.statuses[agent] ?? AgentStatus() }
    private var checklist: WelcomeChecklist { model.welcomeChecklist }
    private var usesAPIKey: Bool { agent == .claude && model.workspace.preferences.claudeBilling == .apiKey }
    private var signIn: AgentSignIn? { model.signIns[agent] }
    private var installURL: URL {
        URL(string: agent == .codex ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        AppIconMark(size: 52)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Welcome to Marika").font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                            Text("A few steps to your first conversation.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if model.workspace.preferences.welcomeCompleted == true, !model.workspace.projects.isEmpty {
                            Button { model.showsWelcome = false } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Back to workspace")
                                .help("Back to workspace").keyboardShortcut(.cancelAction)
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Picker("Coding agent", selection: Binding(get: { agent }, set: model.selectWelcomeAgent)) {
                            ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Coding agent")
                        #if DEBUG
                            .background(DebugViewMarker(name: "welcome-provider"))
                        #endif
                        HStack {
                            Text("You only need one agent to get started.")
                            Spacer(minLength: 8)
                            Button {
                                Task { await model.refreshAgents(force: true) }
                            } label: {
                                if model.isRefreshingAgents { ProgressView().controlSize(.mini) }
                                else { Label("Check Again", systemImage: "arrow.clockwise") }
                            }
                            .disabled(model.isRefreshingAgents)
                            .accessibilityLabel("Check agent setup again")
                            #if DEBUG
                                .background(DebugViewMarker(name: "welcome-check-again"))
                            #endif
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        if let suggested = model.welcomeSuggestedAgent {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("\(suggested.shortName) is already ready to use.")
                                Spacer(minLength: 8)
                                Button("Use \(suggested.shortName)") { model.selectWelcomeAgent(suggested) }
                                    .buttonStyle(WorkspaceButtonStyle(kind: .secondary))
                                    #if DEBUG
                                        .background(DebugViewMarker(name: "welcome-use-ready-agent"))
                                    #endif
                            }
                            .font(.system(size: 12)).padding(10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    VStack(spacing: 0) {
                        setupRow(1, title: "Agent installed", detail: installationDetail, state: checklist.installation) {
                            if checklist.installation == .pending {
                                Link("Install Guide ↗", destination: installURL).buttonStyle(WorkspaceButtonStyle(kind: .secondary))
                            } else if checklist.installation == .needsAttention {
                                checkAgain
                            }
                        }
                        Divider().padding(.leading, 54)
                        setupRow(2, title: usesAPIKey ? "API key connected" : "Signed in", detail: accountDetail,
                                 state: signIn?.isPending == true ? .checking : checklist.account) {
                            if signIn?.isPending == true {
                                VStack(spacing: 8) {
                                    checkAgain
                                    Button("Stop Waiting") { signIn?.stopWaiting() }.buttonStyle(.plain)
                                        .help("Stops checking in Marika. The Terminal sign-in stays open.")
                                }
                            } else if checklist.account == .pending || checklist.account == .needsAttention || signIn?.phase == .failed {
                                if usesAPIKey {
                                    SettingsLink { Text("Open Settings…") }.buttonStyle(WorkspaceButtonStyle(kind: .secondary))
                                } else if (checklist.account == .pending || signIn?.phase == .failed), status.executable != nil {
                                    AgentSignInButton(agent: agent)
                                        .buttonStyle(WorkspaceButtonStyle(kind: .secondary))
                                        #if DEBUG
                                            .background(DebugViewMarker(name: "welcome-sign-in"))
                                        #endif
                                } else { checkAgain }
                            }
                        }
                        Divider().padding(.leading, 54)
                        setupRow(3, title: "Project opened", detail: model.selectedProject?.name ?? "Choose the folder you want to work in.", state: checklist.project) {
                            Button(model.selectedProject == nil ? "Choose Folder…" : "Change…") { model.chooseProject() }
                                .buttonStyle(WorkspaceButtonStyle(kind: .secondary))
                                .help(model.selectedProject?.path ?? "Open a project folder (⌘O)")
                                #if DEBUG
                                    .background(DebugViewMarker(name: "welcome-open-project"))
                                #endif
                        }
                        Divider().padding(.leading, 54)
                        setupRow(4, title: "Ready to work", detail: checklist.isReady ? "Open Chat and describe your first task." : "Complete the steps above to start a conversation.", state: checklist.isReady ? .complete : .blocked) {
                            Button("Start Working") { Task { await model.finishWelcome() } }
                                .buttonStyle(WorkspaceButtonStyle(kind: .primary))
                                .keyboardShortcut(.defaultAction)
                                .disabled(!checklist.isReady)
                                #if DEBUG
                                    .background(DebugViewMarker(name: "welcome-start"))
                                #endif
                        }
                    }
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline) }

                    HStack(alignment: .firstTextBaseline) {
                        Text(checklist.isReady ? "Everything is ready." : "\(checklist.completedSteps) of 3 setup steps complete")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if model.selectedProject != nil {
                            Button("Explore in Editor") { Task { await model.finishWelcome(exploreOnly: true) } }
                                .help("Open your project without starting an agent conversation")
                                #if DEBUG
                                    .background(DebugViewMarker(name: "welcome-explore"))
                                #endif
                        } else { Text("Open a folder anytime with ⌘O").foregroundStyle(.tertiary) }
                    }
                    .font(.system(size: 11)).buttonStyle(.plain)
                }
                .controlSize(.small)
                .frame(maxWidth: 560)
                .padding(geometry.size.height < 650 ? 24 : 40)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
        }
        .background(Theme.canvas)
        #if DEBUG
            .background(DebugViewMarker(name: "welcome-checklist"))
        #endif
    }

    private var checkAgain: some View {
        Button("Check Again") { Task { await model.refreshAgents(force: true) } }
            .buttonStyle(WorkspaceButtonStyle(kind: .secondary)).disabled(model.isRefreshingAgents)
    }

    private var installationDetail: String {
        switch checklist.installation {
        case .complete: "\(agent.shortName) CLI found on your Mac."
        case .checking: "Looking for \(agent.shortName) on this Mac…"
        case .needsAttention: "Couldn't check the installation. Try again."
        default: "Install the \(agent.shortName) CLI, then check again."
        }
    }

    private var accountDetail: String {
        if let signIn, signIn.isPending || signIn.phase == .failed { return signIn.message ?? "" }
        if signIn?.phase == .succeeded { return status.account.map { "Signed in as \($0)." } ?? "Sign-in confirmed. \(agent.shortName) is ready." }
        switch checklist.account {
        case .complete: return status.account ?? "\(agent.shortName) is connected and ready."
        case .checking: return "Checking your connection…"
        case .blocked: return "Install \(agent.shortName) first."
        case .needsAttention:
            if case .unavailable(let reason) = status.readiness { return reason }
            return "Couldn't check your account. Try again."
        case .pending: return "\(usesAPIKey ? "Add your API key in Settings" : "Sign in through the official CLI"), then return here."
        }
    }

    private func setupRow<Action: View>(_ number: Int, title: String, detail: String,
                                       state: WelcomeChecklist.State, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 12) {
            Group {
                if state == .complete { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else if state == .checking { ProgressView().controlSize(.small) }
                else if state == .needsAttention { Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.attention) }
                else { Text(String(number)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
            }
            .font(.system(size: 21)).frame(width: 26, height: 26)
            .accessibilityLabel(state == .complete ? "Complete" : state == .checking ? "Checking" : "Step \(number)")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action().fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .accessibilityElement(children: .contain)
    }
}
