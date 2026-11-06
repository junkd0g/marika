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
        List(selection: Binding(
            get: { model.selectedSession?.projectID },
            set: { id in
                if let id, let project = model.project(id: id) {
                    Task { @MainActor in model.openProject(project) }
                }
            }
        )) {
            Section("Projects") {
                ForEach(visibleProjects) { project in
                    Button { model.openProject(project) } label: {
                        ProjectRow(project: project)
                    }
                        .buttonStyle(.plain)
                        .tag(project.id)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button("Open Project") { model.openProject(project) }
                            Button("Show Agents") { model.openProject(project, tab: .agents) }
                            Button("Launch Agent…") { model.showAgents(for: project, launch: true) }
                            Divider()
                            Button("Reveal in Finder") { model.revealProject(project) }
                            Button("Remove from Marika", role: .destructive) { model.removeProject(project) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Find a project")
        .overlay {
            if model.isReady, visibleProjects.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.workspace.projects.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
                        .font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                    Text(model.workspace.projects.isEmpty ? "Your projects live here" : "No matching projects")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if !searchText.isEmpty {
                        Button("Clear Search") { searchText = "" }.buttonStyle(.link)
                    }
                }
                .padding()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { UsageFooter() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.chooseProject() } label: {
                    Label("Open Project", systemImage: "plus")
                }
                .help("Open a project (⌘O)")
            }
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: Project

    private var active: [SessionController] {
        model.controllers.values.filter { $0.meta.projectID == project.id && $0.isBusy }
    }
    private var needsApproval: Bool { active.contains { $0.phase == .waitingForUser } }
    private var tint: Color {
        let colors: [Color] = [.blue, .purple, .teal, .orange, .pink]
        let index = project.id.uuidString.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[index]
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(project.url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !active.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(needsApproval ? Theme.attention : tint).frame(width: 5, height: 5)
                    Text(String(active.count)).monospacedDigit()
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .help(needsApproval ? "An agent needs your approval" : "\(active.count) agents working")
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(project.path)
        .accessibilityLabel(project.name)
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
