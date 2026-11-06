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
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Pipelines").font(.title2.bold())
                    Spacer()
                    Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Reload workflows")
                }
                if loading { ProgressView().controlSize(.small) }
                else if jobs.isEmpty {
                    Text("Add a workflow under .github/workflows to run a job here.").foregroundStyle(.secondary)
                } else {
                    Picker("Job", selection: $selection) {
                        ForEach(jobs) { job in
                            Text(job.workflow.isEmpty ? "Swift package · Local Mac" : "\(URL(fileURLWithPath: job.workflow).lastPathComponent) · \(job.job) · \(job.event)").tag(job.id)
                        }
                    }
                    if let job {
                        if let reason = job.reason { Label(reason, systemImage: "info.circle").foregroundStyle(.secondary) }
                        else if !job.workflow.isEmpty {
                            TextField("Docker runner image", text: $image).textFieldStyle(.roundedBorder)
                            Text("Docker · \(job.runner)").font(.caption).foregroundStyle(.secondary)
                        }
                        if runner?.active != nil {
                            Button("Stop run", systemImage: "stop.fill") { runner?.stop() }
                        } else {
                            Button("Run pipeline", systemImage: "play.fill") {
                                selectedRun = nil
                                model.runPipeline(job, project: project, image: image)
                            }.buttonStyle(.borderedProminent)
                                .disabled(job.reason != nil || (!job.workflow.isEmpty && image.isEmpty))
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if !history.isEmpty, runner?.active == nil {
                    Picker("Saved runs", selection: Binding(get: { result?.id }, set: { selectedRun = $0 })) {
                        ForEach(history.reversed()) { run in
                            Text("\(run.date.formatted()) · \(run.title) · \(run.status)").tag(Optional(run.id))
                        }
                    }
                }
                if let result {
                    Divider()
                    HStack {
                        if runner?.active != nil { ProgressView().controlSize(.small) }
                        Text(result.status).font(.headline)
                        Text(result.runner).foregroundStyle(.secondary)
                    }
                    if runner?.active == nil, let savedJob = jobs.first(where: { $0.id == result.jobID }), savedJob.reason == nil {
                        Button("Run again", systemImage: "arrow.clockwise") {
                            selectedRun = nil
                            selection = savedJob.id
                            if let savedImage = result.image { image = savedImage }
                            model.runPipeline(savedJob, project: project, image: image)
                        }
                    }
                    if result.status.hasPrefix("Failed") {
                        Button("Ask agent about failure", systemImage: "sparkles") {
                            Task { await explain(result) }
                        }.disabled(asking)
                    }
                    Text(result.log.isEmpty ? "Waiting for output…" : result.log)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(maxWidth: 900, alignment: .leading)
        }
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
