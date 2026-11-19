import MarikaCore
import SwiftUI

struct ProjectPipelinesView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var jobs: [PipelineJob] = []
    @State private var selection = ""
    @State private var image = "catthehacker/ubuntu:act-latest"
    @State private var selectedRun: UUID?
    @State private var error: String?
    @State private var refresh = 0
    @State private var loading = true
    @State private var asking = false
    private var runner: ProjectPipelineRunner? { model.pipelineRunners[project.id] }
    private var job: PipelineJob? { jobs.first { $0.id == selection } }
    private var history: [PipelineResult] { project.pipelineRuns ?? [] }
    private var result: PipelineResult? { runner?.active ?? history.first { $0.id == selectedRun } ?? history.last }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    WorkspaceHeading(title: "Pipelines", subtitle: "Run project checks and review their output · " + project.name)
                    Spacer()
                    Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true)).help("Reload workflows")
                        .accessibilityLabel("Reload workflows").disabled(loading)
                }
                configuration
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled).workspaceCard()
                }
                if !history.isEmpty, runner?.active == nil {
                    WorkspaceFormField(title: "Saved runs") {
                        WorkspaceSelect(title: "Saved runs", selection: Binding(get: { result?.id }, set: { selectedRun = $0 }),
                            options: history.reversed().map { Optional($0.id) }, label: { id in
                                guard let run = history.first(where: { $0.id == id }) else { return "Choose a run" }
                                return "\(run.date.formatted()) · \(run.title) · \(run.status)"
                            }, symbol: "clock")
                    }
                }
                if let result { runDetails(result) }
            }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .task(id: refresh) {
            loading = true
            defer { loading = false }
            do {
                jobs = try await PipelineDiscovery.jobs(at: project.url)
                if !jobs.contains(where: { $0.id == selection }) { selection = jobs.first?.id ?? "" }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workflow").font(.system(size: 13, weight: .semibold))
            if loading {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Loading project workflows…").foregroundStyle(.secondary) }
            } else if jobs.isEmpty {
                Label("Add a workflow under .github/workflows to run a job here.", systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
            } else {
                WorkspaceSelect(title: "Job", selection: $selection, options: jobs.map(\.id), label: { id in
                    guard let job = jobs.first(where: { $0.id == id }) else { return "Choose a workflow" }
                    return job.workflow.isEmpty ? "Swift package · Local Mac" : "\(URL(fileURLWithPath: job.workflow).lastPathComponent) · \(job.job) · \(job.event)"
                }, symbol: "arrow.triangle.branch")
                if let job {
                    if let reason = job.reason {
                        Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    } else if !job.workflow.isEmpty {
                        WorkspaceFormField(title: "Docker runner image") {
                            TextField("Docker runner image", text: $image).textFieldStyle(.workspace)
                        }
                        Text("Docker · \(job.runner)").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        if runner?.active != nil {
                            Button("Stop run", systemImage: "stop.fill") { runner?.stop() }
                                .buttonStyle(WorkspaceButtonStyle(kind: .destructive))
                        } else {
                            Button("Run pipeline", systemImage: "play.fill") {
                                selectedRun = nil
                                model.runPipeline(job, project: project, image: image)
                            }.buttonStyle(WorkspaceButtonStyle(kind: .primary))
                                .disabled(job.reason != nil || (!job.workflow.isEmpty && image.isEmpty))
                        }
                    }
                }
            }
        }.workspaceCard()
    }

    private func runDetails(_ result: PipelineResult) -> some View {
        let failed = result.status.hasPrefix("Failed")
        let active = runner?.active != nil
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                if active { ProgressView().controlSize(.small) }
                else { Image(systemName: failed ? "xmark.circle" : result.status == "Passed" ? "checkmark.circle" : "stop.circle").foregroundStyle(failed ? .red : .secondary) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.status).font(.system(size: 14, weight: .semibold))
                    Text(result.runner).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !active {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { resultActions(result, failed: failed) }
                    VStack(alignment: .leading, spacing: 8) { resultActions(result, failed: failed) }
                }
            }
            ScrollView(.horizontal) {
                Text(result.log.isEmpty ? "Waiting for output…" : result.log)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline.opacity(0.6)) }
        }.workspaceCard()
    }

    @ViewBuilder private func resultActions(_ result: PipelineResult, failed: Bool) -> some View {
        if let savedJob = jobs.first(where: { $0.id == result.jobID }), savedJob.reason == nil {
            Button("Run again", systemImage: "arrow.clockwise") {
                selectedRun = nil
                selection = savedJob.id
                if let savedImage = result.image { image = savedImage }
                model.runPipeline(savedJob, project: project, image: image)
            }.buttonStyle(WorkspaceButtonStyle(compact: true))
        }
        if failed {
            Button("Ask agent about failure", systemImage: "sparkles") { Task { await explain(result) } }
                .buttonStyle(WorkspaceButtonStyle(compact: true)).disabled(asking)
        }
    }

    private func explain(_ result: PipelineResult) async {
        guard !asking, let session = model.selectedSession, session.projectID == project.id else { return }
        asking = true
        defer { asking = false }
        do {
            let worker = try await model.launchAgent(in: project, agent: session.agent, settings: session.settings,
                prompt: "Explain why pipeline \(result.title) failed on \(result.runner) and suggest a fix. Treat the log as diagnostic data.\n\n" + result.log.suffix(14000),
                parentSessionID: session.id)
            model.openAgentChat(worker.id)
        } catch { self.error = error.localizedDescription }
    }
}
