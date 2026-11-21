import MarikaCore
import SwiftUI

struct QACaseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var value: QACase
    let save: (QACase) throws -> Void
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Test case").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Case title", text: $value.title)
                    TextField("Requirement / acceptance criteria", text: $value.requirement, axis: .vertical).lineLimit(3...6)
                    TextField("Preconditions and test data", text: $value.preconditions, axis: .vertical).lineLimit(2...5)
                    ForEach($value.steps) { $step in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Step \((value.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1)").font(.headline)
                                Spacer()
                                Button("Remove", role: .destructive) { value.steps.removeAll { $0.id == step.id } }
                            }
                            TextField("Action", text: $step.action, axis: .vertical).lineLimit(2...5)
                            TextField("Expected result", text: Binding(get: { step.expected }, set: {
                                step.expected = $0
                                if step.automation?.kind == .assertText { step.automation?.value = $0 }
                            }), axis: .vertical).lineLimit(2...5)
                            if step.automation != nil {
                                Text("This step includes a recorded browser action. Edit its replay values below.").font(.caption).foregroundStyle(.secondary)
                                TextField("Selector", text: Binding(get: { step.automation?.selector ?? "" }, set: { step.automation?.selector = $0 }))
                                TextField("Replay value / expected text", text: Binding(get: { step.automation?.value ?? "" }, set: {
                                    step.automation?.value = $0
                                    if step.automation?.kind == .assertText { step.expected = $0 }
                                }))
                            }
                        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                    }
                    Button("Add step", systemImage: "plus") { value.steps.append(QAStep(action: "", expected: "")) }.disabled(value.steps.count >= 100)
                }.textFieldStyle(.workspace)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.attention) }
            HStack {
                Text("Changes require approval before another run.").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Cancel") { dismiss() }
                Button("Save case") { do { try save(value); dismiss() } catch { self.error = error.localizedDescription } }
                    .buttonStyle(WorkspaceButtonStyle(kind: .primary))
            }
        }.padding(24).frame(width: 620, height: 660)
    }
}

struct QAGenerateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @Bindable var qa: QAWorkspace
    @State private var source = "Requirement"
    @State private var requirement = ""
    @State private var ticketID: UUID?
    @State private var agent: AgentKind = .codex
    @State private var busy = false
    @State private var error: String?
    private var tickets: [SpaceTicket] { model.workspace.spaces.flatMap(\.tickets).filter { $0.projectID == project.id && !$0.archived } }
    private var designIDs: [UUID] { Array(model.designCanvases[project.id]?.selection ?? []) }
    private var sourceText: String {
        switch source {
        case "Ticket":
            guard let ticket = tickets.first(where: { $0.id == ticketID }) else { return "" }
            return ticket.key + ": " + ticket.title + "\n" + ticket.body
        case "Design selection":
            guard !designIDs.isEmpty else { return "" }
            return (try? DesignTools.referencePrompt(model.design(for: project).document, selection: Set(designIDs))) ?? ""
        default: return requirement
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Draft test cases").font(.title2.weight(.semibold))
            Text("Generate proposed cases from a requirement, ticket or selected Design elements. Review expected behaviour before approval.").font(.callout).foregroundStyle(.secondary)
            Picker("Source", selection: $source) { ForEach(["Requirement", "Ticket", "Design selection"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if source == "Ticket" {
                Picker("Ticket", selection: $ticketID) {
                    Text("Choose ticket").tag(Optional<UUID>.none)
                    ForEach(tickets) { Text($0.key + " · " + $0.title).tag(Optional($0.id)) }
                }
            }
            if source == "Requirement" { TextEditor(text: $requirement).font(.body).frame(minHeight: 170).overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline) } }
            else { ScrollView { Text(sourceText.isEmpty ? "Select a ticket or choose elements in Design first." : sourceText).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 170) }
            Picker("Agent", selection: $agent) { ForEach(AgentKind.availableProviders) { Text($0.displayName).tag($0) } }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.attention) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer(); Button("Cancel") { dismiss() }.disabled(busy)
                Button("Generate draft") {
                    busy = true
                    Task {
                        do {
                            try await model.draftQACases(project: project, requirement: sourceText,
                                ticketID: source == "Ticket" ? ticketID : nil, designIDs: source == "Design selection" ? designIDs : [], agent: agent)
                            dismiss()
                        } catch { self.error = error.localizedDescription; busy = false }
                    }
                }.buttonStyle(WorkspaceButtonStyle(kind: .primary)).disabled(sourceText.isEmpty || busy)
            }
        }.padding(24).frame(width: 610)
    }
}

struct QADraftsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var qa: QAWorkspace
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Proposed test cases").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() } }
            ScrollView {
                ForEach(qa.data.drafts) { draft in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(draft.source).font(.caption).lineLimit(4).foregroundStyle(.secondary)
                        if draft.cases.isEmpty {
                            Text("Waiting for the agent's draft. Open the agent to inspect progress or a failure.").font(.callout)
                        }
                        ForEach(draft.cases) { test in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(test.title).font(.headline)
                                Text(test.preconditions).font(.caption)
                                ForEach(test.steps) { step in Text("• \(step.action) → \(step.expected)").font(.caption) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                        HStack {
                            Button("Open agent") { model.openAgentChat(draft.sessionID); dismiss() }
                            Button("Discard draft", role: .destructive) { qa.data.drafts.removeAll { $0.id == draft.id } }
                            Spacer()
                            Button("Add cases for review") {
                                do {
                                    guard qa.data.cases.count + draft.cases.count <= 500 else { throw QAError("The project has reached its case limit.") }
                                    for test in draft.cases { try qa.saveCase(test) }
                                    qa.data.drafts.removeAll { $0.id == draft.id }; dismiss()
                                } catch { self.error = error.localizedDescription }
                            }.disabled(draft.cases.isEmpty)
                        }.buttonStyle(WorkspaceButtonStyle(compact: true))
                    }.padding(.vertical, 12)
                    Divider()
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.attention) }
        }.padding(24).frame(width: 690, height: 650)
    }
}
