import AppKit
import MarikaCore
import SwiftUI

struct ProjectArtifactsView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var selectedID: UUID?
    @State private var allProjects = false
    @State private var task = ""
    @State private var comment = ""
    @State private var line = 1
    @State private var imageIndex = 0
    @State private var error: String?
    @State private var launching = false
    private var artifacts: [(Project, ProjectArtifact)] {
        (allProjects ? model.workspace.projects : [model.project(id: project.id) ?? project])
            .flatMap { project in (project.artifacts ?? []).map { (project, $0) } }
            .sorted { $0.1.date > $1.1.date }
    }
    private var selected: (Project, ProjectArtifact)? { artifacts.first { $0.1.id == selectedID } ?? artifacts.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Describe a task to plan…", text: $task).textFieldStyle(.roundedBorder)
                Button("Draft plan") { launchPlan() }.disabled(launching || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Text("Plans, walkthroughs, and observed browser steps").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("All projects", isOn: $allProjects).toggleStyle(.checkbox)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(artifacts, id: \.1.id) { owner, artifact in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(artifact.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(artifact.kind.rawValue + (artifact.approved ? " · Reviewed" : "")).font(.caption).foregroundStyle(.secondary)
                            if allProjects { Text(owner.name).font(.caption2).foregroundStyle(.tertiary) }
                        }.padding(.vertical, 4).tag(artifact.id)
                    }
                }.frame(width: 215)
                Divider()
                if let (owner, artifact) = selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(artifact.title).font(.title2.bold())
                            HStack {
                                Text(artifact.kind.rawValue + " · " + artifact.date.formatted()).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Open agent") { model.experienceProjectID = nil; model.openAgentChat(artifact.sessionID) }
                            }
                            MarkdownView(text: artifact.body).environment(\.projectRoot, owner.url).textSelection(.enabled)
                            if !artifact.images.isEmpty { images(artifact) }
                            if artifact.kind != .browser { review(artifact, owner: owner) }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }.id(artifact.id)
                } else {
                    ContentUnavailableView("Work you can review", systemImage: "doc.text.magnifyingglass", description: Text("Draft a plan above. Agent reports and browser evidence are saved here as work progresses."))
                        .frame(maxWidth: .infinity)
                }
            }.overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline) }
        }.onChange(of: selected?.1.id) { imageIndex = 0; line = 1; comment = "" }
    }
    private func review(_ artifact: ProjectArtifact, owner: Project) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Review comments").font(.headline)
            ForEach(artifact.comments) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Line \(note.line)").font(.caption).foregroundStyle(.secondary)
                    Text(note.text).font(.callout)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).surface()
            }
            let lines = artifact.body.components(separatedBy: "\n")
            Stepper("Comment on line \(line)", value: $line, in: 1...max(1, lines.count)).font(.caption)
            Text(lines.indices.contains(line - 1) ? lines[line - 1] : "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                TextField("Feedback on this passage", text: $comment).textFieldStyle(.roundedBorder)
                Button("Add") {
                    model.updateProject(owner.id) { current in
                        if let index = current.artifacts?.firstIndex(where: { $0.id == artifact.id }) {
                            current.artifacts?[index].comments.append(ArtifactComment(line: line, text: String(comment.prefix(4000))))
                        }
                    }
                    comment = ""
                }.disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Send review") { Task { await model.submitArtifact(artifact, projectID: owner.id, approve: false) } }.disabled(artifact.comments.isEmpty || model.controllers[artifact.sessionID]?.isBusy == true)
                Spacer()
                if artifact.kind == .plan {
                    Button(artifact.approved ? "Continue implementation" : "Approve and implement") { Task { await model.submitArtifact(artifact, projectID: owner.id, approve: true) } }
                        .buttonStyle(.borderedProminent).disabled(model.controllers[artifact.sessionID]?.isBusy == true)
                } else {
                    Button(artifact.approved ? "Reviewed" : "Mark reviewed") {
                        model.updateProject(owner.id) { current in
                            if let index = current.artifacts?.firstIndex(where: { $0.id == artifact.id }) { current.artifacts?[index].approved = true }
                        }
                    }.disabled(artifact.approved)
                }
            }
        }
    }
    private func images(_ artifact: ProjectArtifact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let index = min(imageIndex, artifact.images.count - 1)
            let name = artifact.images[index]
            if name == URL(fileURLWithPath: name).lastPathComponent,
               let image = NSImage(contentsOf: model.store.root.appendingPathComponent("browser-evidence").appendingPathComponent(name)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 310)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button { imageIndex = max(0, index - 1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                Text("Browser step \(index + 1) of \(artifact.images.count)").font(.caption)
                Button { imageIndex = min(artifact.images.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }.disabled(index == artifact.images.count - 1)
            }
        }
    }
    private func launchPlan() {
        launching = true
        Task {
            defer { launching = false }
            do {
                let session = try await model.launchAgent(in: project, agent: model.selectedSession?.agent ?? .codex,
                    settings: AgentSettings(model: model.selectedSession?.model, mode: .plan),
                    prompt: "Plan this task only; do not change files. Inspect the code, propose changes with concrete file references, risks, and verification steps. Publish a Plan with project_publish_artifact, then stop for review.\n\n" + task, isolated: false)
                model.experienceProjectID = nil
                model.openAgentChat(session.id)
            } catch { self.error = error.localizedDescription }
        }
    }
}
