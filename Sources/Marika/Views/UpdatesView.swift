import AppKit
import MarikaCore
import SwiftUI

struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @State private var showsInstalledNotes = false

    private var updates: AppUpdates { model.updates }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.app").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Marika").font(.system(size: 21, weight: .semibold))
                    Text("Version \(updates.installedVersion) · Build \(updates.installedBuild)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Check for Updates") { Task { await updates.check() } }
                    .disabled(updates.status == .checking)
                    #if DEBUG
                        .background(DebugViewMarker(name: "updates-check"))
                    #endif
            }.padding(22)
            HStack(alignment: .top, spacing: 10) {
                if updates.status == .checking { ProgressView().controlSize(.small) }
                else { Image(systemName: statusSymbol).foregroundStyle(updates.status == .failed ? Theme.attention : .secondary) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusTitle).font(.system(size: 13, weight: .medium))
                    if let error = updates.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.attention) }
                    if let checked = updates.lastChecked {
                        Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if updates.status == .available, let release = updates.release {
                    if updates.supportsInstallation {
                        Button("Download and Install…") { updates.install() }
                            .buttonStyle(.borderedProminent).disabled(!model.canInstallAppUpdate)
                            .help(model.canInstallAppUpdate ? "Review and install the signed update" : "Finish active agents and save editor changes first")
                    } else {
                        Link("View Release", destination: release.url)
                    }
                }
            }.padding(.horizontal, 22).padding(.bottom, 20)
            Divider()
            HStack {
                Text(showsInstalledNotes || updates.release == nil ? "In this version" : "Release notes")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if updates.release != nil {
                    Toggle("Installed version", isOn: $showsInstalledNotes).toggleStyle(.button).controlSize(.small)
                }
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)
            ScrollView {
                MarkdownView(text: showsInstalledNotes ? marikaReleaseNotes : updates.release?.notes ?? marikaReleaseNotes,
                             onOpenLink: { $0.scheme == "https" ? .systemAction : .discarded })
                    .padding(.horizontal, 22).padding(.bottom, 22)
            }
            Divider()
            HStack {
                Text("Updates are checked when you ask.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Link("All releases", destination: ReleaseChecker.repositoryURL.appendingPathComponent("releases"))
                    .font(.system(size: 11))
            }.padding(16)
        }
        .background(Theme.canvas)
        #if DEBUG
            .background(DebugViewMarker(name: "app-updates"))
        #endif
    }

    private var statusTitle: String {
        switch updates.status {
        case .idle: "Check for a newer version of Marika."
        case .checking: "Checking for updates…"
        case .current: "You're up to date."
        case .available: "Marika \(updates.release?.version.display ?? "") is available."
        case .noReleases: "No releases have been published yet."
        case .failed: "Couldn't check for updates."
        }
    }

    private var statusSymbol: String {
        switch updates.status {
        case .current: "checkmark.circle"
        case .available: "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        default: "info.circle"
        }
    }
}
