import AppKit
import MarikaCore
import SwiftUI

/// The chat navigator stays inside the project; the app sidebar remains a list of projects.
struct ProjectChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.conversationIsVisible) private var isVisible
    let project: Project
    let selection: SessionMeta
    @State private var query = ""
    @State private var showsPeople = true
    @State private var showsJobs = false
    @State private var renameTarget: UUID?
    @State private var renameText = ""

    private var agents: [SessionMeta] {
        model.sessions(in: project).filter { $0.agentTask != nil }
    }
    private var filteredAgents: [SessionMeta] {
        agents.filter { query.isEmpty || ($0.title + " " + ProjectChat.handle(for: $0)).localizedCaseInsensitiveContains(query) }
    }
    private var mainConversation: SessionMeta? { model.workspace.conversation(for: project.id) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if showsPeople && !agents.isEmpty && geometry.size.width >= 700 {
                    navigator.frame(width: 224)
                    Divider()
                }
                VStack(spacing: 0) {
                    header(canShowPeople: !agents.isEmpty && geometry.size.width >= 700)
                    Divider()
                    if showsJobs {
                        ProjectJobsView(project: project, onOpenChat: { showsJobs = false })
                    } else {
                        SessionContainer(meta: selection).id(selection.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: agents.map(\.id)) {
            for agent in agents { await model.open(agent.id) }
            markReadIfVisible()
        }
        .task(id: selection.id) {
            await model.open(selection.id)
            markReadIfVisible()
        }
        .onAppear { updateVisibility() }
        .onDisappear { model.visibleChatSessionIDs.remove(selection.id) }
        .onChange(of: isVisible) { _, _ in updateVisibility() }
        .onChange(of: showsJobs) { _, _ in updateVisibility() }
        .onChange(of: selection.id) { old, _ in
            model.visibleChatSessionIDs.remove(old)
            showsJobs = false
            updateVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in markReadIfVisible() }
        .alert("Rename agent", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Agent name", text: $renameText)
            Button("Save") {
                if let id = renameTarget { model.rename(id, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: { Text("Give this agent a name for your project. Its @mention stays the same.") }
        #if DEBUG
            .background(DebugViewMarker(name: "project-chat"))
        #endif
    }

    private var navigator: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.secondary)
                Text("Project chat").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button { model.agentLaunchProjectID = project.id } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("Start a conversation with a new agent")
            }
            .padding(16)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Find an agent", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Find a project agent")
            }
            .font(.system(size: 12))
            .padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    sectionLabel("CHANNELS")
                    if let conversation = mainConversation {
                        channelRow(conversation)
                    }
                    HStack {
                        sectionLabel("AGENTS")
                        Spacer()
                        Text("\(agents.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 16).padding(.trailing, 12)
                    ForEach(filteredAgents) { agent in
                        agentRow(agent)
                    }
                    if filteredAgents.isEmpty {
                        Text(agents.isEmpty ? "Start an agent to give it a task, ask questions, and follow up here." : "No matching agents")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineSpacing(3).padding(.horizontal, 12).padding(.top, 4)
                    }
                    sectionLabel("AUTOMATIONS").padding(.top, 16)
                    Button { showsJobs = true } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "calendar.badge.clock")
                            Text("Scheduled jobs")
                            Spacer(minLength: 0)
                            Text("\(project.tools?.schedules.count ?? 0)").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12)).padding(10).contentShape(Rectangle())
                        .background(showsJobs ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.bottom, 16)
            }
            Spacer(minLength: 0)
            Divider()
            Button { model.agentLaunchProjectID = project.id } label: {
                Label("New agent", systemImage: "plus.bubble").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.ink)
            .padding(4)
        }
        .background(Theme.chrome)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(0.9).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.bottom, 4)
    }

    private func channelRow(_ conversation: SessionMeta) -> some View {
        Button { showsJobs = false; model.openAgentChat(conversation.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: "number").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("project").font(.system(size: 12, weight: .semibold))
                    Text("Your main conversation").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                unreadBadge(conversation.id)
            }
            .padding(8).contentShape(Rectangle())
            .background(selection.id == conversation.id && !showsJobs ? Theme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Project channel")
        #if DEBUG
            .background(DebugViewMarker(name: "chat-channel-project"))
        #endif
    }

    private func agentRow(_ agent: SessionMeta) -> some View {
        let controller = model.controllers[agent.id]
        let presence = ChatPresence(meta: agent, controller: controller)
        return Button { showsJobs = false; model.openAgentChat(agent.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                ChatAvatar(agent: agent.agent, color: presence.color).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(agent.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        unreadBadge(agent.id)
                    }
                    Text(presence.preview ?? "Send a message")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 4) {
                        Text(agent.agent.shortName)
                        Text("·")
                        Text(presence.label)
                    }
                    .font(.system(size: 9.5)).foregroundStyle(presence.color)
                }
            }
            .padding(8).contentShape(Rectangle())
            .background(selection.id == agent.id && !showsJobs ? Theme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("@" + ProjectChat.handle(for: agent))
        .accessibilityLabel("Chat with \(agent.title), \(presence.label)")
        .contextMenu {
            Button("Rename agent…") { renameText = agent.title; renameTarget = agent.id }
            Button("Copy @mention") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("@" + ProjectChat.handle(for: agent), forType: .string)
            }
            Button("Open chat") { showsJobs = false; model.openAgentChat(agent.id) }
            Button("Manage agents") { model.showAgents(for: project) }
        }
        #if DEBUG
            .background(DebugViewMarker(name: "chat-agent-" + agent.id.uuidString))
        #endif
    }

    @ViewBuilder private func unreadBadge(_ id: UUID) -> some View {
        let unread = model.chatUnreadCount(id)
        if unread > 0 {
            Text(unread > 99 ? "99+" : String(unread)).font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.accentColor, in: Capsule()).accessibilityLabel("\(unread) unread replies")
        }
    }

    private func header(canShowPeople: Bool) -> some View {
        HStack(spacing: 12) {
            if canShowPeople {
                Button { showsPeople.toggle() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Show or hide project chats")
            }
            if showsJobs {
                Label("Scheduled jobs", systemImage: "calendar.badge.clock").font(.system(size: 13, weight: .semibold))
            } else {
                let presence = ChatPresence(meta: selection, controller: model.controllers[selection.id])
                if selection.agentTask != nil {
                    ChatAvatar(agent: selection.agent, color: presence.color)
                } else {
                    Image(systemName: "bubble.left").font(.system(size: 14, weight: .regular)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.agentTask == nil ? (model.controllers[selection.id]?.hasStarted == true ? selection.title : "New chat") : selection.title)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(selection.agentTask == nil ? selection.agent.shortName : "@\(ProjectChat.handle(for: selection)) · \(presence.label)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                destinationMenu
            }
            Spacer(minLength: 0)
            Button { model.showsChatHistorySearch = true } label: { Image(systemName: "text.magnifyingglass") }
                .buttonStyle(.plain).help("Search chat history (⇧⌘H)").accessibilityLabel("Search chat history")
                #if DEBUG
                    .background(DebugViewMarker(name: "chat-open-history-search"))
                #endif
            Button { showsJobs.toggle() } label: { Image(systemName: showsJobs ? "bubble.left.and.bubble.right" : "calendar.badge.clock") }
                .buttonStyle(.plain).help(showsJobs ? "Return to chat" : "Scheduled jobs")
                #if DEBUG
                    .background(DebugViewMarker(name: "chat-open-jobs"))
                #endif
            if selection.agentTask != nil {
                Button { renameText = selection.title; renameTarget = selection.id } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).help("Rename agent").accessibilityLabel("Rename agent")
                Button { Task { await model.openAgentReview(selection.id) } } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(.plain).help("Review this agent's changes")
                    .disabled(selection.agentTask?.workspace == nil || selection.agentTask?.workspace?.status == .discarded)
            }
            Button { model.agentLaunchProjectID = project.id } label: { Image(systemName: "person.badge.plus") }
                .buttonStyle(.plain).help("New agent")
        }
        .padding(.horizontal, 18).frame(height: 46)
        .background(Theme.canvas)
    }

    private var destinationMenu: some View {
        Menu {
            if let conversation = mainConversation {
                Button("# project") { model.openAgentChat(conversation.id) }
            }
            Divider()
            ForEach(agents) { agent in
                Button(agent.title + " · " + agent.agent.shortName) { model.openAgentChat(agent.id) }
            }
            Divider()
            let history = model.sessions(in: project).filter { $0.agentTask == nil && $0.id != mainConversation?.id }
            if !history.isEmpty {
                Menu("Previous conversations") {
                    ForEach(history) { conversation in
                        Button(conversation.title) { model.openAgentChat(conversation.id) }
                    }
                }
            }
            Button("New agent…") { model.agentLaunchProjectID = project.id }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Switch project channel or agent")
    }

    private func markReadIfVisible() {
        if isVisible && !showsJobs && NSApp.isActive { model.markChatRead(selection.id) }
    }

    private func updateVisibility() {
        if isVisible && !showsJobs { model.visibleChatSessionIDs.insert(selection.id) }
        else { model.visibleChatSessionIDs.remove(selection.id) }
        markReadIfVisible()
    }
}

@MainActor private struct ChatPresence {
    var label: String
    var color: Color
    var preview: String?

    init(meta: SessionMeta, controller: SessionController?) {
        let presentation = AgentTaskPresentation(meta: controller?.meta ?? meta, items: controller?.items ?? [],
                                                  phase: controller?.phase ?? .idle, approval: controller?.pendingApproval, activity: controller?.activity)
        label = presentation.state.rawValue
        color = presentation.state.color
        preview = presentation.preview
    }
}

private struct ChatAvatar: View {
    let agent: AgentKind
    let color: Color

    var body: some View {
        Text(agent == .codex ? "Co" : "Cl").font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(agent == .codex ? Color.teal : Color.purple)
            .frame(width: 30, height: 30)
            .background((agent == .codex ? Color.teal : Color.purple).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(color).frame(width: 7, height: 7).overlay(Circle().stroke(Theme.canvas, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .accessibilityHidden(true)
    }
}
