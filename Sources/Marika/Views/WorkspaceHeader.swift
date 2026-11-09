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
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { model.showsProjectSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(model.showsProjectSidebar ? "Hide projects" : "Show projects")
                        .help(model.showsProjectSidebar ? "Hide projects" : "Show projects")
                    navigation
                    newViewMenu
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
                        Button("Deliverables, Plans and Artifacts…") { model.showExperience("Artifacts", project: project) }
                        Button("Terminal…") { model.openTerminal() }
                        Button("Connections…") { model.openProjectSettings(project, section: "MCP") }
                        Button("Task Queue…") { model.taskQueueProjectID = project.id }
                        Button("Task Activity…") { model.taskActivityProjectID = project.id }
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
                    if geometry.size.width >= 460 {
                        PreviewStatusButton(project: project)
                    }
                    if selection == .conversation, geometry.size.width >= 540 {
                        Button { model.showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Toggle changes").help("Show or hide changes (⌥⌘I)")
                    }
                    Button(action: launchAgent) {
                        if geometry.size.width >= 530 { Label("New Agent", systemImage: "person.badge.plus") }
                        else { Image(systemName: "person.badge.plus") }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("New Agent")
                    .help("Launch an agent in \(project.name) (⇧⌘N)")
                }
                .padding(.horizontal, 16)
                .frame(width: geometry.size.width, height: 42)
            }
        }
        .frame(height: 42)
        .background(Theme.canvas)
        #if DEBUG
            .background(DebugViewMarker(name: "workspace-header"))
        #endif
    }

    private var newViewMenu: some View {
        Menu {
            ForEach(ProjectPanel.allCases.filter { $0 != .conversation }, id: \.self) { tab in
                Button { select(tab) } label: {
                    Label("\(tab.title)  ⌘\(tab.shortcut)", systemImage: tab.symbol)
                }
            }
        } label: { Image(systemName: "plus").frame(width: 24, height: 30) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Open a view").help("Open a project view. Drag an open tab to split the workspace.")
        #if DEBUG
            .background(DebugViewMarker(name: "workspace-new-view"))
        #endif
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

    private var openTabs: [ProjectPanel] { model.layout(for: project.id).openTabs }

    private var navigation: some View {
        let strip = HStack(spacing: 4) {
            tabButton(.conversation).fixedSize(horizontal: true, vertical: false)
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(openTabs.filter { $0 != .conversation }, id: \.self) { tab in tabButton(tab).id(tab) }
                            Spacer(minLength: 40).frame(height: 30)
                        }
                        .frame(minWidth: geometry.size.width, alignment: .leading).padding(.vertical, 3)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selection, initial: true) { _, tab in
                        if tab != .conversation { scroll.scrollTo(tab, anchor: .center) }
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        #if DEBUG
            return strip.background(DebugViewMarker(name: "workspace-tabs"))
        #else
            return strip
        #endif
    }

    private func tabButton(_ tab: AppModel.ProjectTab) -> some View {
        let selected = selection == tab
        let button = HStack(spacing: 4) {
            Button { select(tab) } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab.symbol).font(.system(size: 12, weight: .medium))
                    Text(tab.title).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    if tab == .agents, activeAgents > 0 {
                        Text(String(activeAgents)).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .padding(.horizontal, 4).padding(.vertical, 1).background(Theme.selection, in: Capsule())
                    }
                }
                .foregroundStyle(selected ? Theme.ink : .secondary)
                .frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(MiddleClickTarget { select(tab) })
            .onDrag { WorkspaceTabDrag(projectID: project.id, panel: tab).itemProvider() }
            .help("\(tab.title) (⌘\(tab.shortcut)). Middle-click to open; drag to a workspace edge to split.")
            .accessibilityLabel(tab.title + " tab")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            if tab != .conversation {
                Button { model.closeProjectTab(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        .frame(width: 20, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .opacity(selected || hovered == tab ? 1 : 0.5)
                .help("Close \(tab.title) tab").accessibilityLabel("Close \(tab.title) tab")
                #if DEBUG
                    .background(DebugViewMarker(name: "workspace-close-" + tab.rawValue.lowercased()))
                #endif
            }
        }
        .padding(.leading, 10).padding(.trailing, tab == .conversation ? 10 : 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selection : hovered == tab ? Theme.surface : .clear))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.hairline : .clear) }
        .onHover { hovered = $0 ? tab : nil }
        .contextMenu {
            ForEach(ProjectSplitEdge.allCases, id: \.self) { edge in
                Button("Split \(tab.title) \(edge.rawValue)") {
                    model.splitProjectTab(WorkspaceTabDrag(projectID: project.id, panel: tab), at: edge)
                }
                .disabled(openTabs.allSatisfy { $0 == tab })
            }
            Divider()
            Button("Close Tab") { model.closeProjectTab(tab) }.disabled(tab == .conversation)
            Button("Close Other Tabs") { model.closeOtherProjectTabs(keeping: tab) }.disabled(openTabs.count < 2)
            Divider()
            Button("Move Tab Left") { model.moveProjectTab(tab, offset: -1) }
                .disabled(tab == .conversation || openTabs.firstIndex(of: tab) == 1)
            Button("Move Tab Right") { model.moveProjectTab(tab, offset: 1) }
                .disabled(tab == .conversation || openTabs.last == tab)
        }
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
        case .research: "books.vertical"
        case .pipelines: "point.3.connected.trianglepath.dotted"
        }
    }
}
