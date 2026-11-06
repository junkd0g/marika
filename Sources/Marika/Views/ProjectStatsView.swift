import Charts
import MarikaCore
import SwiftUI

struct ProjectStatsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var launching = false
    @State private var failure: String?
    @State private var selectedScanID: UUID?
    @State private var showsSettings = false
    @State private var showsFullSummary = false
    @State private var severity: ScanFinding.Severity?
    @State private var expanded: Set<String> = []

    private var provider: AgentKind { project.scanProvider ?? model.selectedSession?.agent ?? model.workspace.preferences.defaultAgent }
    private var modelID: String? { project.scanProvider == nil ? model.selectedSession?.model : project.scanModel }
    private var agent: SessionController? { project.statsAgentID.flatMap { model.controllers[$0] } }
    private var history: [CodeScan] { project.scans ?? [] }
    private var scan: CodeScan? { history.first { $0.id == selectedScanID } ?? history.last }
    private var active: Bool { launching || agent?.isBusy == true }
    private var incompleteReview: String? {
        guard let agent, !agent.isBusy else { return nil }
        if let item = agent.items.last, case .notice(let notice) = item.content, notice.level == .error { return notice.text }
        if let scan = history.last, scan.agentSessionID == agent.id, scan.inventory != nil, scan.review == nil {
            return "Inventory saved. The agent finished without publishing a code review."
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if active || failure != nil || incompleteReview != nil { activity }
                if let scan {
                    review(scan)
                    if let inventory = scan.inventory {
                        metrics(inventory)
                        if let report = scan.review, !report.findings.isEmpty { findings(report) }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) { hotspots(inventory); composition(scan) }.frame(minWidth: 590)
                            VStack(spacing: 16) { hotspots(inventory); composition(scan) }
                        }
                        let comparable = history.filter { $0.inventory != nil && $0.date <= scan.date }
                        if comparable.count > 1 { trend(comparable) }
                        if !inventory.markers.isEmpty { markers(inventory) }
                        Text("Generated code tracked separately · \(inventory.excludedFiles.formatted()) dependency/build files excluded · \(scan.skipped) unreadable files skipped" + (scan.limited ? " · Inventory limited to 20,000 paths" : ""))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                } else if !active {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30)).foregroundStyle(.teal)
                        Text("Find what needs attention").font(.title3.weight(.semibold))
                        Text("Review source and tests for concrete bugs, reliability risks and maintenance work. Each finding links to the code and suggests a next step.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).surface(cornerRadius: 16)
                }
            }.frame(maxWidth: 1080, alignment: .leading).padding(24).frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .task(id: project.statsAgentID) { if let id = project.statsAgentID { await model.open(id) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Code health").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text(project.name).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { showsSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .help("Review model").popover(isPresented: $showsSettings) { settings.padding(20).frame(width: 300) }
                Button { Task { await startAnalysis() } } label: {
                    Label("Run review", systemImage: "sparkle").font(.system(size: 12, weight: .semibold)).padding(.vertical, 3)
                }.buttonStyle(.borderedProminent).tint(.teal).disabled(active)
                #if DEBUG
                    .background(DebugViewMarker(name: "stats-run-review"))
                #endif
            }
            if let scan {
                HStack(spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(.tertiary)
                    Menu {
                        ForEach(history.reversed()) { saved in
                            Button(saved.date.formatted(date: .abbreviated, time: .standard)) { selectedScanID = saved.id; severity = nil; showsFullSummary = false }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Text("· \(scan.provider?.shortName ?? "Local scan")").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let id = scan.agentSessionID, model.workspace.sessions.contains(where: { $0.id == id }) {
                        Button("Conversation") { model.openAgentChat(id) }.buttonStyle(.link)
                    }
                }.font(.caption)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review model").font(.headline)
            Picker("Agent", selection: Binding(get: { provider }, set: { value in
                model.updateProject(project.id) { $0.scanProvider = value; $0.scanModel = nil }
            })) { ForEach(AgentKind.allCases) { Text($0.shortName).tag($0) } }
            Picker("Model", selection: Binding(get: { modelID ?? "" }, set: { value in
                let selected = provider
                model.updateProject(project.id) { $0.scanProvider = selected; $0.scanModel = value.isEmpty ? nil : value }
            })) {
                Text("Agent default").tag("")
                let options = model.capabilities[provider]?.models.filter { $0.id != "default" } ?? []
                ForEach(options) { Text($0.name).tag($0.id) }
                if let modelID, !modelID.isEmpty, !options.contains(where: { $0.id == modelID }) { Text(modelID).tag(modelID) }
            }
        }
    }

    private var activity: some View {
        HStack(spacing: 12) {
            if active { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 3) {
                Text(failure ?? incompleteReview ?? (agent?.phase == .waitingForUser ? "Review needs your input" : agent?.activity ?? "Inspecting source and tests…"))
                    .font(.subheadline).lineLimit(2)
                if active { Text("Findings appear here when the agent publishes its review.").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if let agent {
                Button(agent.phase == .waitingForUser || !agent.isBusy ? "Open" : "Stop") {
                    if agent.phase == .waitingForUser || !agent.isBusy { model.openAgentChat(agent.id) } else { agent.interrupt() }
                }.controlSize(.small)
            }
        }.padding(14).background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func review(_ scan: CodeScan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let review = scan.review {
                HStack(spacing: 8) {
                    Image(systemName: "text.magnifyingglass").foregroundStyle(.teal)
                    Text("\(review.findings.count) findings").font(.headline)
                    Spacer()
                    Text("\(review.inspectedFiles.count) files inspected").font(.caption).foregroundStyle(.secondary)
                }
                Text(review.summary).font(.system(size: 14)).foregroundStyle(.secondary)
                    .lineLimit(showsFullSummary ? nil : 3).textSelection(.enabled)
                if review.summary.count > 260 {
                    Button(showsFullSummary ? "Less" : "Read full summary") { showsFullSummary.toggle() }.buttonStyle(.link).font(.caption)
                }
            } else if !active || scan.agentSessionID != agent?.id {
                Text("This scan contains inventory only").font(.headline)
                Text("Run a review to inspect the code and get source-linked findings.").foregroundStyle(.secondary).font(.subheadline)
                if let analysis = scan.analysis {
                    DisclosureGroup("Previous summary") { Text(analysis).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
    }

    private func metrics(_ inventory: ScanInventory) -> some View {
        let source = metric("Application source", inventory.sourceLines, detail: "lines of maintained code", symbol: "chevron.left.forwardslash.chevron.right")
        let tests = metric("Test code", inventory.testLines, detail: "\(inventory.testFiles.formatted()) test files · line count", symbol: "checkmark.seal")
        let generated = metric("Generated code", inventory.generatedLines, detail: "\(inventory.generatedFiles.formatted()) files · excluded above", symbol: "gearshape.2")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { source; tests; generated }.frame(minWidth: 520)
            VStack(spacing: 12) { source; tests; generated }
        }
    }

    private func metric(_ label: String, _ count: Int, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(count.formatted()).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).surface(cornerRadius: 12)
    }

    private func findings(_ report: ScanReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Needs attention").font(.headline)
                Spacer()
                Menu {
                    Button("All priorities") { severity = nil }
                    ForEach(ScanFinding.Severity.allCases, id: \.self) { item in
                        Button(item.rawValue.capitalized) { severity = item }
                    }
                } label: { Text(severity?.rawValue.capitalized ?? "All priorities") }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption)
            }
            ForEach(report.findings.filter { severity == nil || $0.severity == severity }) { finding in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(color(finding.severity)).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(finding.title).font(.system(size: 14, weight: .semibold))
                            Text("\(finding.severity.rawValue.capitalized) priority · \(finding.category.rawValue.capitalized)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(finding.impact).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button { model.openLocation(path: finding.path, line: finding.line, root: project.url) } label: {
                        Label("\(finding.path):\(finding.line)", systemImage: "doc.text").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }.buttonStyle(.link)
                    DisclosureGroup("Evidence and next step", isExpanded: Binding(get: { expanded.contains(finding.id) }, set: { value in
                        if value { expanded.insert(finding.id) } else { expanded.remove(finding.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(finding.evidence).font(.caption.monospaced()).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))
                            Text(finding.action).font(.subheadline).textSelection(.enabled)
                            Button("Work on this with an agent", systemImage: "sparkles") { Task { await investigate(finding) } }.disabled(launching)
                        }.padding(.top, 8)
                    }.font(.caption).tint(.secondary)
                }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline.opacity(0.5)) }
            }
        }
    }

    private func hotspots(_ inventory: ScanInventory) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Largest source files").font(.headline)
            ForEach(inventory.largestFiles.prefix(6)) { file in
                Button { model.openLocation(path: file.path, line: 1, root: project.url) } label: {
                    HStack {
                        Text(file.path).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(file.lines.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }.font(.caption)
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).surface(cornerRadius: 12)
    }

    private func composition(_ scan: CodeScan) -> some View {
        let languages = scan.linesByLanguage.keys.sorted { scan.linesByLanguage[$0, default: 0] > scan.linesByLanguage[$1, default: 0] }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Language mix").font(.headline)
            ForEach(languages.prefix(5), id: \.self) { language in
                let lines = scan.linesByLanguage[language, default: 0]
                VStack(spacing: 4) {
                    HStack {
                        Text(language)
                        Spacer()
                        Text(lines.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        Text("\(Int((Double(lines) / Double(max(1, scan.lines))) * 100))%").foregroundStyle(.tertiary).frame(width: 32, alignment: .trailing)
                    }.font(.caption)
                    GeometryReader { proxy in
                        Capsule().fill(Color.teal.opacity(0.1)).overlay(alignment: .leading) {
                            Capsule().fill(Color.teal.opacity(0.7)).frame(width: proxy.size.width * Double(lines) / Double(max(1, scan.lines)))
                        }
                    }.frame(height: 3)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).surface(cornerRadius: 12)
    }

    private func trend(_ scans: [CodeScan]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Maintained source over time").font(.headline)
            Chart(scans) { scan in
                LineMark(x: .value("Review", scan.date), y: .value("Source lines", scan.inventory?.sourceLines ?? 0)).foregroundStyle(.teal)
                PointMark(x: .value("Review", scan.date), y: .value("Source lines", scan.inventory?.sourceLines ?? 0)).foregroundStyle(.teal)
            }.chartYScale(domain: .automatic(includesZero: false)).frame(height: 110)
        }.padding(16).surface(cornerRadius: 12)
    }

    private func markers(_ inventory: ScanInventory) -> some View {
        DisclosureGroup("TODO and FIXME locations · \(inventory.markers.count) shown") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(inventory.markers) { marker in
                    Button { model.openLocation(path: marker.path, line: marker.line, root: project.url) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(marker.path):\(marker.line)").font(.caption.monospaced())
                            Text(marker.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 10)
        }.font(.subheadline)
    }

    private func color(_ severity: ScanFinding.Severity) -> Color {
        switch severity { case .high: .red; case .medium: .orange; case .low: .teal }
    }

    private func startAnalysis() async {
        guard !active, let session = model.selectedSession, session.projectID == project.id else { return }
        launching = true; failure = nil
        defer { launching = false }
        do {
            let worker = try await model.launchAgent(in: project, agent: provider,
                settings: AgentSettings(model: modelID, mode: session.mode),
                prompt: """
                Review this project's code health. First call project_scan_stats once and keep the returned scan.id. Use its inventory to orient yourself; generated and dependency files are separate from maintained source. Inspect application entrypoints, important handlers/services and related tests. Investigate correctness, reliability, performance, security boundaries and specific test gaps relevant to this codebase. Read at least several relevant files, trace suspected issues through callers, and verify evidence before reporting. Prioritize 3–8 concrete actionable findings if the evidence supports them. An empty findings list is valid. Do not invent risks, repeat TODO text as a bug, derive coverage or quality from line counts, or claim tests ran unless you ran them. Each finding requires an exact source excerpt, relative path and line, impact and a specific next action. Call project_publish_scan_review with scanID and a JSON review containing summary, inspectedFiles and findings per its schema. Summary should use at most three short sentences (600 characters) to explain the main engineering concerns and inspected scope. Keep project files unchanged. Finish with a concise result.
                """, parentSessionID: session.id, isolated: false)
            selectedScanID = nil; severity = nil
            model.updateProject(project.id) { $0.statsAgentID = worker.id }
        } catch { failure = error.localizedDescription }
    }

    private func investigate(_ finding: ScanFinding) async {
        guard let session = model.selectedSession, !launching else { return }
        launching = true; failure = nil
        defer { launching = false }
        do {
            let task = "Investigate this code-review finding, verify it against current code, and fix it if valid. Add a focused regression check where appropriate.\n\n\(finding.title)\n\(finding.path):\(finding.line)\nEvidence: \(finding.evidence)\nImpact: \(finding.impact)\nSuggested next step: \(finding.action)"
            let worker = try await model.launchAgent(in: project, agent: provider, settings: AgentSettings(model: modelID, mode: session.mode), prompt: task, parentSessionID: session.id)
            model.openAgentChat(worker.id)
        } catch { failure = error.localizedDescription }
    }
}
