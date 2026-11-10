import MarikaCore
import SwiftUI

/// A run of tool calls and reasoning. Stays open while the agent works, and folds into a
/// one-line summary afterwards so the conversation stays readable.
struct ActivityGroup: View {
    @Environment(AppModel.self) private var model
    let items: [TranscriptItem]
    let children: [String: [TranscriptItem]]
    let projectID: UUID
    let isLive: Bool

    @State private var userExpanded: Bool?

    private var isCollapsible: Bool { items.count > 2 }
    private var isExpanded: Bool { userExpanded ?? (isLive || !isCollapsible) }

    /// e.g. "Read 3 files, edited 1 file, ran 2 commands".
    private var summary: String {
        var counts: [Phrase: Int] = [:]
        var order: [Phrase] = []
        for call in items.compactMap(\.tool) {
            guard !call.isInternal else { continue }
            let phrase = Phrase(kind: call.kind)
            if counts[phrase] == nil { order.append(phrase) }
            // One patch can touch several files.
            counts[phrase, default: 0] += phrase == .edit ? max(1, call.diff.count) : 1
        }
        guard !order.isEmpty else { return "Thought it through" }
        let parts = order.map { $0.text(count: counts[$0] ?? 0) }
        let sentence = parts.joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    private enum Phrase: Hashable {
        case read, edit, command, search, web, agent, plan, question, other

        init(kind: ToolKind) {
            switch kind {
            case .read: self = .read
            case .edit, .write: self = .edit
            case .shell: self = .command
            case .search: self = .search
            case .web: self = .web
            case .subagent: self = .agent
            case .plan: self = .plan
            case .question: self = .question
            default: self = .other
            }
        }

        func text(count: Int) -> String {
            func noun(_ singular: String) -> String { "\(count) \(singular)\(count == 1 ? "" : "s")" }
            switch self {
            case .read: return "read \(noun("file"))"
            case .edit: return "edited \(noun("file"))"
            case .command: return "ran \(noun("command"))"
            case .search: return "searched \(count == 1 ? "once" : "\(count) times")"
            case .web: return "used the web"
            case .agent: return "started \(noun("agent"))"
            case .plan: return "proposed a plan"
            case .question: return "asked \(noun("question"))"
            case .other: return "used \(noun("tool"))"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if isCollapsible {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { userExpanded = !isExpanded }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(summary)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, isExpanded ? 3 : 0)
            }
            if isExpanded {
                ForEach(items) { item in
                    switch item.content {
                    case .tool(let call):
                        ToolRow(call: call, children: children[call.id] ?? [], projectID: projectID)
                    case .thinking(let text, let durationMs):
                        ThinkingRow(text: text, durationMs: durationMs, isLive: isLive && item.id == items.last?.id)
                    default:
                        EmptyView()
                    }
                }
            } else if items.compactMap(\.tool).contains(where: { $0.name.hasSuffix("project_publish_design") && $0.status == .succeeded }) {
                Button { model.openDesign(for: projectID) } label: {
                    Label("Open Design", systemImage: "square.on.circle")
                }.buttonStyle(.borderless)
            }
        }
    }
}

private struct ThinkingRow: View {
    let text: String
    let durationMs: Int?
    let isLive: Bool

    @State private var isExpanded = false

    private var label: String {
        if isLive { return "Thinking" }
        if let durationMs { return "Thought for \(Format.duration(milliseconds: durationMs))" }
        return "Thought"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                        .frame(width: 16)
                        .symbolEffect(.pulse, isActive: isLive)
                    Text(label)
                        .font(.system(size: 12.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !text.isEmpty {
                InlineText(text)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
                    .padding(.bottom, 6)
            }
        }
    }
}

struct ToolRow: View {
    @Environment(AppModel.self) private var model
    let call: ToolCall
    let children: [TranscriptItem]
    let projectID: UUID

    @State private var isExpanded = false

    private var canExpand: Bool {
        !call.output.isEmpty || !call.diff.isEmpty || !children.isEmpty || call.kind == .shell
    }

    private var statusColor: Color {
        switch call.status {
        case .failed: .red
        case .denied, .cancelled: Theme.attention
        default: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard canExpand else { return }
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Group {
                        if call.status == .running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: call.symbol)
                                .font(.system(size: 11))
                                .foregroundStyle(statusColor)
                        }
                    }
                    .frame(width: 16)

                    Text(call.title)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(call.detail)
                        .font(Theme.codeSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    trailing

                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if call.name.hasSuffix("project_publish_design"), call.status == .succeeded {
                Button { model.openDesign(for: projectID) } label: {
                    Label("Open Design", systemImage: "square.on.circle")
                }
                .buttonStyle(.borderless).padding(.leading, 24)
            }

            if isExpanded {
                ToolDetail(call: call, children: children, projectID: projectID)
                    .padding(.leading, 24)
                    .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch call.status {
        case .denied:
            Text("Denied").font(.system(size: 11)).foregroundStyle(Theme.attention)
        case .cancelled:
            Text("Stopped").font(.system(size: 11)).foregroundStyle(.tertiary)
        case .failed:
            Text("Failed").font(.system(size: 11)).foregroundStyle(.red)
        default:
            if !call.diff.isEmpty {
                DiffStat(
                    additions: call.diff.reduce(0) { $0 + $1.additions },
                    deletions: call.diff.reduce(0) { $0 + $1.deletions })
            } else if let finished = call.finishedAt, finished.timeIntervalSince(call.startedAt) >= 1 {
                Text(Format.duration(seconds: finished.timeIntervalSince(call.startedAt)))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ToolDetail: View {
    let call: ToolCall
    let children: [TranscriptItem]
    let projectID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch call.kind {
            case .shell:
                if let command = call.input["command"]?.string {
                    OutputBlock(text: command, prefix: "$ ")
                }
                if !call.output.isEmpty {
                    OutputBlock(text: call.output)
                }
            case .subagent:
                ForEach(children) { child in
                    if case .tool(let nested) = child.content {
                        ToolRow(call: nested, children: [], projectID: projectID)
                    }
                }
                if !call.output.isEmpty {
                    MarkdownView(text: call.output)
                }
            case .plan:
                MarkdownView(text: call.input["plan"]?.string ?? call.output)
            case .question:
                InlineText(call.output)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            default:
                if call.diff.isEmpty {
                    if !call.output.isEmpty { OutputBlock(text: call.output) }
                } else {
                    ForEach(call.diff) { DiffView(file: $0) }
                }
            }
        }
    }
}

/// Command text or output, capped so one noisy tool can't take over the page.
struct OutputBlock: View {
    let text: String
    var prefix = ""

    private static let limit = 20_000

    private var display: String {
        let clipped = text.count > Self.limit ? String(text.prefix(Self.limit)) + "\n… output truncated" : text
        return prefix + clipped.trimmingCharacters(in: .newlines)
    }

    var body: some View {
        ScrollView {
            Text(display)
                .font(Theme.codeSmall)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .surface(cornerRadius: 8)
        .overlay(alignment: .topTrailing) {
            CopyButton(text: text).padding(5)
        }
    }
}
