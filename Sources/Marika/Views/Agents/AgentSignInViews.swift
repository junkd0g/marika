import MarikaCore
import SwiftUI

struct AgentSignInButton: View {
    @Environment(AppModel.self) private var model
    let agent: AgentKind
    var title = "Sign In…"
    var body: some View {
        Button(model.signIns[agent]?.isPending == true ? "Signing In…" : model.signIns[agent]?.phase == .failed ? "Retry Sign In…" : title) {
            model.signIn(agent)
        }
        .disabled(model.signIns[agent]?.isPending == true)
        .controlSize(.small)
    }
}

struct AgentSignInFeedback: View {
    @Environment(AppModel.self) private var model
    let agent: AgentKind
    var body: some View {
        if let flow = model.signIns[agent], flow.phase == .succeeded {
            Label("Sign-in confirmed.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(.green)
        } else if let flow = model.signIns[agent], flow.isPending || flow.phase == .failed {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 7) {
                    if flow.isPending { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention) }
                    Text(flow.message ?? "").fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button("Check Again") { Task { await model.refreshAgents(force: true) } }
                        .disabled(model.isRefreshingAgents)
                    if flow.isPending {
                        Button("Stop Waiting") { flow.stopWaiting() }
                            .help("Stops checking in Marika. The sign-in window in Terminal stays open.")
                    }
                }
                .buttonStyle(.link).controlSize(.small)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
