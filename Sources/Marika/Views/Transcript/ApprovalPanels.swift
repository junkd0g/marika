import AppKit
import MarikaCore
import SwiftUI

/// What the agent is waiting on, shown above the composer until it is answered.
struct ApprovalPanel: View {
    let request: ApprovalRequest
    let session: SessionController

    private var queueLabel: String? {
        session.approvals.count > 1 ? "1 of \(session.approvals.count)" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.attention)
                Text(request.title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let agentLabel = request.agentLabel {
                    Text(agentLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let queueLabel {
                    Text(queueLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            switch request.kind {
            case .tool:
                ToolApproval(request: request, session: session)
            case .questions(let questions):
                QuestionsApproval(request: request, questions: questions, session: session)
            case .plan(let plan):
                PlanApproval(request: request, plan: plan, session: session)
            }
        }
        .padding(14)
        .floatingPanel()
    }
}

private struct ToolApproval: View {
    let request: ApprovalRequest
    let session: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if request.diff.isEmpty {
                if !request.detail.isEmpty {
                    OutputBlock(text: request.detail, prefix: request.toolKind == .shell ? "$ " : "")
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(request.diff) { DiffView(file: $0) }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let directory = request.workingDirectory {
                Label("Runs in \(directory)", systemImage: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.attention)
            }
            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(request.notes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Deny") { session.answer(request, with: .deny) }
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                Text("or type what to do instead")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                ForEach(request.rememberOptions.prefix(1)) { option in
                    Button(option.label) { session.answer(request, with: .allow(remember: option)) }
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button(request.link == nil ? "Allow" : "Open Page") {
                    if let link = request.link { NSWorkspace.shared.open(link) }
                    session.answer(request, with: .allow())
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .fixedSize()
            }
        }
    }
}

private struct QuestionsApproval: View {
    let request: ApprovalRequest
    let questions: [AgentQuestion]
    let session: SessionController

    @State private var selections: [String: Set<String>] = [:]
    @State private var otherText: [String: String] = [:]

    private var isComplete: Bool {
        questions.allSatisfy { $0.isOptional || !answer(for: $0).isEmpty }
    }

    private func answer(for question: AgentQuestion) -> [String] {
        let other = otherText[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var chosen = question.options.map(\.label).filter { selections[question.id]?.contains($0) == true }
        if !other.isEmpty { chosen = question.allowsMultiple ? chosen + [other] : [other] }
        return chosen
    }

    private func toggle(_ label: String, in question: AgentQuestion) {
        var chosen = selections[question.id] ?? []
        if chosen.contains(label) {
            chosen.remove(label)
        } else {
            if !question.allowsMultiple { chosen.removeAll() }
            chosen.insert(label)
        }
        selections[question.id] = chosen
        if !question.allowsMultiple { otherText[question.id] = "" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                questionList.padding(.trailing, 8)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Skip") { session.answer(request, with: .deny) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Answer") {
                    let answers = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, answer(for: $0)) })
                    session.answer(request, with: .answers(answers))
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!isComplete)
            }
        }
    }

    private var questionList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).font(.system(size: 13))
                    ForEach(question.options) { option in
                        OptionRow(
                            option: option, isSelected: selections[question.id]?.contains(option.label) == true,
                            allowsMultiple: question.allowsMultiple
                        ) { toggle(option.label, in: question) }
                    }
                    TextField(
                        question.options.isEmpty ? "Your answer…" : "Something else…",
                        text: Binding(
                            get: { otherText[question.id] ?? "" },
                            set: {
                                otherText[question.id] = $0
                                if !question.allowsMultiple, !$0.isEmpty { selections[question.id] = [] }
                            })
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                }
            }
        }
    }
}

private struct OptionRow: View {
    let option: AgentQuestion.Option
    let isSelected: Bool
    let allowsMultiple: Bool
    let action: () -> Void

    private var symbol: String {
        switch (allowsMultiple, isSelected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 13, weight: .medium))
                    if !option.detail.isEmpty {
                        Text(option.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Theme.surface,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PlanApproval: View {
    let request: ApprovalRequest
    let plan: String
    let session: SessionController

    private var stopButton: some View {
        Button("Stop") { session.answer(request, with: .deny) }
            .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private var approveButtons: some View {
        Button("Approve, Ask for Each Edit") { session.answer(request, with: .approvePlan(then: nil)) }
        Button("Approve and Accept Edits") { session.answer(request, with: .approvePlan(then: .acceptEdits)) }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                MarkdownView(text: plan).padding(.trailing, 8)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    stopButton
                    Text("or type changes to the plan")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    Spacer(minLength: 8)
                    approveButtons
                }
                HStack(spacing: 8) {
                    stopButton
                    Spacer(minLength: 8)
                    approveButtons
                }
                VStack(alignment: .trailing, spacing: 6) {
                    approveButtons
                    stopButton
                }
            }
        }
    }
}

/// The agent's task list for the current turn.
struct TodoStrip: View {
    let todos: [TodoItem]
    @State private var isExpanded = false

    private var completed: Int { todos.count { $0.status == .completed } }
    private var current: TodoItem? { todos.first { $0.status == .inProgress } ?? todos.first { $0.status == .pending } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").foregroundStyle(.secondary)
                    Text("\(completed) of \(todos.count)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    if let current, !isExpanded {
                        Text(current.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(todos) { todo in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: symbol(for: todo))
                                .font(.system(size: 11))
                                .foregroundStyle(todo.status == .inProgress ? Color.accentColor : .secondary)
                            Text(todo.text)
                                .font(.system(size: 12.5))
                                .strikethrough(todo.status == .completed)
                                .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .floatingPanel(cornerRadius: 12)
    }

    private func symbol(for todo: TodoItem) -> String {
        switch todo.status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        case .pending: "circle"
        }
    }
}
