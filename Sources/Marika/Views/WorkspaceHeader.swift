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
            HStack(spacing: 8) {
                Button { model.showsProjectSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(model.showsProjectSidebar ? "Hide projects" : "Show projects")
                    .help(model.showsProjectSidebar ? "Hide projects" : "Show projects")
                navigation(showsLabels: geometry.size.width >= 935)
                Spacer(minLength: 4)
                if geometry.size.width >= 620 {
                    Button { model.showsCommandPalette = true } label: { Image(systemName: "command") }
                        .buttonStyle(.plain).help("Command palette (⌘K)")
                }
                Menu {
                    ForEach(ProjectPanel.allCases.filter { $0 != selection }, id: \.self) { panel in
                        Button("Split with " + panel.title) { model.setSplit(panel) }
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
                    Button(model.showsInspector ? "Hide Change Inspector" : "Show Change Inspector") { model.showsInspector.toggle() }
                    Button("Checkpoints…") { model.showExperience("Recovery", project: project) }
                    Button("Runtime Debugging…") { model.showExperience("Debug", project: project) }
                    Button("Plans and Artifacts…") { model.showExperience("Artifacts", project: project) }
                    Button("Terminal…") { model.openTerminal() }
                    Button("MCP Servers…") { model.openProjectSettings(project, section: "MCP") }
                    Button("Project Settings…") { model.openProjectSettings(project) }
                    Divider()
                    Button("Search Project…") { model.showsProjectSearch = true }
                    Button("Preview Settings and Logs…") { model.openPreviewSettings(for: project) }
                    Menu("Repositories") { repositoryActions }
                    Button(model.previews[project.id]?.isActive == true ? "Stop Preview" : "Run Preview") {
                        let preview = model.preview(for: project)
                        if preview.isActive { preview.stop() } else { model.runPreview(for: project) }
                    }
                    Button("Command Palette…") { model.showsCommandPalette = true }
                } label: { Image(systemName: "rectangle.split.2x1") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Split workspace and tools")
                if geometry.size.width >= 540 { Menu { repositoryActions } label: { Image(systemName: "folder.badge.plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Repositories · " + project.editorURL.lastPathComponent)
                }
                if geometry.size.width >= 460 { Button {
                    let preview = model.preview(for: project)
                    if preview.isActive { preview.stop() } else { model.runPreview(for: project) }
                } label: { Image(systemName: model.previews[project.id]?.isActive == true ? "stop.circle" : "play.circle") }
                    .buttonStyle(.plain).help("Run or stop preview (⇧⌘R)")
                }
                if selection == .conversation, geometry.size.width >= 540 {
                    Button { model.showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Toggle changes").help("Show or hide changes (⌥⌘I)")
                }
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
        .frame(height: 42)
        .background(Theme.canvas)
    }

    @ViewBuilder private var repositoryActions: some View {
        ForEach(project.repositoryURLs, id: \.path) { url in
            Button { model.selectRepository(url, project: project) } label: {
                Label(url.lastPathComponent, systemImage: url == project.editorURL ? "checkmark" : "folder")
            }
        }
        Divider()
        Button("Attach Repository…") { model.attachRepository(to: project) }
    }

    private func navigation(showsLabels: Bool) -> some View {
        let strip = tabStrip(showsLabels: showsLabels)
        .fixedSize()
        .padding(.vertical, 3)
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
                    .foregroundStyle(selected ? Theme.ink : Color.secondary)
                if showsLabel {
                    Text(tab.title).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                }
                if tab == .agents, activeAgents > 0 {
                    Text(String(activeAgents)).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.selection, in: Capsule())
                }
            }
            .padding(.horizontal, showsLabel ? 9 : 5)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.selection : hovered == tab ? Theme.surface : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? tab : nil }
        .help("\(tab.title) (⌘\(tab.shortcut))").accessibilityLabel(tab.title)
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
