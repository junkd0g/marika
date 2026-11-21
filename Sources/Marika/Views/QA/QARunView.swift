import AppKit
import MarikaCore
import SwiftUI
import UniformTypeIdentifiers

struct QARunView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Bindable var qa: QAWorkspace
    let runID: UUID
    @State private var image: QAEvidence?
    private var run: QARun? { qa.data.runs.first { $0.id == runID } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let run {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(run.name).font(.title2.weight(.semibold))
                        Text("\(run.mode.rawValue) · \(run.environment) · \(run.build)").font(.callout).foregroundStyle(.secondary)
                        Text(run.url).font(.caption).textSelection(.enabled)
                        HStack(spacing: 12) {
                            ForEach(QAStatus.allCases, id: \.self) { status in
                                VStack { Text("\(run.counts[status, default: 0])").font(.title3.monospacedDigit()); Text(status.rawValue).font(.caption2) }
                                    .foregroundStyle(status.color)
                            }
                        }
                        Text(qa.runFreshness[runID] ?? run.freshnessNote ?? "Checking source version…")
                            .font(.caption).foregroundStyle(.secondary)
                        if run.mode != .playwright {
                            Text("Results cover these \(run.cases.count) cases only. Browser width previews do not emulate a real mobile device.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { runActions(run) }
                            VStack(alignment: .leading) { runActions(run) }
                        }.buttonStyle(WorkspaceButtonStyle(compact: true))
                        Divider()
                        ForEach(run.cases) { result in
                            caseResult(result, run: run).id(result.id)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task(id: qa.selectedCaseID) {
                if let id = qa.selectedCaseID { proxy.scrollTo(id, anchor: .top) }
            }
        }
        #if DEBUG
        .background(DebugViewMarker(name: "qa-run-" + runID.uuidString))
        #endif
        .sheet(item: $image) { QAEvidenceView(qa: qa, evidence: $0) }
        .task(id: runID) {
            while !Task.isCancelled {
                await qa.checkFreshness(runID)
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    @ViewBuilder private func runActions(_ run: QARun) -> some View {
        if qa.replayTask != nil { Button("Stop replay", role: .destructive) { qa.replayTask?.cancel() } }
        else if run.finishedAt == nil {
            Button("Finish run") { Task { await qa.finishRun(runID) } }
        } else if run.mode != .playwright {
            Button("Retest cases", systemImage: "arrow.clockwise") {
                Task { await perform {
                    let cases = try run.cases.map { old in
                        guard let current = qa.data.cases.first(where: { $0.id == old.id && !$0.archived && $0.approved }) else {
                            throw QAError("Review and approve each current case before retesting.")
                        }
                        return current
                    }
                    if run.mode == .replay, let test = cases.first, cases.count == 1 {
                        try await qa.replay(test, retesting: runID)
                    } else { _ = try await qa.startRun(cases: cases, retesting: runID) }
                } }
            }.disabled(qa.busy)
        }
        Button("Export report…", systemImage: "square.and.arrow.up") { export(run) }
        Button("Check source version") { Task { await qa.checkFreshness(runID) } }
    }

    private func caseResult(_ result: QACaseResult, run: QARun) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(result.testCase.title).font(.headline); Spacer(); Text(result.status.rawValue).font(.caption).foregroundStyle(result.status.color) }
            if !result.testCase.requirement.isEmpty { Text(result.testCase.requirement).font(.caption).foregroundStyle(.secondary) }
            if !result.testCase.preconditions.isEmpty { Text("Preconditions: " + result.testCase.preconditions).font(.caption) }
            if let observations = result.playwright {
                ForEach(observations) { observation in playwrightResult(observation, caseID: result.id) }
                if result.testCase.baseline != nil {
                    Text("This report did not check the Marika visual baseline.").font(.caption).foregroundStyle(.secondary)
                }
            } else { localResults(result, run: run) }
            Divider()
        }
    }

    @ViewBuilder private func localResults(_ result: QACaseResult, run: QARun) -> some View {
        ForEach(Array(result.testCase.steps.enumerated()), id: \.element.id) { index, step in
            stepResult(step, index: index, result: result, run: run)
        }
        if result.testCase.baseline != nil {
            Button("Compare with visual baseline", systemImage: "square.on.square") {
                Task { await perform { try await qa.compareBaseline(runID: runID, caseID: result.id) } }
            }.disabled(run.finishedAt != nil || qa.busy || qa.isComparing(runID: runID, caseID: result.id))
                .buttonStyle(WorkspaceButtonStyle(compact: true))
            Text("Same-size captures; 12/255 channel tolerance and up to 0.5% changed pixels. Review differences before replacing a baseline.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if let error = result.visualError {
            Label("Visual check incomplete", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.attention)
            Text(error).font(.caption).textSelection(.enabled)
        }
        if let visual = result.visual, result.visualError == nil {
            Text("Visual check: \(visual.passed ? "Passed" : "Failed") · \(String(format: "%.2f", visual.changedFraction * 100))% changed")
                .font(.callout).foregroundStyle(visual.passed ? Color.green : .red)
            HStack {
                Button("Baseline") { image = visual.baseline }
                Button("Actual") { image = visual.actual }
                if let difference = visual.difference { Button("Difference") { image = difference } }
            }.buttonStyle(WorkspaceButtonStyle(compact: true))
            if !visual.passed {
                if let ticketID = visual.ticketID, let location = model.ticketLocation(ticketID) {
                    Button("Open visual bug \(location.ticket.key)") { model.openSpaceSection(.tickets); model.spaceTicketSelections[location.spaceID] = ticketID }
                } else {
                    Button("Create visual bug", systemImage: "ladybug") {
                        Task { await perform { _ = try await model.createQAVisualBug(project: project, runID: runID, caseID: result.id) } }
                    }.buttonStyle(WorkspaceButtonStyle(compact: true))
                }
            }
        }
    }

    private func playwrightResult(_ result: QAPlaywrightResult, caseID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.browserProject.isEmpty ? "Default Playwright project" : result.browserProject).font(.headline)
            if let browser = result.browser, browser != result.browserProject {
                Text(browser).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(result.status.rawValue) · \(result.outcome) · \(result.attempts) attempts")
                .font(.caption).foregroundStyle(result.status.color)
            if !result.error.isEmpty { Text(result.error).font(.caption.monospaced()).textSelection(.enabled) }
            if let hint = result.traceHint, result.traceID == nil {
                Text("Reported trace: " + hint).font(.caption)
            }
            ViewThatFits(in: .horizontal) {
                HStack { playwrightButtons(result, caseID: caseID) }
                VStack(alignment: .leading) { playwrightButtons(result, caseID: caseID) }
            }.buttonStyle(WorkspaceButtonStyle(compact: true))
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func playwrightButtons(_ result: QAPlaywrightResult, caseID: UUID) -> some View {
        if let id = result.traceID {
            Button("Open trace", systemImage: "arrow.up.right.square") {
                NSWorkspace.shared.open(URL(string: "https://trace.playwright.dev/")!)
                NSWorkspace.shared.activateFileViewerSelecting([qa.traceURL(id)])
            }.help("Drag the selected ZIP from Finder into Playwright Trace Viewer.")
        }
        Button(result.traceID == nil ? "Attach trace…" : "Replace trace…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.zip]
            if panel.runModal() == .OK, let url = panel.url {
                Task { await perform { try await qa.attachPlaywrightTrace(url, runID: runID, caseID: caseID, resultID: result.id) } }
            }
        }.disabled(qa.busy)
        if let ticketID = result.ticketID, let ticket = model.ticketLocation(ticketID)?.ticket {
            Button(ticket.key, systemImage: "ticket") { model.openTicket(ticketID) }
        } else if result.status == .failed {
            Button("Create bug", systemImage: "ladybug") {
                Task { await perform { model.openTicket(try await model.createQAPlaywrightBug(project: project, runID: runID, caseID: caseID, resultID: result.id)) } }
            }.disabled(qa.busy)
        }
    }

    private func stepResult(_ step: QAStep, index: Int, result: QACaseResult, run: QARun) -> some View {
        let observed = result.steps[index]
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(index + 1). \(step.action)").font(.system(size: 13, weight: .semibold))
            Text("Expected: " + step.expected).font(.caption).foregroundStyle(.secondary)
            Picker("Result", selection: Binding(get: { observed.status }, set: { status in
                qa.changeResult(runID: runID, caseID: result.id, step: index) { $0.status = status }
            })) { ForEach(QAStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .accessibilityLabel("Result for step \(index + 1)")
                .disabled(run.finishedAt != nil || run.mode == .replay).frame(maxWidth: 250)
            if run.finishedAt != nil || run.mode == .replay {
                Text(observed.actual.isEmpty ? "No observation recorded" : observed.actual)
                    .font(.callout).foregroundStyle(observed.actual.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Actual result / notes", text: Binding(get: { observed.actual }, set: { text in
                    qa.changeResult(runID: runID, caseID: result.id, step: index) { $0.actual = String(text.prefix(12_000)) }
                }), axis: .vertical).lineLimit(2...6).textFieldStyle(.workspace)
                    .accessibilityLabel("Actual result for step \(index + 1)")
            }
            evidenceActions(result, run: run, index: index)
            ForEach(observed.evidence) { item in
                Button(item.title + " · " + item.date.formatted(date: .omitted, time: .shortened), systemImage: "photo") { image = item }
                    .font(.caption).buttonStyle(.link)
            }
        }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func evidenceActions(_ result: QACaseResult, run: QARun, index: Int) -> some View {
        let observed = result.steps[index]
        return ViewThatFits(in: .horizontal) {
            HStack { evidenceButtons(result, run: run, index: index, observed: observed) }
            VStack(alignment: .leading, spacing: 6) { evidenceButtons(result, run: run, index: index, observed: observed) }
        }.buttonStyle(WorkspaceButtonStyle(compact: true))
    }
    @ViewBuilder private func evidenceButtons(_ result: QACaseResult, run: QARun, index: Int, observed: QAStepResult) -> some View {
        if run.finishedAt == nil {
            Button("Screenshot", systemImage: "camera") { Task { await perform { try await qa.attachImage(runID: runID, caseID: result.id, step: index) } } }.disabled(qa.busy).accessibilityLabel("Screenshot for step \(index + 1)")
            Button("Attach image…") { importImage(caseID: result.id, step: index) }.disabled(qa.busy).accessibilityLabel("Attach image to step \(index + 1)")
        }
        if let ticketID = observed.ticketID, let location = model.ticketLocation(ticketID) {
            Button(location.ticket.key, systemImage: "ticket") { model.openSpaceSection(.tickets); model.spaceTicketSelections[location.spaceID] = ticketID }
        } else if [.failed, .blocked].contains(observed.status) {
            Button("Create bug", systemImage: "ladybug") {
                Task { await perform { _ = try await model.createQABug(project: project, runID: runID, caseID: result.id, step: index) } }
            }.disabled(observed.actual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        do { try await action(); qa.error = nil } catch { qa.error = error.localizedDescription }
    }
    private func importImage(caseID: UUID, step: Int) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await perform { try await qa.attachImage(runID: runID, caseID: caseID, step: step, input: Data(contentsOf: url)) } }
    }
    private func export(_ run: QARun) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Export report"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            await qa.checkFreshness(run.id)
            export(run, to: destination)
        }
    }
    private func export(_ run: QARun, to destination: URL) {
        do {
            let folder = destination.appendingPathComponent("QA-" + run.id.uuidString)
            let images = folder.appendingPathComponent("evidence", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            var report = QATools.report(run)
            let evidence = run.cases.flatMap { result in
                result.steps.flatMap(\.evidence) + (result.visual.map { [$0.baseline, $0.actual] + ($0.difference.map { [$0] } ?? []) } ?? [])
            }
            for item in Set(evidence) {
                guard let source = qa.evidenceURL(item) else { continue }
                let target = images.appendingPathComponent(item.filename)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
                report += "\n\n![Evidence](evidence/\(item.filename))"
            }
            for id in Set(run.cases.flatMap { ($0.playwright ?? []).compactMap(\.traceID) }) {
                let source = qa.traceURL(id), target = images.appendingPathComponent(source.lastPathComponent)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
                report += "\n\n[Playwright trace](evidence/\(source.lastPathComponent))"
            }
            if let freshness = qa.runFreshness[run.id] { report += "\n\nExport-time source check: " + freshness }
            try report.write(to: folder.appendingPathComponent("Report.md"), atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { qa.error = error.localizedDescription }
    }
}

extension QAStatus {
    var color: Color {
        switch self { case .passed: .green; case .failed: .red; case .blocked: .orange; case .notTested: .secondary }
    }
}
