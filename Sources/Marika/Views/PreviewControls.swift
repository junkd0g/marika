import MarikaCore
import SwiftUI

struct PreviewStatusLabel: View {
    let preview: ProjectPreview?
    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(preview?.state == .failed ? Theme.attention : preview?.state == .running ? .green : .secondary)
    }
    private var title: String {
        switch preview?.state ?? .stopped {
        case .stopped: "Preview stopped"
        case .starting: "Preview starting…"
        case .running: "Preview running"
        case .failed: "Preview failed"
        }
    }
    private var symbol: String {
        switch preview?.state ?? .stopped {
        case .stopped: "stop.circle"
        case .starting: "clock"
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }
}

struct PreviewStatusButton: View {
    @Environment(AppModel.self) private var model
    let project: Project
    private var preview: ProjectPreview? { model.previews[project.id] }
    var body: some View {
        Menu {
            Button(preview?.isActive == true ? "Stop Preview" : "Start Preview") {
                if let preview, preview.isActive { preview.stop() }
                else { model.runPreview(for: project) }
            }
            if preview?.state == .running {
                Button("Open Preview") { model.openRunningPreview(for: project) }
            }
            Button("Preview Settings and Logs…") { model.openPreviewSettings(for: project) }
        } label: { PreviewStatusLabel(preview: preview).labelStyle(.iconOnly) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Project preview").help("Preview status, controls and logs (⇧⌘R)")
    }
}

struct PreviewLogView: View {
    let preview: ProjectPreview
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(preview.logs.isEmpty ? "Server output will appear here." : preview.logs)
                    .font(Theme.codeSmall).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("preview-log-end")
            }
            .padding(12).background(Theme.canvas)
            .onChange(of: preview.logs) { _, _ in proxy.scrollTo("preview-log-end", anchor: .bottom) }
        }
    }
}

extension AppModel {
    func openRunningPreview(for project: Project) {
        guard let preview = previews[project.id], preview.state == .running, let address = preview.address else { return }
        if selectedProject?.id != project.id { openProject(project) }
        browser(for: project).navigate(address.absoluteString)
        switchPanel(.browser)
    }
}
