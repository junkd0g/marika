import MarikaCore
import SwiftUI

struct ProjectResearchHub: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack { sections; Spacer(); deliverables }
                VStack(alignment: .leading) { sections; deliverables }
            }.padding(12)
            Divider()
            switch model.researchSections[project.id] ?? "Research" {
            case "Compare": ProjectComparisonView(project: project)
            case "Knowledge": ProjectKnowledgeView(project: project)
            default: ProjectResearchView(project: project)
            }
        }.background(Theme.canvas)
    }
    private var sections: some View {
        Picker("Research workspace", selection: Binding(get: { model.researchSections[project.id] ?? "Research" }, set: { model.researchSections[project.id] = $0 })) {
            Text("Research").tag("Research"); Text("Compare models").tag("Compare"); Text("Knowledge").tag("Knowledge")
        }.pickerStyle(.segmented).frame(maxWidth: 420)
    }
    private var deliverables: some View { Button("Deliverables", systemImage: "doc.richtext") { model.showExperience("Artifacts", project: project) }.controlSize(.small) }
}

struct ProjectComparisonView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var question = ""
    @State private var selectedID: UUID?
    @State private var synthesizer: AgentKind = .codex
    @State private var starting = false
    @State private var error: String?
    private var runs: [ModelComparison] { (model.project(id: project.id)?.comparisons ?? []).reversed() }
    private var run: ModelComparison? { runs.first { $0.id == selectedID } ?? runs.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Two independent answers. One considered conclusion.").font(.headline)
            TextField("What should Claude and Codex investigate?", text: $question, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
            ViewThatFits(in: .horizontal) {
                HStack { controls; Spacer(); start }
                VStack(alignment: .leading) { controls; start }
            }
            Text("Uses both installed accounts for independent analysis, then a third run to combine the answers. Each run follows its provider's approvals and usage limits.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(Theme.attention).textSelection(.enabled) }
            Divider()
            if let run {
                HStack {
                    Menu("Comparisons (\(runs.count))") { ForEach(runs) { value in Button(value.question) { selectedID = value.id } } }
                    Spacer()
                    Button("Remove") { model.updateProject(project.id) { $0.comparisons?.removeAll { $0.id == run.id } }; selectedID = nil }
                        .disabled([run.claudeID, run.codexID, run.synthesisID].compactMap { $0 }.contains { model.controllers[$0]?.isBusy == true })
                }.controlSize(.small)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(run.question).font(.title3.bold()).textSelection(.enabled)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 14) { answer(.claude, run: run).frame(minWidth: 280); answer(.codex, run: run).frame(minWidth: 280) }
                            VStack(spacing: 14) { answer(.claude, run: run); answer(.codex, run: run) }
                        }
                        synthesis(run)
                    }.padding(.bottom, 20)
                }
            } else { ContentUnavailableView("Compare before deciding", systemImage: "person.2.wave.2", description: Text("Both agents get the same question without seeing the other answer. The combined result preserves disagreements and unverified claims.")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(20)
        .task(id: runs.map(\.id)) {
            for run in runs { for id in [run.claudeID, run.codexID, run.synthesisID].compactMap({ $0 }) where model.workspace.sessions.contains(where: { $0.id == id }) { await model.open(id) } }
        }
    }
    private var controls: some View { Picker("Combine with", selection: $synthesizer) { ForEach(AgentKind.allCases) { Text($0.shortName).tag($0) } }.fixedSize().controlSize(.small) }
    private var start: some View {
        Button(starting ? "Starting…" : "Compare Claude + Codex", systemImage: "arrow.triangle.branch") {
            starting = true; error = nil
            Task { defer { starting = false }; do { selectedID = try await model.launchComparison(question, synthesizer: synthesizer, project: project); question = "" } catch { self.error = error.localizedDescription } }
        }.buttonStyle(.borderedProminent).disabled(starting || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func answer(_ agent: AgentKind, run: ModelComparison) -> some View {
        let id = run.sessionID(for: agent)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(agent.shortName).font(.headline); Spacer()
                if model.controllers[id]?.isBusy == true { Button("Stop") { model.controllers[id]?.interrupt() } }
                if model.workspace.sessions.contains(where: { $0.id == id }) { Button("Open chat") { model.openAgentChat(id) } }
            }.controlSize(.small)
            if let value = run.answers[agent.rawValue] {
                MarkdownView(text: value.conclusion).textSelection(.enabled)
                DisclosureGroup("Reasoning and uncertainties") {
                    MarkdownView(text: value.reasoning).textSelection(.enabled)
                    ForEach(Array(value.uncertainties.enumerated()), id: \.offset) { _, text in Text("• " + text).font(.callout).textSelection(.enabled) }
                    ForEach(value.sources) { source in
                        if let url = URL(string: source.url) { Link(source.title, destination: url) }
                        Text(source.excerpt).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } else {
                let controller = model.controllers[id]
                if let controller {
                    let state = AgentTaskPresentation(meta: controller.meta, items: controller.items, phase: controller.phase, approval: controller.pendingApproval, activity: controller.activity)
                    if state.state == .failed || state.state == .stopped { Text(state.preview ?? state.state.rawValue).foregroundStyle(Theme.attention).textSelection(.enabled) }
                }
                Text(run.errors?[agent.rawValue] ?? (controller?.pendingApproval != nil ? "Needs approval — open chat to continue." : controller?.isBusy == true ? "Analyzing independently…" : "No published answer. Open chat for the result or retry."))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Button("Retry analysis") { Task { await model.startComparisonAnswer(run.id, agent: agent, project: project) } }.disabled(controller?.isBusy == true || run.synthesisID != nil)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
    }
    @ViewBuilder private func synthesis(_ run: ModelComparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Combined conclusion · " + (model.workspace.sessions.first(where: { $0.id == run.synthesisID })?.agent ?? run.synthesizer).shortName).font(.headline)
            if let value = run.synthesis {
                MarkdownView(text: value.recommendation).textSelection(.enabled)
                Text("Agreements").font(.headline)
                ForEach(Array(value.agreements.enumerated()), id: \.offset) { _, text in Text("• " + text).textSelection(.enabled) }
                Text("Disagreements").font(.headline)
                if value.disagreements.isEmpty { Text("No disagreements reported. Agreement does not verify correctness.").foregroundStyle(.secondary) }
                ForEach(Array(value.disagreements.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 6) { Text(item.topic).bold(); Text("Claude: " + item.claude); Text("Codex: " + item.codex); Text("Assessment: " + item.resolution) }.textSelection(.enabled)
                }
                Text("Checks still needed").font(.headline)
                ForEach(Array(value.checks.enumerated()), id: \.offset) { _, text in Text("• " + text).textSelection(.enabled) }
            } else {
                if let error = run.errors?["synthesis"] { Text(error).foregroundStyle(Theme.attention) }
                Text(run.answers.count < 2 ? "Waiting for both independent answers." : "The synthesis runs after both answers are published. If it stopped, open its chat or retry.").foregroundStyle(.secondary)
                if let id = run.synthesisID, model.workspace.sessions.contains(where: { $0.id == id }) { Button("Open synthesis chat") { model.openAgentChat(id) } }
                Button("Combine conclusions") { Task { do { try await model.synthesizeComparison(run.id, agent: run.synthesizer, project: project) } catch { self.error = error.localizedDescription } } }
                    .disabled(run.answers.count != 2 || run.synthesisID.flatMap { model.controllers[$0]?.isBusy } == true)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).surface()
    }
}
