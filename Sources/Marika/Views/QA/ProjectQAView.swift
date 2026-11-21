import AppKit
import MarikaCore
import SwiftUI
import UniformTypeIdentifiers

struct ProjectQAView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Bindable var qa: QAWorkspace
    @State private var editing: QACase?
    @State private var showsGenerator = false
    @State private var showsDrafts = false
    @State private var image: QAEvidence?
    @State private var showArchived = false

    private var cases: [QACase] { qa.data.cases.filter { $0.archived == showArchived } }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                environment
                if let error = qa.error {
                    HStack { Text(error).font(.caption).textSelection(.enabled); Spacer(); Button("Dismiss") { qa.error = nil } }
                        .foregroundStyle(Theme.attention).padding(12)
                }
                Divider()
                if geometry.size.width < 650, qa.section != "Release" { compactPicker.padding(12) }
                HStack(spacing: 0) {
                    if geometry.size.width >= 650, qa.section != "Release" { sidebar.frame(width: 205); Divider() }
                    Group {
                        if qa.section == "Release" { QAReleaseView(qa: qa) }
                        else if qa.section == "Runs", let run = qa.selectedRun {
                            QARunView(project: project, qa: qa, runID: run.id)
                        } else if qa.section == "Cases", let test = qa.selectedCase {
                            caseDetail(test)
                        } else { emptyState }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(Theme.canvas)
        }
        .sheet(item: $editing) { value in
            QACaseEditor(value: value) { edited in try qa.saveCase(edited) }
        }
        .sheet(isPresented: $showsGenerator) { QAGenerateView(project: project, qa: qa) }
        .sheet(isPresented: $showsDrafts) { QADraftsView(qa: qa) }
        .sheet(item: $image) { QAEvidenceView(qa: qa, evidence: image ?? $0) }
        .onChange(of: model.projectRuntimeTools[project.id]?.browser?.annotation) { _, selection in perform { try qa.acceptCheckpoint(selection) } }
        #if DEBUG
        .background(DebugViewMarker(name: "project-qa"))
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality assurance").font(.system(size: qa.section == "Release" ? 16 : 22, weight: .semibold))
                    if qa.section != "Release" {
                        Text("\(qa.data.cases.filter(\.approved).count) approved cases · \(qa.data.runs.count) saved runs")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if qa.busy { ProgressView().controlSize(.small) }
                Picker("QA section", selection: $qa.section) {
                    Text("Cases").tag("Cases")
                    Text("Runs").tag("Runs")
                    Text("Release").tag("Release")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 205)
            }
            if qa.section != "Release" {
                ViewThatFits(in: .horizontal) {
                    HStack { buttons }
                    VStack(alignment: .leading, spacing: 8) { HStack { createButtons }; HStack { browserButtons } }
                }.buttonStyle(WorkspaceButtonStyle(compact: true))
            } else if qa.recording {
                HStack { browserButtons }.buttonStyle(WorkspaceButtonStyle(compact: true))
            }
        }.padding(.horizontal, 22).padding(.top, 17).padding(.bottom, qa.section == "Release" ? 12 : 17)
    }
    @ViewBuilder private var buttons: some View { createButtons; Spacer(minLength: 8); browserButtons }
    @ViewBuilder private var createButtons: some View {
        Button("New case", systemImage: "plus") { editing = QACase(title: "", steps: [QAStep(action: "", expected: "")]) }
        Button("Draft cases", systemImage: "sparkles") { showsGenerator = true }
        Button("Run suite") { Task { await performAsync { _ = try await qa.startRun(cases: qa.data.cases.filter { $0.approved && !$0.archived }) } } }
            .disabled(qa.busy || !qa.data.cases.contains(where: { $0.approved && !$0.archived }))
        Button("Import CI report…", systemImage: "square.and.arrow.down") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.message = "Choose a Playwright JSON report for the QA environment and build entered here."
            if panel.runModal() == .OK, let url = panel.url {
                Task { await performAsync { try await qa.importPlaywrightReport(url) } }
            }
        }.disabled(qa.busy)
        if !qa.data.drafts.isEmpty { Button("Drafts (\(qa.data.drafts.count))") { showsDrafts = true } }
    }
    @ViewBuilder private var browserButtons: some View {
        Button(qa.recording ? "Stop recording (\(qa.recordingActions.count))" : "Record journey", systemImage: qa.recording ? "stop.circle.fill" : "record.circle") {
            perform { if qa.recording { try qa.stopRecording() } else { try qa.startRecording() } }
        }.disabled(qa.busy)
        Button("Browser", systemImage: "globe") { qa.openBrowser() }
    }
    private var environment: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { environmentFields }.frame(minWidth: 440)
            VStack(spacing: 8) { environmentFields }
        }.textFieldStyle(.workspace).font(.system(size: 12)).padding(.horizontal, 22).padding(.bottom, 14)
    }
    @ViewBuilder private var environmentFields: some View {
        if qa.section == "Release" {
            WorkspaceFormField(title: "Environment") { environmentInput }
            WorkspaceFormField(title: "Build identifier") { buildInput }
            WorkspaceFormField(title: "Test URL") { urlInput }
        } else {
            environmentInput
            buildInput
            urlInput
        }
    }
    private var environmentInput: some View {
        TextField("Environment", text: $qa.data.environment).accessibilityLabel("QA environment")
    }
    private var buildInput: some View {
        TextField("Build identifier", text: $qa.data.build).accessibilityLabel("QA build")
    }
    private var urlInput: some View {
        TextField(qa.section == "Release" ? "https://…" : "Test URL", text: $qa.data.url).accessibilityLabel("QA test URL")
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if qa.section == "Cases" {
                Toggle("Show archived", isOn: $showArchived).font(.caption).padding(12)
                List(cases, selection: $qa.selectedCaseID) { test in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(test.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text(test.approved ? "Approved · v\(test.revision)" : "Draft · review required").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(test.id)
                }.listStyle(.sidebar)
            } else {
                List(qa.data.runs.reversed(), selection: $qa.selectedRunID) { run in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text(run.startedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                        Text(run.finishedAt == nil ? "In progress" : "\(run.counts[.failed, default: 0]) failed · \(run.counts[.passed, default: 0]) passed").font(.caption2)
                    }.padding(.vertical, 5).tag(run.id).contextMenu {
                        Button("Remove saved run", role: .destructive) {
                            qa.data.runs.removeAll { $0.id == run.id }
                            if qa.selectedRunID == run.id { qa.selectedRunID = qa.data.runs.last?.id }
                        }.disabled(run.finishedAt == nil || qa.busy)
                    }
                }.listStyle(.sidebar)
            }
        }
    }
    private var compactPicker: some View {
        Group {
            if qa.section == "Cases" {
                Picker("Case", selection: $qa.selectedCaseID) {
                    Text("Choose case").tag(Optional<UUID>.none)
                    ForEach(cases) { Text($0.title).tag(Optional($0.id)) }
                }
            } else {
                Picker("Run", selection: $qa.selectedRunID) {
                    Text("Choose run").tag(Optional<UUID>.none)
                    ForEach(qa.data.runs.reversed()) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        }
    }

    private func caseDetail(_ test: QACase) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text(test.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Spacer()
                    Menu {
                        Button("Edit case") { editing = test }
                        Button(test.archived ? "Restore" : "Archive") { qa.archiveCase(test.id) }
                        Button("Export Playwright test…") { exportReplay(test) }.disabled(!test.canReplay)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
                Text(test.approved ? "Approved · revision \(test.revision)" : "Draft — review steps and expected results, then approve")
                    .font(.caption).foregroundStyle(test.approved ? Color.green : .secondary)
                if !test.requirement.isEmpty { Text(test.requirement).font(.body).textSelection(.enabled) }
                if !test.preconditions.isEmpty { VStack(alignment: .leading, spacing: 5) { Text("Preconditions").font(.headline); Text(test.preconditions).textSelection(.enabled) } }
                if let id = test.ticketID, let space = project.spaceID, let ticket = model.ticket(id, in: space) {
                    Button("Requirement: \(ticket.key)") { model.openSpaceSection(.tickets); model.spaceTicketSelections[space] = id }
                }
                if let run = qa.data.runs.filter({ $0.mode == .playwright && $0.cases.contains(where: { $0.id == test.id }) })
                    .max(by: { $0.startedAt < $1.startedAt }),
                   let result = run.cases.first(where: { $0.id == test.id }) {
                    Button("Latest CI result · \(run.build) · v\(result.testCase.revision)", systemImage: "checklist") {
                        qa.selectedRunID = run.id
                        qa.section = "Runs"
                    }.buttonStyle(.link)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { caseActions(test) }
                    VStack(alignment: .leading, spacing: 8) { caseActions(test) }
                }.buttonStyle(WorkspaceButtonStyle(compact: true))
                Divider()
                ForEach(Array(test.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.action).font(.system(size: 13, weight: .medium))
                            Text("Expected: " + step.expected).font(.system(size: 12)).foregroundStyle(.secondary)
                            if step.automation?.isAssertion == true { Label("Replay checkpoint", systemImage: "checkmark.viewfinder").font(.caption2).foregroundStyle(.secondary) }
                        }.textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                }
                if test.steps.contains(where: { $0.automation != nil }) {
                    Text("Recorded actions replay in WebKit. Add a checkpoint for an observable result; protected inputs require manual testing. Export Playwright to run in other browsers.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(qa.pickingCheckpoint ? "Click the expected element in Browser…" : "Pick a checkpoint in Browser", systemImage: "cursorarrow.click") {
                        Task { await performAsync { try await qa.addCheckpoint() } }
                    }.disabled(qa.pickingCheckpoint || qa.busy)
                }
                HStack {
                    Button(test.baseline == nil ? "Capture visual baseline" : "Replace visual baseline") {
                        Task { await performAsync { try await qa.captureBaseline(test.id) } }
                    }.disabled(qa.busy)
                    if let baseline = test.baseline { Button("View baseline") { image = baseline } }
                }.buttonStyle(WorkspaceButtonStyle(compact: true))
                Text("Baseline capture requires the tested page visible in Browser. Replacing a baseline requires case approval again.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func caseActions(_ test: QACase) -> some View {
        if !test.approved { Button("Approve case") { perform { try qa.approveCase(test.id) } } }
        Button("Run manually", systemImage: "play") { Task { await performAsync { _ = try await qa.startRun(cases: [test]) } } }
            .disabled(!test.approved || qa.busy)
        Button("Replay web journey", systemImage: "arrow.clockwise") { Task { await performAsync { try await qa.replay(test) } } }
            .disabled(!test.canReplay || qa.busy || qa.recording)
    }
    private var emptyState: some View {
        ContentUnavailableView("Test the complete journey", systemImage: "checklist", description: Text("Create a case, draft cases from a requirement, or record a browser journey. Results stay linked to their tested build."))
    }
    private func perform(_ action: () throws -> Void) { do { try action(); qa.error = nil } catch { qa.error = error.localizedDescription } }
    private func performAsync(_ action: () async throws -> Void) async { do { try await action(); qa.error = nil } catch { qa.error = error.localizedDescription } }
    private func exportReplay(_ test: QACase) {
        perform {
            let text = try QATools.playwright(test)
            let panel = NSSavePanel(); panel.nameFieldStringValue = "qa-journey.spec.ts"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct QAEvidenceView: View {
    let qa: QAWorkspace
    let evidence: QAEvidence
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(evidence.title).font(.headline); Spacer(); Button("Done") { dismiss() } }
            Text("\(evidence.width) × \(evidence.height) · \(evidence.date.formatted())").font(.caption).foregroundStyle(.secondary)
            if let url = qa.evidenceURL(evidence), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else { ContentUnavailableView("Evidence file unavailable", systemImage: "photo") }
        }.padding(20).frame(minWidth: 620, idealWidth: 900, minHeight: 440, idealHeight: 650)
    }
}
