import MarikaCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""

    private var visibleProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.workspace.projects.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.path.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                sidebarAction("New chat", symbol: "square.and.pencil") { model.newSessionInCurrentProject() }
                sidebarAction("Search project", symbol: "magnifyingglass") { model.showsProjectSearch = true }
                    .disabled(model.selectedProject == nil)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 22)

            HStack {
                Text("Projects").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
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
                            .background(model.selectedSession?.projectID == project.id ? Theme.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityAddTraits(model.selectedSession?.projectID == project.id ? [.isSelected] : [])
                            .contextMenu {
                                Button("Open Project") { model.openProject(project) }
                                Button("Show Agents") { model.openProject(project, tab: .agents) }
                                Button("Launch Agent…") { model.showAgents(for: project, launch: true) }
                                Divider()
                                Button("Reveal in Finder") { model.revealProject(project) }
                                Button("Remove from Marika", role: .destructive) { model.removeProject(project) }
                            }
                    }
                    if model.isReady, visibleProjects.isEmpty {
                        Text(model.workspace.projects.isEmpty ? "Open a folder to get started." : "No matching projects")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 16)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            UsageFooter()
        }
        .background(Theme.sidebar)
    }

    private func sidebarAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.ink)
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
