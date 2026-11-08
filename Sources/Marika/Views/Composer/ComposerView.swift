import AppKit
import MarikaCore
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.conversationIsVisible) private var conversationIsVisible
    @Bindable var session: SessionController

    @State private var highlightedCommand = 0
    @State private var isConfirmingBypass = false
    @State private var isDropTargeted = false
    @State private var isRoutingMessage = false
    @State private var routingError: String?

    private var capabilities: AgentCapabilities? { model.capabilities[session.meta.agent] }
    private var selectedModel: ModelOption? {
        let models = capabilities?.models ?? []
        return models.first { $0.id == (session.meta.model ?? session.reportedModel) }
            ?? models.first(where: \.isDefault) ?? models.first
    }
    private var trimmedDraft: String { session.draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        (!trimmedDraft.isEmpty || !session.draftImages.isEmpty) && (isAgentAvailable || trimmedDraft.hasPrefix("@")) && !isRoutingMessage
            && (session.pendingApproval == nil || !trimmedDraft.isEmpty)
    }

    /// An agent that isn't set up can't answer, and a message sent to one would lock the session
    /// to it. Unknown status counts as available so a slow check never blocks typing.
    private var isAgentAvailable: Bool {
        if session.meta.agentTask?.workspace?.status == .discarded { return false }
        return model.canMessage(session.meta.agent)
    }

    private var placeholder: String {
        if session.pendingApproval != nil { return "Or tell the agent what to do instead…" }
        if session.isBusy { return "Add to this turn…" }
        return session.hasStarted ? "Ask a follow-up, or @mention an agent…" : "Ask anything, or describe a task…"
    }

    /// Commands matching the `/word` being typed.
    private var commandMatches: [SlashCommand] {
        guard session.draft.hasPrefix("/"), !session.draft.contains(" "), !session.draft.contains("\n") else { return [] }
        let prefix = session.draft.dropFirst().lowercased()
        let commands = capabilities?.commands ?? []
        return Array(commands.filter { $0.name.lowercased().hasPrefix(prefix) }.prefix(7))
    }

    private var mentionMatches: [SessionMeta] {
        guard session.draft.hasPrefix("@"), !session.draft.contains(where: { $0.isWhitespace }) else { return [] }
        return Array(ProjectChat.agents(in: session.meta.projectID, sessions: model.workspace.sessions,
                                       matching: String(session.draft.dropFirst())).prefix(6))
    }

    var body: some View {
        VStack(spacing: 8) {
            editorPanel
            HStack(spacing: 4) {
                Text("Return to send")
                Text("·")
                Text("⇧ Return for a new line")
                Spacer(minLength: 0)
                if session.meta.hasDraft {
                    Image(systemName: "pencil.line")
                    Text("Draft")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .onChange(of: session.draft) { _, _ in highlightedCommand = 0; routingError = nil }
        .confirmationDialog(
            "Run without any approval checks?", isPresented: $isConfirmingBypass, titleVisibility: .visible
        ) {
            Button("Bypass Checks", role: .destructive) { setMode(.bypass) }
        } message: {
            Text("The agent will run any command and change any file without asking. Only use this in a disposable environment.")
        }
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let queued = session.meta.queuedAgent {
                HStack(alignment: .firstTextBaseline) {
                    Label("\(queued.shortName) takes over after this turn.", systemImage: "clock")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Cancel switch") { session.cancelAgentSwitch() }
                }.font(.system(size: 12))
            }
            if let running = session.runningMode, running != session.meta.mode {
                pendingModeNotice(running: running)
            }
            if !commandMatches.isEmpty {
                commandList
            }
            if !mentionMatches.isEmpty { mentionList }
            if let routingError {
                Text(routingError).font(.system(size: 11)).foregroundStyle(Theme.attention).textSelection(.enabled)
            }
            if !session.draftImages.isEmpty {
                attachments
                if session.pendingApproval != nil {
                    Text("Images stay in your draft while you answer this approval.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            ComposerTextView(
                text: $session.draft, placeholder: placeholder,
                isActive: conversationIsVisible && !isRoutingMessage,
                focusToken: [session.id, model.composerFocusRequest],
                onSubmit: { submit() }, onPasteImage: { data in addImage(data: data) }, onKey: { key in handleKey(key) }
            )
            .fixedSize(horizontal: false, vertical: true)

            controls
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline) }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    /// The row gives up detail as the column narrows, so it can never force the window wider.
    /// A running Codex turn can't change policy, so the menu's new value isn't in force yet.
    private func pendingModeNotice(running: ApprovalMode) -> some View {
        let agent = session.meta.agent
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock").foregroundStyle(Theme.attention)
            Text("This turn keeps running as \(running.title(for: agent)). \(session.meta.mode.title(for: agent)) starts with your next message.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Stop Now") { session.interrupt() }
                .controlSize(.small)
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(.full)
            controlRow(.compact)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    attachmentButton
                    agentMenu
                    Spacer(minLength: 4)
                    sendControls
                }
                if !(capabilities?.models ?? []).isEmpty {
                    HStack { modelMenu; Spacer(minLength: 0) }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        effortMenu
                        speedMenu
                        Spacer(minLength: 4)
                        modeMenu(showsTitle: false)
                        if let context = session.context { ContextRing(usage: context) }
                    }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) { effortMenu; speedMenu; Spacer(minLength: 0) }
                        HStack(spacing: 8) {
                            modeMenu(showsTitle: true)
                            Spacer(minLength: 0)
                            if let context = session.context { ContextRing(usage: context) }
                        }
                    }
                }
            }
        }
        .font(.system(size: 12))
    }

    private enum Density {
        case full
        case compact
    }

    private func controlRow(_ density: Density) -> some View {
        HStack(spacing: 8) {
            attachmentButton
            agentMenu
            modelMenu
            effortMenu
            speedMenu
            modeMenu(showsTitle: density == .full)

            Spacer(minLength: 6)

            if let context = session.context {
                ContextRing(usage: context).padding(.trailing, 6)
            }
            sendControls
        }
    }

    private var attachmentButton: some View {
        Button(action: chooseImages) { Image(systemName: "plus").frame(width: 22, height: 24) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Attach images").help("Attach images")
    }

    @ViewBuilder
    private var agentMenu: some View {
        Group {
            Menu {
                Section(session.isBusy ? "Switch after this turn" : "Provider") {
                    ForEach(AgentKind.allCases) { agent in
                        Button {
                            model.setAgent(agent, for: session.id)
                        } label: {
                            if agent == (session.meta.queuedAgent ?? session.meta.agent) {
                                Label(agent.displayName, systemImage: "checkmark")
                            } else {
                                Text(agent.displayName)
                            }
                        }
                    }
                }
                if session.meta.queuedAgent != nil {
                    Divider()
                    Button("Cancel queued switch") { session.cancelAgentSwitch() }
                }
            } label: {
                Text(session.meta.agent.shortName)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.meta.agentTask?.workspace?.status == .discarded)
            .accessibilityLabel("Provider: " + session.meta.agent.shortName)
            .help(session.isBusy ? "Queue a provider switch after this turn" : "Switch provider for the next message; conversation and workspace are kept")
        }
    }

    @ViewBuilder
    private var modelMenu: some View {
        let models = capabilities?.models ?? []
        if !models.isEmpty {
            Menu {
                Button {
                    setModel(nil)
                } label: {
                    menuLabel("Default", isSelected: session.meta.model == nil)
                }
                Divider()
                ForEach(models.filter { $0.id != "default" }) { option in
                    Button {
                        setModel(option.id)
                    } label: {
                        menuLabel(option.name, isSelected: session.meta.model == option.id)
                    }
                }
            } label: {
                Text(selectedModel?.name ?? "Default model").lineLimit(1).truncationMode(.middle).frame(maxWidth: 155)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model for " + session.meta.agent.shortName)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var effortMenu: some View {
        let efforts = selectedModel?.efforts ?? []
        if !efforts.isEmpty {
            Menu {
                Button {
                    setEffort(nil)
                } label: {
                    menuLabel("Default", isSelected: session.meta.effort == nil)
                }
                Divider()
                ForEach(efforts, id: \.self) { effort in
                    Button {
                        setEffort(effort)
                    } label: {
                        menuLabel(Format.effort(effort), isSelected: session.meta.effort == effort)
                    }
                }
            } label: {
                Text((session.meta.effort ?? selectedModel?.defaultEffort).map(Format.effort) ?? "Effort")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("How hard the model thinks. Applies from your next message.")
        }
    }

    @ViewBuilder
    private var speedMenu: some View {
        if session.meta.agent == .codex {
            let options = selectedModel?.speedOptions ?? [.standard]
            let label = session.meta.serviceTier.map { tier in
                options.first { $0.id == ServiceTierOption.requestValue(tier) }?.name ?? ServiceTierOption.displayName(tier)
            } ?? "Default speed"
            let menu = Menu {
                Section("Speed") {
                    Button { setServiceTier(nil) } label: { menuLabel("Default speed", isSelected: session.meta.serviceTier == nil) }
                    Divider()
                    ForEach(options) { option in
                        Button { setServiceTier(option.id) } label: {
                            menuLabel(option.name, isSelected: session.meta.serviceTier.map(ServiceTierOption.requestValue) == option.id)
                        }
                        .help(option.detail)
                    }
                }
                Text("Applies to the next turn. Faster tiers may use more of your plan.")
            } label: {
                Label(label, systemImage: "bolt")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Speed: " + label)
            .help("Speed is separate from reasoning effort. Default follows your Codex settings; changes apply to the next turn.")
            #if DEBUG
                menu.background(DebugViewMarker(name: "composer-speed"))
            #else
                menu
            #endif
        }
    }

    private func modeMenu(showsTitle: Bool) -> some View {
        let agent = session.meta.agent
        return Menu {
            ForEach(ApprovalMode.allCases) { mode in
                Button {
                    if mode == .bypass { isConfirmingBypass = true } else { setMode(mode) }
                } label: {
                    menuLabel(mode.title(for: agent), isSelected: session.meta.mode == mode)
                }
                .help(mode.summary(for: agent))
            }
        } label: {
            Group {
                if showsTitle {
                    Label(session.meta.mode.title(for: agent), systemImage: session.meta.mode.symbol)
                } else {
                    Image(systemName: session.meta.mode.symbol)
                }
            }
            .foregroundStyle(session.meta.mode == .bypass ? Color.red : .primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(session.meta.mode.summary(for: agent))
    }

    @ViewBuilder
    private var sendControls: some View {
        if session.isBusy {
            Button {
                session.interrupt()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Stop (⌘.)")
        }
        if !session.isBusy || canSend {
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(canSend ? Theme.ink : Color.secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (Return)")
        }
    }

    @ViewBuilder
    private func menuLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: Slash commands

    private var commandList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commandMatches.enumerated()), id: \.element.id) { index, command in
                Button {
                    accept(command)
                } label: {
                    HStack(spacing: 10) {
                        Text("/\(command.name)")
                            .font(Theme.code)
                        Text(command.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        index == highlightedCommand ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func accept(_ command: SlashCommand) {
        session.draft = "/\(command.name) "
    }

    private var mentionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MESSAGE AN AGENT").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).padding(6)
            ForEach(Array(mentionMatches.enumerated()), id: \.element.id) { index, agent in
                Button { acceptMention(agent) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "at").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(ProjectChat.handle(for: agent)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(agent.agent.shortName).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(8).contentShape(Rectangle())
                    .background(index == highlightedCommand ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
        }
    }

    private func acceptMention(_ agent: SessionMeta) {
        session.draft = "@" + ProjectChat.handle(for: agent) + " "
    }

    private func handleKey(_ key: ComposerTextView.Key) -> Bool {
        let mentions = mentionMatches
        if !mentions.isEmpty {
            switch key {
            case .up: highlightedCommand = max(0, highlightedCommand - 1)
            case .down: highlightedCommand = min(mentions.count - 1, highlightedCommand + 1)
            case .tab: acceptMention(mentions[min(highlightedCommand, mentions.count - 1)])
            case .escape: session.draft = ""
            }
            return true
        }
        let matches = commandMatches
        if key == .escape {
            // Handled here because a focused text view would otherwise offer word completions.
            if !matches.isEmpty {
                session.draft = ""
            } else if let approval = session.pendingApproval {
                session.answer(approval, with: .deny)
            } else if session.isBusy {
                session.interrupt()
            }
            return true
        }
        guard !matches.isEmpty else { return false }
        switch key {
        case .up:
            highlightedCommand = max(0, highlightedCommand - 1)
        case .down:
            highlightedCommand = min(matches.count - 1, highlightedCommand + 1)
        case .tab:
            accept(matches[min(highlightedCommand, matches.count - 1)])
        case .escape:
            break
        }
        return true
    }

    // MARK: Actions

    private func submit() {
        if !mentionMatches.isEmpty {
            acceptMention(mentionMatches[min(highlightedCommand, mentionMatches.count - 1)])
            return
        }
        if !commandMatches.isEmpty, !session.draft.contains(" ") {
            let command = commandMatches[min(highlightedCommand, commandMatches.count - 1)]
            if session.draft != "/\(command.name)" {
                accept(command)
                return
            }
        }
        guard canSend else { return }
        if trimmedDraft.hasPrefix("@") {
            let input = UserInput(text: trimmedDraft, images: session.draftImages)
            isRoutingMessage = true
            Task {
                defer { isRoutingMessage = false }
                do { try await model.sendChatMention(input, from: session.id) }
                catch { routingError = error.localizedDescription }
            }
            return
        }
        if let approval = session.pendingApproval {
            guard !trimmedDraft.isEmpty else { return }
            session.answer(approval, with: .denyWithFeedback(trimmedDraft))
        } else {
            session.send(UserInput(text: trimmedDraft, images: session.draftImages))
            session.draftImages = []
        }
        session.draft = ""
    }

    private func setModel(_ model: String?) {
        var settings = session.meta.settings
        settings.model = model
        // Effort levels differ by model, and a stale one would be rejected.
        let models = capabilities?.models ?? []
        let chosen = models.first { $0.id == model } ?? models.first(where: \.isDefault) ?? models.first
        if let effort = settings.effort, chosen?.efforts.contains(effort) == false { settings.effort = nil }
        if let tier = settings.serviceTier, chosen?.speedOptions.contains(where: { $0.id == ServiceTierOption.requestValue(tier) }) == false {
            settings.serviceTier = nil
        }
        session.update(settings: settings)
    }

    private func setEffort(_ effort: String?) {
        var settings = session.meta.settings
        settings.effort = effort
        session.update(settings: settings)
    }

    private func setServiceTier(_ tier: String?) {
        var settings = session.meta.settings
        settings.serviceTier = tier
        session.update(settings: settings)
    }

    private func setMode(_ mode: ApprovalMode) {
        var settings = session.meta.settings
        settings.mode = mode
        session.update(settings: settings)
    }

    // MARK: Images

    private var attachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(session.draftImages) { image in
                    AttachmentThumbnail(attachment: image, size: 52)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                session.draftImages.removeAll { $0 == image }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove image attachment")
                            .offset(x: 5, y: -5)
                        }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
            .padding(.bottom, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 62)
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addImage(url:))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in addImage(url: url) }
            }
        }
        return true
    }

    private func addImage(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
            let data = try? Data(contentsOf: url)
        else { return }
        store(data, extension: url.pathExtension.lowercased(), mediaType: type.preferredMIMEType ?? "image/png")
    }

    private func addImage(data: Data) {
        store(data, extension: "png", mediaType: "image/png")
    }

    /// Copies images into app storage so the conversation keeps working if the original moves.
    private func store(_ data: Data, extension fileExtension: String, mediaType: String) {
        let directory = model.store.attachmentsDirectory
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
            session.draftImages.append(ImageAttachment(path: url.path, mediaType: mediaType))
        } catch {
            NSLog("Marika could not store an attachment: %@", error.localizedDescription)
        }
    }
}

struct AttachmentThumbnail: View {
    let attachment: ImageAttachment
    let size: CGFloat

    var body: some View {
        Group {
            if let image = NSImage(contentsOfFile: attachment.path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline)
        }
    }
}

/// How full the conversation's context window is.
private struct ContextRing: View {
    let usage: ContextUsage

    private var color: Color {
        usage.fraction > 0.85 ? .red : usage.fraction > 0.65 ? Theme.attention : .secondary
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, usage.fraction))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .help(
            "\(Int((usage.fraction * 100).rounded()))% of context used "
                + "(\(Format.tokens(usage.usedTokens)) of \(Format.tokens(usage.maxTokens)))")
    }
}
