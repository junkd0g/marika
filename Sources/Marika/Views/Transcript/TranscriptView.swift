import AppKit
import MarikaCore
import SwiftUI

/// What the transcript draws: messages, and runs of agent activity grouped between them.
enum TranscriptRow: Identifiable {
    case message(TranscriptItem)
    case activity(id: String, items: [TranscriptItem])

    var id: String {
        switch self {
        case .message(let item): item.id
        case .activity(let id, _): id
        }
    }

    static func build(_ items: [TranscriptItem]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var run: [TranscriptItem] = []

        func flush() {
            guard let first = run.first else { return }
            rows.append(.activity(id: "activity-\(first.id)", items: run))
            run.removeAll()
        }

        for item in items where item.parentToolID == nil {
            switch item.content {
            case .tool(let call) where call.isInternal:
                continue
            case .tool, .thinking:
                run.append(item)
            default:
                flush()
                rows.append(.message(item))
            }
        }
        flush()
        return rows
    }
}

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let session: SessionController

    /// Rows are laid out exactly rather than lazily. A lazy stack anchored to the bottom has to
    /// estimate the height of rows it hasn't built, and with rows this uneven it can land past
    /// them and show an empty page. Capping the rows keeps the exact layout cheap on long sessions.
    private static let pageSize = 80

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAwayFromBottom = false
    @State private var visibleRows = TranscriptView.pageSize
    @State private var historyWindowEnd: Int?
    @State private var highlightedItemID: String?
    /// Whether the view tracks the end of the conversation. Only the user can turn this off, by
    /// scrolling away. SwiftUI's bottom anchor isn't enough here: when rows settle their height
    /// the scroll view can snap back to the top, and asking for `.bottom` again does nothing
    /// because the position already says `.bottom`. So the view scrolls to a numeric offset.
    @State private var isFollowing = true
    @State private var isUserScrolling = false
    @State private var endOffset: CGFloat = 0

    private struct ScrollMetrics: Equatable {
        var offset: CGFloat
        var endOffset: CGFloat
    }

    var body: some View {
        let rows = TranscriptRow.build(session.items)
        let children = Dictionary(grouping: session.items.filter { $0.parentToolID != nil }) { $0.parentToolID ?? "" }
        let windowEnd = min(rows.count, historyWindowEnd ?? rows.count)
        let windowStart = max(0, windowEnd - visibleRows)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if windowStart > 0 {
                    Button("Show earlier messages") { visibleRows += Self.pageSize }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                ForEach(rows[windowStart..<windowEnd]) { row in
                    Group {
                        switch row {
                        case .message(let item):
                            MessageRow(item: item, session: session)
                        case .activity(_, let items):
                            ActivityGroup(
                                items: items, children: children,
                                isLive: session.isBusy && row.id == rows.last?.id)
                        }
                    }
                    .background {
                        if highlightedItemID == row.id {
                            RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1))
                                .padding(.horizontal, -8).padding(.vertical, -6)
                        }
                    }
                    .overlay {
                        if highlightedItemID == row.id {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                                .padding(.horizontal, -8).padding(.vertical, -6)
                        }
                    }
                    .id(row.id)
                    #if DEBUG
                        .background {
                            if highlightedItemID == row.id { DebugViewMarker(name: "chat-history-target") }
                        }
                    #endif
                }
                if windowEnd < rows.count {
                    Button("Show later messages") {
                        historyWindowEnd = min(rows.count, windowEnd + Self.pageSize)
                        visibleRows += Self.pageSize
                    }.buttonStyle(.link).font(.system(size: 12)).frame(maxWidth: .infinity)
                } else if session.isBusy {
                    WorkingIndicator(session: session)
                } else if let summary = TaskCompletionSummary(items: session.items) {
                    TaskCompletionCard(session: session, summary: summary)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: Theme.transcriptWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollPhaseChange { _, phase in
            isUserScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: geometry.contentOffset.y,
                endOffset: geometry.contentSize.height - geometry.containerSize.height)
        } action: { _, metrics in
            endOffset = metrics.endOffset
            let distance = metrics.endOffset - metrics.offset
            isAwayFromBottom = distance > 120
            if isUserScrolling || ScrollWheelActivity.shared.isRecent {
                isFollowing = distance <= 8
            } else if isFollowing, distance > 1 {
                position.scrollTo(y: metrics.endOffset)
            }
        }
        .onChange(of: session.items.count) { _, _ in
            if case .user = session.items.last?.content { jumpToEnd() }
        }
        .overlay(alignment: .bottom) {
            if isAwayFromBottom || historyWindowEnd != nil {
                Button(action: jumpToEnd) {
                    Label("Latest", systemImage: "arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .floatingPanel(cornerRadius: 14)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                #if DEBUG
                    .background(DebugViewMarker(name: "transcript-latest"))
                #endif
            }
        }
        .animation(.easeOut(duration: 0.15), value: isAwayFromBottom)
        .onAppear { ScrollWheelActivity.shared.start() }
        .task(id: model.chatHistoryFocus?.requestID) {
            guard let focus = model.chatHistoryFocus, focus.sessionID == session.id,
                  let index = rows.firstIndex(where: { $0.id == focus.itemID }) else { return }
            isFollowing = false
            historyWindowEnd = min(rows.count, index + Self.pageSize / 2)
            visibleRows = Self.pageSize
            highlightedItemID = focus.itemID
            await Task.yield()
            if !Task.isCancelled { position.scrollTo(id: focus.itemID, anchor: .center) }
        }
    }

    private func jumpToEnd() {
        historyWindowEnd = nil
        visibleRows = Self.pageSize
        highlightedItemID = nil
        if model.chatHistoryFocus?.sessionID == session.id { model.chatHistoryFocus = nil }
        isFollowing = true
        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(y: endOffset) }
    }
}

/// Notices the scroll wheel directly. A plain mouse wheel reports no scroll phase to SwiftUI, so
/// without this, anyone using a mouse would be pulled back to the end of a streaming answer.
@MainActor
final class ScrollWheelActivity {
    static let shared = ScrollWheelActivity()

    private var lastActivity = Date.distantPast
    private var monitor: Any?

    var isRecent: Bool { Date().timeIntervalSince(lastActivity) < 0.3 }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let moved = event.scrollingDeltaY != 0
            MainActor.assumeIsolated {
                if moved { ScrollWheelActivity.shared.lastActivity = Date() }
            }
            return event
        }
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    let session: SessionController
    private var agent: AgentKind { session.meta.agent }

    var body: some View {
        switch item.content {
        case .user(let text, let images):
            UserMessage(text: text, images: images)
                .help("You · " + item.date.formatted(date: .omitted, time: .shortened))
        case .assistant(let text):
            AssistantMessage(text: text, session: session)
        case .notice(let notice):
            NoticeRow(notice: notice, agent: agent)
        case .turnEnd(let summary):
            TurnEndRow(summary: summary, showsCost: agent == .claude && model.workspace.preferences.claudeBilling == .apiKey)
        case .tool, .thinking:
            EmptyView()
        }
    }

    private func messageHeader(_ sender: String) -> some View {
        HStack(spacing: 7) {
            Text(sender).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(item.date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

private struct UserMessage: View {
    let text: String
    let images: [ImageAttachment]

    var body: some View {
        HStack {
            Spacer(minLength: 72)
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(images) { image in
                            AttachmentThumbnail(attachment: image, size: 96)
                        }
                    }
                }
                if !text.isEmpty {
                    SelectableMessageText(text, markdown: false, fillsWidth: false)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Theme.messageBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    CopyButton(text: text).accessibilityLabel("Copy your message")
                }
            }
        }
    }
}

private struct AssistantMessage: View {
    @Environment(AppModel.self) private var model
    let text: String
    let session: SessionController
    @State private var commandError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownView(text: text, onRunCommand: { command in
                do { try model.runChatCommand(command, sessionID: session.id) }
                catch { commandError = error.localizedDescription }
            }, runCommandsDisabled: session.isBusy, nativeSelection: true)
            CopyButton(text: text).accessibilityLabel("Copy entire reply")
        }
            .alert("Couldn't run command", isPresented: Binding(get: { commandError != nil }, set: { if !$0 { commandError = nil } })) {
                Button("OK") { commandError = nil }
            } message: { Text(commandError ?? "") }
    }
}

private struct NoticeRow: View {
    @Environment(AppModel.self) private var model
    let notice: Notice
    let agent: AgentKind

    private var color: Color {
        switch notice.level {
        case .info: .secondary
        case .warning: Theme.attention
        case .error: .red
        }
    }

    private var symbol: String {
        switch notice.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(notice.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if notice.action == .signIn {
                Button("Sign In…") { model.signIn(agent) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(notice.level == .info ? 0.06 : 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TurnEndRow: View {
    let summary: TurnSummary
    /// On a subscription the figure isn't what the user pays, so it would only mislead.
    let showsCost: Bool

    private var label: String? {
        let duration = summary.durationMs.map(Format.duration(milliseconds:))
        switch summary.outcome {
        case .completed: return duration.map { "Finished in \($0)" }
        case .interrupted: return "Stopped"
        case .failed: return nil
        }
    }

    var body: some View {
        if let label {
            HStack(spacing: 6) {
                Text(label)
                if let output = summary.outputTokens, output > 0 {
                    Text("·")
                    Text("\(Format.tokens(output)) tokens out")
                }
                if showsCost, let cost = summary.totalCostUSD {
                    Text("·")
                    Text("\(Format.cost(cost)) this session")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
    }
}

private struct WorkingIndicator: View {
    let session: SessionController

    private var label: String {
        if session.phase == .waitingForUser { return "Waiting for you" }
        return session.activity ?? "Working"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if session.phase == .waitingForUser {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Theme.attention)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(label)
                if let start = session.turnStartedAt {
                    Text(Format.duration(seconds: max(0, context.date.timeIntervalSince(start).rounded())))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }
}
