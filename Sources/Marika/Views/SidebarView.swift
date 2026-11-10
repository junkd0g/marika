import MarikaCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var pendingSpaceDeletion: ProjectSpace?

    private var visibleProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.spaceProjects.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.path.localizedStandardContains(query)
        }
    }

    private var designSelected: Bool {
        model.selectedSpace.section == .projects && model.commandPanel == .design
    }

    var body: some View {
        GeometryReader { geometry in
            let reserved: CGFloat = model.rateLimits.isEmpty ? 556 : 582
            sidebar(spaceRows: max(1, min(4, Int((geometry.size.height - reserved) / 53))))
        }
    }

    private func sidebar(spaceRows: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.selectedSpace.symbol).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(model.selectedSpace.color.tint).frame(width: 40, height: 40)
                    .background(model.selectedSpace.color.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(model.selectedSpace.color.tint.opacity(0.16)) }
                Text(model.selectedSpace.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    SpaceMenuActions(space: model.selectedSpace) { pendingSpaceDeletion = $0 }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 22) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Space options")
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            VStack(spacing: 2) {
                spaceSection("Needs attention", symbol: "tray", section: .attention,
                    count: model.attentionItems.filter { model.project(id: $0.projectID)?.spaceID == model.selectedSpace.id }.count)
                spaceSection("Notes", symbol: "doc.text", section: .notes, count: model.selectedSpace.notes.filter { !$0.archived }.count)
                spaceSection("Tickets", symbol: "rectangle.3.group", section: .tickets, count: model.selectedSpace.tickets.filter { !$0.archived && $0.status != .done }.count)
                sidebarAction("Design", symbol: "square.on.circle", selected: designSelected) {
                    if let project = model.workspace.preferredProject(in: model.selectedSpace.id) {
                        model.openProject(project, tab: .design)
                    }
                }
                .disabled(model.spaceProjects.isEmpty)
                .accessibilityLabel("Design in " + model.selectedSpace.name)
                .help("Open the design canvas for this project (⌘G)")
                #if DEBUG
                    .background(DebugViewMarker(name: "sidebar-open-design"))
                #endif
                Divider().padding(.horizontal, 10).padding(.vertical, 7)
                sidebarAction("New chat", symbol: "square.and.pencil") { model.newSessionInCurrentProject() }
                sidebarAction("Search project", symbol: "magnifyingglass") { model.showsProjectSearch = true }
                    .disabled(model.selectedProject == nil)
            }
            .padding(.horizontal, 10).padding(.bottom, 20)

            HStack {
                Text("Projects").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(String(model.spaceProjects.count)).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                Spacer()
                Button { model.chooseProject() } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open a project (⌘O)")
                    .accessibilityLabel("Open Project")
            }
            .padding(.horizontal, 20).padding(.bottom, 9)

            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.tertiary)
                TextField("Filter projects", text: $searchText).textFieldStyle(.plain)
                    .accessibilityLabel("Find a project")
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(visibleProjects) { project in
                        Button { model.openProject(project) } label: { ProjectRow(project: project) }
                            .buttonStyle(.plain)
                            .background(model.selectedSpace.section == .projects && model.selectedSession?.projectID == project.id ? Theme.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityAddTraits(model.selectedSpace.section == .projects && model.selectedSession?.projectID == project.id ? [.isSelected] : [])
                            .contextMenu {
                                Button("Open Project") { model.openProject(project) }
                                Button("Show Agents") { model.openProject(project, tab: .agents) }
                                Button("Launch Agent…") { model.showAgents(for: project, launch: true) }
                                Menu("Move to Space") {
                                    ForEach(model.workspace.spaces.filter { $0.id != project.spaceID }) { space in
                                        Button { model.moveProject(project.id, toSpace: space.id) } label: { Label(space.name, systemImage: space.symbol) }
                                    }
                                    Divider()
                                    Button("New Space…") { model.showSpaceEditor(movingProjectID: project.id) }
                                }
                                Divider()
                                Button("Reveal in Finder") { model.revealProject(project) }
                                Button("Remove from Marika", role: .destructive) { model.removeProject(project) }
                            }
                    }
                    if model.isReady, visibleProjects.isEmpty {
                        Text(model.spaceProjects.isEmpty ? "No projects in this space yet." : "No matching projects")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 16)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            .frame(minHeight: 80)
            #if DEBUG
                .background(DebugViewMarker(name: "sidebar-project-list"))
            #endif
            SpaceSwitcher(visibleRows: spaceRows) { pendingSpaceDeletion = $0 }
            UsageFooter()
        }
        .background(alignment: .topLeading) {
            RadialGradient(colors: [model.selectedSpace.color.tint.opacity(0.10), .clear],
                center: .topLeading, startRadius: 0, endRadius: 220)
                .frame(height: 200).allowsHitTesting(false)
        }
        .background(Theme.sidebar)
        .onChange(of: model.selectedSpace.id) { _, _ in searchText = "" }
        .confirmationDialog("Delete “\(pendingSpaceDeletion?.name ?? "")”?", isPresented: Binding(
            get: { pendingSpaceDeletion != nil }, set: { if !$0 { pendingSpaceDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingSpaceDeletion) { space in
            if let destination = model.workspace.spaces.first(where: { $0.id != space.id }) {
                Button("Delete Space", role: .destructive) { model.deleteSpace(space.id, movingProjectsTo: destination.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { space in
            Text("Its projects, notes and tickets will move to “\(model.workspace.spaces.first(where: { $0.id != space.id })?.name ?? "another space")”. Your files and conversations are kept.")
        }
    }

    private func spaceSection(_ title: String, symbol: String, section: SpaceSection, count: Int) -> some View {
        Button { model.openSpaceSection(section) } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 16)
                Text(title)
                Spacer(minLength: 4)
                if count > 0 { Text(String(count)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary) }
            }.font(.system(size: 12.5)).padding(.horizontal, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
                .background(model.selectedSpace.section == section ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(title + " in " + model.selectedSpace.name)
            .accessibilityAddTraits(model.selectedSpace.section == section ? [.isSelected] : [])
            #if DEBUG
                .background(DebugViewMarker(name: "space-open-" + (section == .attention ? "attention" : section.rawValue.lowercased())))
            #endif
    }

    private func sidebarAction(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).foregroundStyle(Theme.ink)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct SpaceMenuActions: View {
    @Environment(AppModel.self) private var model
    let space: ProjectSpace
    let requestDeletion: (ProjectSpace) -> Void

    var body: some View {
        Button("Edit Space…") { model.showSpaceEditor(space.id) }
        Button("New Space…") { model.showSpaceEditor() }
        Divider()
        Button("Move Up") { model.reorderSpace(space.id, offset: -1) }
            .disabled(model.workspace.spaces.first?.id == space.id)
        Button("Move Down") { model.reorderSpace(space.id, offset: 1) }
            .disabled(model.workspace.spaces.last?.id == space.id)
        Divider()
        Button("Delete Space…", role: .destructive) { requestDeletion(space) }
            .disabled(model.workspace.spaces.count < 2)
    }
}

private struct SpaceSwitcher: View {
    @Environment(AppModel.self) private var model
    let visibleRows: Int
    let requestDeletion: (ProjectSpace) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Spaces").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(String(model.workspace.spaces.count)).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button { model.showSpaceEditor() } label: { Image(systemName: "plus") }
                    .buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true)).help("New space")
                    .accessibilityLabel("New space")
                    #if DEBUG
                        .background(DebugViewMarker(name: "space-create"))
                    #endif
            }.padding(.horizontal, 16)
            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    VStack(spacing: 5) {
                        ForEach(model.workspace.spaces) { space in
                            SpaceSwitchButton(space: space, requestDeletion: requestDeletion).id(space.id)
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 2)
                }.scrollIndicators(.automatic)
                    .frame(height: CGFloat(min(model.workspace.spaces.count, visibleRows)) * 53 - 1)
                    .onChange(of: model.selectedSpace.id, initial: true) { _, id in scroll.scrollTo(id, anchor: .center) }
            }
        }.padding(.top, 10).padding(.bottom, 12)
            .overlay(alignment: .top) { Divider().padding(.horizontal, 16) }
    }
}

private struct SpaceSwitchButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovered = false
    let space: ProjectSpace
    let requestDeletion: (ProjectSpace) -> Void

    private var selected: Bool { model.selectedSpace.id == space.id }
    private var projectCount: Int { model.workspace.projects(in: space.id).count }
    private var working: [SessionController] {
        let ids = Set(model.workspace.projects(in: space.id).map(\.id))
        return model.controllers.values.filter { ids.contains($0.meta.projectID) && $0.isBusy }
    }

    var body: some View {
        Button { model.selectSpace(space.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: space.symbol).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(space.color.tint).frame(width: 32, height: 32)
                    .background(space.color.tint.opacity(selected ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(space.name).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                    Text("\(projectCount) \(projectCount == 1 ? "project" : "projects")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if !working.isEmpty {
                    Circle().fill(working.contains { $0.phase == .waitingForUser } ? Theme.attention : .green)
                        .frame(width: 7, height: 7)
                }
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(space.color.tint)
                }
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 48)
            .background(selected ? space.color.tint.opacity(0.10) : hovered ? Theme.selection : .clear,
                in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? space.color.tint.opacity(0.22) : .clear) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.ink).onHover { hovered = $0 }
        .accessibilityLabel(space.name + " space")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(space.name + " · \(projectCount) projects" + (working.isEmpty ? "" : " · \(working.count) agents active"))
        .contextMenu { SpaceMenuActions(space: space, requestDeletion: requestDeletion) }
        #if DEBUG
            .background(DebugViewMarker(name: "space-switch-" + space.id.uuidString))
        #endif
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project

    private var active: [SessionController] {
        model.controllers.values.filter { $0.meta.projectID == project.id && $0.isBusy }
    }
    private var needsApproval: Bool { active.contains { $0.phase == .waitingForUser } }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 18)
            Text(project.name).font(.system(size: 12.5, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if !active.isEmpty {
                Circle().fill(needsApproval ? Theme.attention : Color.green).frame(width: 5, height: 5)
                Text(String(active.count)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 11)
        .contentShape(Rectangle()).help(project.path).accessibilityLabel(project.name)
        #if DEBUG
            .background(DebugViewMarker(name: "project-row-" + project.id.uuidString))
        #endif
    }
}

/// Plan usage, so hitting a limit is never a surprise.
private struct UsageFooter: View {
    @Environment(AppModel.self) private var model
    @State private var showsUsage = false

    private var usage: [(id: String, agent: AgentKind, window: RateLimitWindow, isExhausted: Bool)] {
        AgentKind.allCases.flatMap { agent -> [(id: String, agent: AgentKind, window: RateLimitWindow, isExhausted: Bool)] in
            guard let snapshot = model.rateLimits[agent] else { return [] }
            return snapshot.windows.map { ("\(agent.rawValue)-\($0.id)", agent, $0, snapshot.isExhausted) }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if !usage.isEmpty {
                Button { showsUsage.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                        Text("Usage")
                        Spacer(minLength: 4)
                        Text(usageSummary).monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .medium))
                    }
                    .font(.system(size: 11))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .popover(isPresented: $showsUsage, arrowEdge: .top) { usageDetails }
                .help("View plan usage and reset times")
            }
            HStack {
                Button { model.chooseProject() } label: {
                    Label("Open Project", systemImage: "folder.badge.plus")
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
        }
        .padding(14)
        .overlay(alignment: .top) { Divider() }
    }

    private var usageSummary: String {
        AgentKind.allCases.compactMap { agent -> String? in
            guard let highest = usage.filter({ $0.agent == agent }).map({ $0.window.utilization }).max() else { return nil }
            return "\(agent.shortName) \(Int((highest * 100).rounded()))%"
        }.joined(separator: " · ")
    }

    private var usageDetails: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Plan usage").font(.system(size: 14, weight: .semibold))
            ForEach(usage, id: \.id) { _, agent, window, isExhausted in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(agent.shortName + " · " + window.label)
                        Spacer()
                        Text("\(Int((window.utilization * 100).rounded()))%").monospacedDigit()
                    }
                    .font(.system(size: 12))
                    ProgressView(value: min(1, window.utilization))
                        .tint(isExhausted || window.utilization > 0.9 ? .red : window.utilization > 0.7 ? Theme.attention : .accentColor)
                        .controlSize(.small)
                    if let resets = window.resetsAt {
                        Text("Resets \(Format.reset(resets))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20).frame(width: 300)
    }
}
