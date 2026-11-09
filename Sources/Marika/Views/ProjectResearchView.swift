import MarikaCore
import SwiftUI

struct ProjectResearchView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var question = ""
    @State private var focus: ResearchFocus = .documentation
    @State private var agent: AgentKind = .codex
    @State private var selectedID: UUID?
    @State private var selectedSourceID: String?
    @State private var launching = false
    @State private var error: String?
    @State private var proposal: ResearchTaskProposal?
    private var runs: [ResearchRun] { (model.project(id: project.id)?.research ?? []).reversed() }
    private var selected: ResearchRun? { runs.first { $0.id == selectedID } ?? runs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Research").font(.system(size: 20, weight: .semibold))
                        Text("Investigate, check sources, then choose what to build.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connections") { model.openProjectSettings(project, section: "MCP") }
                }
                TextField("What should we investigate?", text: $question, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityLabel("Research question")
                ViewThatFits(in: .horizontal) {
                    HStack { controls; Spacer(); startButton }
                    VStack(alignment: .leading) { controls; startButton }
                }
                if let error { Text(error).foregroundStyle(Theme.attention).textSelection(.enabled) }
            }.padding(20)
            Divider()
            if let run = selected {
                ViewThatFits(in: .horizontal) { HStack {
                    Menu {
                        ForEach(runs) { item in Button(item.question) { selectedID = item.id; selectedSourceID = nil } }
                    } label: { Label("Research history (\(runs.count))", systemImage: "clock") }.fixedSize()
                    Spacer()
                    Text(run.focus.rawValue).foregroundStyle(.secondary)
                    Button("Open research chat") { model.openAgentChat(run.sessionID) }
                }; VStack(alignment: .leading, spacing: 10) {
                    Menu("Research history (\(runs.count))") { ForEach(runs) { item in Button(item.question) { selectedID = item.id; selectedSourceID = nil } } }.fixedSize()
                    HStack { Text(run.focus.rawValue).foregroundStyle(.secondary); Spacer(); Button("Open research chat") { model.openAgentChat(run.sessionID) } }
                } }.controlSize(.small).padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
                if let report = run.report {
                    GeometryReader { geometry in
                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: 0) {
                                answer(run, report: report)
                                Divider()
                                sources(report).frame(width: min(340, geometry.size.width * 0.36))
                            }
                        } else {
                            ScrollViewReader { proxy in ScrollView {
                                VStack(alignment: .leading, spacing: 18) {
                                    answerContent(run, report: report)
                                    Divider()
                                    sourceContent(report)
                                }.padding(20)
                            }.onChange(of: selectedSourceID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } } } }
                        }
                    }
                } else {
                    pending(run)
                }
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        ContentUnavailableView("Research before you build", systemImage: "books.vertical", description:
                            Text("Compare libraries, investigate documentation, or study competitors. Your agent gathers sources and saves actionable findings here."))
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                }
            }
        }
        .background(Theme.canvas)
        .onAppear { agent = model.selectedSession?.agent ?? model.workspace.preferences.defaultAgent; selectedID = model.selectedResearchIDs[project.id] }
        .onChange(of: selectedID) { _, id in model.selectedResearchIDs[project.id] = id }
        .task(id: runs.map(\.sessionID)) { for run in runs { await model.open(run.sessionID) } }
        .sheet(item: $proposal) { proposal in
            LaunchAgentView(project: project, initialPrompt: proposal.prompt, initialName: proposal.title, parentSessionID: proposal.run.sessionID,
                researchReference: ResearchTaskReference(runID: proposal.run.id, findingID: proposal.findingID)) { controller in
                model.selectedAgentTaskIDs[project.id] = controller.id
                model.updateProject(project.id) { current in
                    guard let index = current.research?.firstIndex(where: { $0.id == proposal.run.id }) else { return }
                    var links = current.research?[index].implementationTasks ?? [:]
                    links[proposal.findingID] = controller.id
                    current.research?[index].implementationTasks = links
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            Picker("Scope", selection: $focus) { ForEach(ResearchFocus.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.fixedSize()
            Picker("Provider", selection: $agent) { ForEach(AgentKind.allCases) { Text($0.shortName).tag($0) } }.fixedSize()
        }.controlSize(.small)
    }
    private var startButton: some View {
        Button(launching ? "Starting…" : "Start research", systemImage: "magnifyingglass") {
            launching = true; error = nil
            Task {
                defer { launching = false }
                do { let run = try await model.launchResearch(question: question, focus: focus, agent: agent, project: project); selectedID = run.id; selectedSourceID = nil; question = "" }
                catch { self.error = error.localizedDescription }
            }
        }.buttonStyle(.borderedProminent).disabled(launching || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func answer(_ run: ResearchRun, report: ResearchReport) -> some View {
        ScrollView { answerContent(run, report: report).padding(20) }.frame(maxWidth: .infinity)
    }
    private func answerContent(_ run: ResearchRun, report: ResearchReport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(run.question).font(.title3.bold()).textSelection(.enabled)
            Text(run.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            MarkdownView(text: report.answer).environment(\.projectRoot, project.url).textSelection(.enabled)
            Divider()
            Text("Implementation opportunities").font(.headline)
            if report.findings.isEmpty { Text("This report has no proposed implementation tasks.").foregroundStyle(.secondary) }
            ForEach(report.findings) { finding in
                VStack(alignment: .leading, spacing: 10) {
                    Text(finding.title).font(.system(size: 13, weight: .semibold))
                    Text(finding.detail).textSelection(.enabled)
                    HStack {
                        ForEach(finding.sourceIDs, id: \.self) { id in Button("[\(id)]") { selectedSourceID = id }.buttonStyle(.link) }
                        Spacer()
                        if let taskID = run.implementationTasks?[finding.id], model.workspace.sessions.contains(where: { $0.id == taskID }) {
                            Button("Open task") { model.selectedAgentTaskIDs[project.id] = taskID; model.showAgents(for: project) }
                        } else if (model.project(id: project.id)?.taskQueue?.items ?? []).contains(where: { $0.research?.runID == run.id && $0.research?.findingID == finding.id && $0.state != .cancelled }) {
                            Button("View queued task") { model.taskQueueProjectID = project.id }
                        } else {
                            Button("Create task") { proposal = ResearchTaskProposal(run: run, findingID: finding.id, title: String(finding.title.prefix(80)), prompt: report.implementationPrompt(for: finding, question: run.question)) }
                        }
                    }
                    Text(finding.nextAction).font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).surface()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sources(_ report: ResearchReport) -> some View { ScrollViewReader { proxy in
        ScrollView { sourceContent(report).padding(18) }
            .onChange(of: selectedSourceID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
    } }
    private func sourceContent(_ report: ResearchReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sources (\(report.sources.count))").font(.headline)
            Text("Open a source to check the agent's supporting evidence.").font(.caption).foregroundStyle(.secondary)
            ForEach(report.sources) { source in
                VStack(alignment: .leading, spacing: 8) {
                    if let url = URL(string: source.url) { Link("[\(source.id)] " + source.title, destination: url).font(.system(size: 12, weight: .semibold)) }
                    Text(URLComponents(string: source.url)?.host ?? "").font(.caption2).foregroundStyle(.secondary)
                    Text(source.excerpt).font(.system(size: 12)).textSelection(.enabled)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectedSourceID == source.id ? Color.accentColor.opacity(0.1) : Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .id(source.id)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func pending(_ run: ResearchRun) -> some View {
        let controller = model.controllers[run.sessionID]
        let presentation = controller.map { AgentTaskPresentation(meta: $0.meta, items: $0.items, phase: $0.phase, approval: $0.pendingApproval, activity: $0.activity) }
        return VStack(spacing: 14) {
            if controller?.isBusy == true { ProgressView() }
            Text(run.question).font(.headline)
            Text(controller?.isBusy == true ? (presentation?.preview ?? "Gathering sources…") : "No research report was published.")
                .foregroundStyle(.secondary).textSelection(.enabled)
            if controller?.isBusy != true { Text(presentation?.preview ?? "Open the research chat to inspect progress, tool access, or errors.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(controller?.pendingApproval == nil ? "Open chat" : "Review approval") { model.openAgentChat(run.sessionID) }
                if controller?.isBusy == true { Button("Stop research", role: .destructive) { controller?.interrupt() } }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ResearchTaskProposal: Identifiable {
    let id = UUID()
    let run: ResearchRun
    let findingID: String
    let title: String
    let prompt: String
}
