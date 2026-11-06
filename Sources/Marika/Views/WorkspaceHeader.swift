import MarikaCore
import SwiftUI

struct WorkspaceHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let selection: AppModel.ProjectTab
    var activeAgents: Int
    var select: (AppModel.ProjectTab) -> Void
    var launchAgent: () -> Void
    @State private var hovered: AppModel.ProjectTab?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                navigation(showsLabels: geometry.size.width >= 935)
                Spacer(minLength: 4)
                if geometry.size.width >= 620 {
                    Button { model.showsCommandPalette = true } label: { Image(systemName: "command") }
                        .buttonStyle(.plain).help("Command palette (⌘K)")
                }
                Menu {
                    ForEach(ProjectPanel.allCases.filter { $0 != selection }, id: \.self) { panel in
                        Button("Split with " + panel.rawValue) { model.setSplit(panel) }
                    }
                    if model.layout(for: project.id).secondary != nil {
                        Divider()
                        Button(model.layout(for: project.id).stacked ? "Side by Side" : "Stack Vertically") {
                            let saved = model.layout(for: project.id)
                            model.setSplit(saved.secondary, stacked: !saved.stacked)
                        }
                        Button("Close Split") { model.setSplit(nil) }
                    }
                    Divider()
                    Button("Changes…") { model.switchPanel(.changes) }
                    Button("Checkpoints…") { model.showExperience("Recovery", project: project) }
                    Button("Runtime Debugging…") { model.showExperience("Debug", project: project) }
                    Button("Plans and Artifacts…") { model.showExperience("Artifacts", project: project) }
                    Button("Terminal…") { model.openTerminal() }
                    Button("MCP Servers…") { model.openProjectSettings(project, section: "MCP") }
                    Button("Project Settings…") { model.openProjectSettings(project) }
                    Divider()
                    Button("Search Project…") { model.showsProjectSearch = true }
                    Button("Preview Settings and Logs…") { model.openPreviewSettings(for: project) }
                    Button("Command Palette…") { model.showsCommandPalette = true }
                } label: { Image(systemName: "rectangle.split.2x1") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Split workspace and tools")
                Menu {
                    ForEach(project.repositoryURLs, id: \.path) { url in
                        Button { model.selectRepository(url, project: project) } label: {
                            Label(url.lastPathComponent, systemImage: url == project.editorURL ? "checkmark" : "folder")
                        }
                    }
                    Divider()
                    Button("Attach Repository…") { model.attachRepository(to: project) }
                } label: { Image(systemName: "folder.badge.plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Repositories · " + project.editorURL.lastPathComponent)
                Button {
                    let preview = model.preview(for: project)
                    if preview.isActive { preview.stop() } else { model.runPreview(for: project) }
                } label: { Image(systemName: model.previews[project.id]?.isActive == true ? "stop.circle" : "play.circle") }
                    .buttonStyle(.plain).help("Run or stop preview (⇧⌘R)")
                Button(action: launchAgent) {
                    if geometry.size.width >= 530 { Label("New Agent", systemImage: "plus") }
                    else { Image(systemName: "plus") }
                }
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("New Agent")
                .help("Launch an agent in \(project.name) (⇧⌘N)")
            }
            .padding(.horizontal, 16)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 48)
        .background(Theme.chrome)
    }

    private func navigation(showsLabels: Bool) -> some View {
        let strip = tabStrip(showsLabels: showsLabels)
        .fixedSize()
        .padding(3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline.opacity(0.5)) }
        #if DEBUG
            return strip.background(DebugViewMarker(name: "workspace-tabs"))
        #else
            return strip
        #endif
    }

    private func tabStrip(showsLabels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(AppModel.ProjectTab.allCases.filter { ![.changes, .terminal].contains($0) || $0 == selection }, id: \.self) { tab in
                tabButton(tab, showsLabel: showsLabels)
            }
        }
    }

    private func tabButton(_ tab: AppModel.ProjectTab, showsLabel: Bool) -> some View {
        let selected = selection == tab
        let button = Button { select(tab) } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                if showsLabel {
                    Text(tab.rawValue).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                }
                if tab == .agents, activeAgents > 0 {
                    Text(String(activeAgents)).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, showsLabel ? 9 : 6)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color(nsColor: .controlColor) : hovered == tab ? Theme.surface : .clear)
                    .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? tab : nil }
        .help("\(tab.rawValue) (⌘\(tab.shortcut))").accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        #if DEBUG
            return button.background(DebugViewMarker(name: "workspace-tab-" + tab.rawValue.lowercased()))
        #else
            return button
        #endif
    }
}

private extension AppModel.ProjectTab {
    var symbol: String {
        switch self {
        case .conversation: "bubble.left.and.bubble.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .browser: "globe"
        case .agents: "person.2"
        case .stats: "chart.bar.xaxis"
        case .changes: "arrow.triangle.branch"
        case .terminal: "terminal"
        case .api: "network"
        case .pipelines: "point.3.connected.trianglepath.dotted"
        }
    }
}
