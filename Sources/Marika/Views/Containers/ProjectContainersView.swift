import AppKit
import MarikaCore
import SwiftUI

struct ContainerFormRequest: Identifiable {
    enum Kind { case run, pull, cluster, forward }
    let id = UUID()
    let kind: Kind
    let target: ContainerTarget
    let scope: String
    var resource: ContainerResource?
}

struct ProjectContainersView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Bindable var workspace: ContainerWorkspace
    let isVisible: Bool
    @State private var prompt: ContainerOperationPrompt?
    @State private var form: ContainerFormRequest?
    @State private var namespace = ""
    @State private var compactDetails = false
    @State private var width: CGFloat = 1000
    @State private var diagnostics: ContainerDiagnosticRequest?
    @State private var recovery: ContainerRecoveryRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            targets
            Divider()
            if let forward = workspace.forward, forward.running { forwardBar(forward) }
            if let warning = workspace.inventory.warning { message(warning, color: .orange) }
            if let error = workspace.error { message(error, color: .red) }
            if workspace.isBusy {
                HStack { ProgressView().controlSize(.small); Text(workspace.operationTitle); Spacer(); Button("Cancel") { workspace.cancelOperation() } }
                    .font(.callout).padding(12).background(Theme.surface)
            }
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if width >= 1000, workspace.selected != nil, ![ContainerViewMode.health, .logs].contains(workspace.display) { Divider(); details.frame(width: 310) }
            }
            if !workspace.output.isEmpty {
                HStack { Text(workspace.operationTitle).font(.caption); Spacer(); Button("Operation output") { workspace.showsOutput = true }.font(.caption) }.padding(10).background(Theme.panel)
            }
        }
        .background(Theme.canvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: isVisible) {
            guard isVisible else { return }
            while !Task.isCancelled {
                if workspace.display == .health { await workspace.refreshHealth() } else { await workspace.refresh() }
                do { try await Task.sleep(for: .seconds(workspace.display == .health ? 30 : 10)) } catch { break }
            }
        }
        .onChange(of: workspace.scope) { _, _ in Task { await workspace.refresh() } }
        .onChange(of: workspace.display) { _, value in
            if value != .logs { workspace.logs.stop() }
            if value == .health { workspace.selectedID = nil; Task { await workspace.refreshHealth() } }
        }
        .onChange(of: workspace.selectedID) { _, next in if next != nil, width < 1000, ![ContainerViewMode.logs, .health].contains(workspace.display) { compactDetails = true } }
        .sheet(item: $form) { ContainerCreationSheet(workspace: workspace, request: $0) }
        .sheet(item: $diagnostics) { ContainerDiagnosticsView(workspace: workspace, request: $0) }
        .sheet(item: $recovery) { ContainerRecoveryView(workspace: workspace, request: $0) }
        .sheet(isPresented: $compactDetails) { details.frame(width: 400, height: 580) }
        .sheet(isPresented: $workspace.showsOutput) { ContainerOutputView(title: workspace.operationTitle, output: workspace.output, busy: workspace.isBusy) }
        .sheet(isPresented: Binding(get: { workspace.review != nil }, set: { if !$0 { workspace.review = nil } })) {
            if let review = workspace.review { ContainerManifestSheet(workspace: workspace, review: review) }
        }
        .confirmationDialog(prompt?.title ?? "Confirm operation", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), titleVisibility: .visible) {
            if let prompt { Button(prompt.title) { workspace.submit(prompt); self.prompt = nil } }
            Button("Cancel", role: .cancel) { prompt = nil }
        } message: { Text(prompt?.detail ?? "") }
        #if DEBUG
        .background(DebugViewMarker(name: "project-containers"))
        #endif
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Containers").font(.system(size: 22, weight: .semibold))
                    Text("Docker and Kubernetes · " + project.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if width >= 850 { headerActions }
            }
            if width < 850 { headerActions }
        }.padding(18)
    }
    private var headerActions: some View {
        HStack(spacing: 12) {
            Picker("Engine", selection: Binding(get: { workspace.settings.provider }, set: { workspace.changeProvider($0) })) {
                ForEach(ContainerProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 205).disabled(workspace.isBusy)
            #if DEBUG
            .background(DebugViewMarker(name: "containers-engine"))
            #endif
            if workspace.settings.provider == .docker, let target = workspace.target {
                Button("Run image…") { form = ContainerFormRequest(kind: .run, target: target, scope: workspace.scope) }
                    .buttonStyle(WorkspaceButtonStyle(kind: .primary, compact: true)).disabled(workspace.isBusy)
                    #if DEBUG
                    .background(DebugViewMarker(name: "containers-run"))
                    #endif
            }
            Menu {
                if workspace.settings.provider == .docker, let target = workspace.target {
                    Button("Pull image…") { form = ContainerFormRequest(kind: .pull, target: target, scope: workspace.scope) }
                }
                if let docker = workspace.dockerTargets.first(where: { $0.id == workspace.settings.dockerContext }), docker.isLocalDocker {
                    Button("Create local Kubernetes cluster…") { form = ContainerFormRequest(kind: .cluster, target: docker, scope: workspace.scope) }
                }
                if workspace.settings.provider == .kubernetes, workspace.target != nil { Button("Apply manifest…", action: chooseManifest).disabled(workspace.settings.namespace == "*") }
            } label: { Label("New", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize().disabled(workspace.isBusy)
            Button { Task { await workspace.discover(); await workspace.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(WorkspaceButtonStyle(compact: true)).disabled(workspace.isBusy || workspace.isLoading).help("Refresh connections and resources")
        }
    }
    private var targets: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Context", selection: Binding(get: { workspace.target?.id ?? "" }, set: { workspace.changeTarget($0) })) {
                    if workspace.targets.isEmpty { Text("No contexts available").tag("") }
                    ForEach(workspace.targets) { Text($0.name + ($0.kubeconfig == nil ? "" : " · local")).tag($0.id) }
                }.frame(maxWidth: 380).disabled(workspace.isBusy)
                if workspace.settings.provider == .kubernetes {
                    HStack(spacing: 4) {
                        TextField("Namespace or *", text: $namespace).textFieldStyle(.roundedBorder).frame(width: 130)
                            .onSubmit { workspace.changeNamespace(namespace) }.onAppear { namespace = workspace.settings.namespace }
                            .onChange(of: workspace.settings.namespace) { _, value in namespace = value }
                        Menu { Button("All namespaces") { workspace.changeNamespace("*") }; ForEach(workspace.namespaces, id: \.self) { value in Button(value) { workspace.changeNamespace(value) } } }
                            label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Choose a namespace")
                    }.disabled(workspace.isBusy)
                }
                Spacer(minLength: 0)
                if workspace.isLoading { ProgressView().controlSize(.small) }
                if !workspace.inventory.resources.isEmpty {
                    Text(workspace.inventory.date, style: .time).font(.caption).foregroundStyle(.secondary).help("Last resource refresh")
                }
            }
            if workspace.settings.provider == .docker, !workspace.composeFiles.isEmpty {
                HStack {
                    Picker("Project stack", selection: Binding(get: { workspace.settings.composeFile }, set: { workspace.settings.composeFile = $0 })) {
                        ForEach(workspace.composeFiles, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 340)
                    Button("Start stack") { compose("up") }.buttonStyle(WorkspaceButtonStyle(compact: true))
                    Button("Stop stack…") { compose("down") }.buttonStyle(WorkspaceButtonStyle(compact: true))
                }.disabled(workspace.isBusy || workspace.target == nil)
            }
            if let cluster = workspace.selectedCluster, workspace.settings.provider == .kubernetes {
                HStack {
                    Label("Local kind cluster · managed by Marika", systemImage: "desktopcomputer").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete cluster…") { prompt = ContainerOperationPrompt(title: "Delete " + cluster.name,
                        detail: "Removes this local cluster and every workload inside it. Docker context: " + cluster.dockerContext,
                        scope: workspace.scope, operation: .delete(cluster)) }.buttonStyle(WorkspaceButtonStyle(kind: .destructive, compact: true)).disabled(workspace.isBusy)
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 12).background(Theme.panel)
    }
    @ViewBuilder private var content: some View {
        if workspace.display == .logs {
            VStack(spacing: 0) { viewPicker.padding(12).frame(maxWidth: .infinity, alignment: .trailing); ContainerLogsView(project: project, workspace: workspace, logs: workspace.logs) }
        } else if workspace.display == .health, workspace.settings.provider == .kubernetes {
            VStack(spacing: 0) { viewPicker.padding(12).frame(maxWidth: .infinity, alignment: .trailing); ContainerHealthView(workspace: workspace) }
        } else if workspace.target == nil {
            VStack { viewPicker.padding(12).frame(maxWidth: .infinity, alignment: .trailing); ContentUnavailableView("Connect an engine", systemImage: "shippingbox", description: Text(workspace.settings.provider == .docker
                ? workspace.dockerError ?? "Create a Docker context or start Docker Desktop, then refresh."
                : workspace.kubeError ?? "Add a kubeconfig context or create a local kind cluster from New.")) }
        } else {
            VStack(spacing: 0) {
                HStack {
                    TextField("Filter resources", text: $workspace.filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Spacer()
                    Text("\(workspace.resources.count) resources").font(.caption).foregroundStyle(.secondary)
                    viewPicker
                }.padding(12)
                if workspace.resources.isEmpty {
                    ContentUnavailableView(workspace.isLoading ? "Loading resources…" : workspace.filter.isEmpty ? "No resources here yet" : "No matching resources", systemImage: "shippingbox",
                        description: Text(workspace.settings.provider == .docker ? "Run an image or start this project's Compose stack." : "Choose a namespace or apply a manifest to this context."))
                } else if workspace.display == .map { ContainerTopologyView(workspace: workspace) }
                else {
                    List(selection: $workspace.selectedID) {
                        ForEach(workspace.resources) { resource in
                            HStack(spacing: 10) {
                                Image(systemName: resource.kind.symbol).foregroundStyle(resource.condition.color).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(resource.name).font(.system(size: 12, weight: .medium))
                                    Text(resource.namespace.isEmpty ? resource.image : resource.namespace + " · " + resource.kind.rawValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(); Text(resource.status).font(.caption).foregroundStyle(resource.condition.color)
                            }.padding(.vertical, 4).tag(resource.id)
                        }
                    }.listStyle(.plain)
                }
            }
        }
    }
    @ViewBuilder private var details: some View {
        if let resource = workspace.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Image(systemName: resource.kind.symbol).foregroundStyle(resource.condition.color); Text(resource.kind.rawValue).foregroundStyle(.secondary); Spacer(); Button { workspace.selectedID = nil; compactDetails = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    Text(resource.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Label(resource.status, systemImage: "circle.fill").font(.caption).foregroundStyle(resource.condition.color)
                    if !resource.namespace.isEmpty { detail("Namespace", resource.namespace) }
                    if !resource.image.isEmpty { detail("Image", resource.image) }
                    if !resource.ports.isEmpty { detail("Ports", resource.ports) }
                    if !resource.detail.isEmpty { detail("Status", resource.detail) }
                    if !resource.node.isEmpty { detail("Node", resource.node) }
                    if !resource.failureReason.isEmpty, resource.condition == .failed { detail("Failure reason", resource.failureReason) }
                    if !resource.failureMessage.isEmpty { detail("Details", resource.failureMessage) }
                    if !resource.schedule.isEmpty { detail("Schedule", resource.schedule + " · " + resource.timeZone) }
                    if let date = resource.lastScheduledAt { detail("Last scheduled", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let date = resource.lastSuccessfulAt { detail("Last successful", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let date = resource.startedAt { detail("Started", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let date = resource.finishedAt { detail("Finished", date.formatted(date: .abbreviated, time: .shortened)) }
                    if let owner = resource.ownerName { detail("Owner", (resource.ownerKind ?? "") + "/" + owner) }
                    if !resource.networks.isEmpty { detail("Networks", resource.networks.joined(separator: ", ")) }
                    Divider()
                    actions(resource)
                    if resource.kind == .cronJob {
                        let jobs = workspace.inventory.resources.filter { $0.kind == .job && $0.ownerUID == resource.uid }.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                        if !jobs.isEmpty {
                            Text("Recent jobs").font(.headline)
                            ForEach(jobs.prefix(12)) { job in
                                Button { workspace.selectedID = job.id } label: {
                                    VStack(alignment: .leading, spacing: 3) { Text(job.name).lineLimit(1); Text(job.status).foregroundStyle(job.condition.color) }.font(.caption)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    let events = workspace.inventory.events.filter { $0.resourceUID == resource.uid }
                    if !events.isEmpty {
                        Text("Events").font(.headline)
                        ForEach(events) { event in VStack(alignment: .leading, spacing: 3) { Text(event.reason).font(.caption.weight(.semibold)).foregroundStyle(event.warning ? .orange : .secondary); Text(event.message).font(.caption).foregroundStyle(.secondary) } }
                    }
                    if !resource.labels.isEmpty {
                        Text("Labels").font(.headline)
                        ForEach(resource.labels.keys.sorted().prefix(15), id: \.self) { key in detail(key, resource.labels[key] ?? "") }
                    }
                }.padding(18)
            }.background(Theme.panel)
        }
    }
    @ViewBuilder private func actions(_ resource: ContainerResource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if resource.kind.hasLogs || resource.kind.restartable || [.job, .cronJob].contains(resource.kind) {
                Button("Explore logs") { compactDetails = false; workspace.logs.sourceID = resource.id; workspace.logs.container = ""; workspace.display = .logs }
                    .buttonStyle(WorkspaceButtonStyle(kind: .primary, compact: true))
            }
            if resource.kind == .container {
                HStack {
                    Button("Start") { action("start", resource) }.disabled(resource.condition == .ready)
                    Button("Stop…") { action("stop", resource) }.disabled(resource.condition == .stopped)
                    Button("Restart…") { action("restart", resource) }
                }.buttonStyle(WorkspaceButtonStyle(compact: true))
            } else if resource.kind.restartable {
                Button("Restart workload…") { action("restart", resource) }.buttonStyle(WorkspaceButtonStyle(compact: true))
                if resource.kind.scalable { ContainerScaleControl(replicas: resource.replicas ?? 1) { action("scale", resource, replicas: $0) }.id(resource.id + ":" + String(resource.replicas ?? 1)) }
                Button("Rollout status") { workspace.loadStatus(resource) }.buttonStyle(WorkspaceButtonStyle(compact: true))
            }
            if resource.kind == .deployment {
                Button("History / rollback…") { recover(resource, rollback: true) }.buttonStyle(WorkspaceButtonStyle(compact: true))
                    #if DEBUG
                    .background(DebugViewMarker(name: "container-rollback"))
                    #endif
            }
            if resource.kind == .job || resource.kind == .cronJob {
                Button(resource.kind == .cronJob ? "Run now…" : "Retry as new job…") { recover(resource, rollback: false) }.buttonStyle(WorkspaceButtonStyle(compact: true))
                    #if DEBUG
                    .background(DebugViewMarker(name: "container-retry"))
                    #endif
            }
            if resource.kind == .container {
                Button("View logs") { workspace.loadLogs(resource) }.buttonStyle(WorkspaceButtonStyle(compact: true))
                    #if DEBUG
                    .background(DebugViewMarker(name: "containers-logs"))
                    #endif
            }
            if [.pod, .job, .cronJob].contains(resource.kind), let target = workspace.target {
                Button("Logs and diagnostics…") {
                    let request = ContainerDiagnosticRequest(resource: resource, pods: workspace.relatedPods(resource), target: target, scope: workspace.scope)
                    if compactDetails { compactDetails = false; Task { try? await Task.sleep(for: .milliseconds(300)); diagnostics = request } }
                    else { diagnostics = request }
                }.buttonStyle(WorkspaceButtonStyle(compact: true))
                    #if DEBUG
                    .background(DebugViewMarker(name: "container-diagnostics-open"))
                    #endif
            }
            if [.pod, .service].contains(resource.kind), let target = workspace.target {
                Button("Forward a port…") { form = ContainerFormRequest(kind: .forward, target: target, scope: workspace.scope, resource: resource) }.buttonStyle(WorkspaceButtonStyle(compact: true))
            }
            if resource.kind == .container, let port = resource.localPort, workspace.target?.isLocalDocker == true {
                Button("Open port " + String(port)) { open(port) }.buttonStyle(WorkspaceButtonStyle(compact: true))
            }
        }.disabled(workspace.isBusy)
    }
    private var viewPicker: some View {
        Picker("View", selection: $workspace.display) {
            Text("Map").tag(ContainerViewMode.map); Text("List").tag(ContainerViewMode.list); Text("Logs").tag(ContainerViewMode.logs)
            if workspace.settings.provider == .kubernetes { Text("Health").tag(ContainerViewMode.health) }
        }.pickerStyle(.segmented).labelsHidden().frame(width: workspace.settings.provider == .kubernetes ? 280 : 210)
            #if DEBUG
            .background(DebugViewMarker(name: "containers-view"))
            #endif
    }
    private func recover(_ resource: ContainerResource, rollback: Bool) {
        guard let target = workspace.target else { return }
        let request = ContainerRecoveryRequest(resource: resource, target: target, scope: workspace.scope, rollback: rollback)
        if compactDetails { compactDetails = false; Task { try? await Task.sleep(for: .milliseconds(300)); recovery = request } }
        else { recovery = request }
    }
    private func action(_ value: String, _ resource: ContainerResource, replicas: Int? = nil) {
        do { prompt = try workspace.resourcePrompt(value, resource: resource, replicas: replicas) }
        catch { workspace.error = error.localizedDescription }
    }
    private func compose(_ operation: String) {
        guard let target = workspace.target else { return }
        do {
            let command = try ContainerPlans.compose(operation, file: workspace.settings.composeFile, root: project.url, target: target)
            prompt = ContainerOperationPrompt(title: operation == "up" ? "Start project stack" : "Stop project stack", detail: "Docker context: " + target.name + "\n" + command.display,
                                              scope: workspace.scope, operation: .command(command, nil, nil))
        } catch { workspace.error = error.localizedDescription }
    }
    private func chooseManifest() {
        let picker = NSOpenPanel(); picker.directoryURL = project.url; picker.canChooseDirectories = false; picker.message = "Choose a YAML or JSON manifest inside this project. You will review the diff before applying it."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let root = project.url.standardizedFileURL.resolvingSymlinksInPath().path, file = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard file.hasPrefix(root + "/") else { workspace.error = "Choose a manifest inside this project."; return }
        workspace.previewManifest(String(file.dropFirst(root.count + 1)))
    }
    private func open(_ port: Int) { model.browser(for: project).navigate("http://127.0.0.1:\(port)"); model.switchPanel(.browser) }
    private func forwardBar(_ forward: ContainerForward) -> some View {
        HStack { Label("\(forward.name) → localhost:\(forward.port)", systemImage: "arrow.left.arrow.right"); Spacer(); if forward.ready { Button("Open") { open(forward.port) } }; Button("Stop forwarding") { forward.stop() } }.font(.caption).padding(10).background(Theme.surface)
    }
    private func detail(_ name: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(name).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) } }
    private func message(_ value: String, color: Color) -> some View {
        HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle").foregroundStyle(color); Text(value).font(.caption).textSelection(.enabled); Spacer() }.padding(12).background(color.opacity(0.07))
    }
}

private struct ContainerScaleControl: View {
    @State var replicas: Int
    let apply: (Int) -> Void
    var body: some View {
        HStack { Stepper("\(replicas) replicas", value: $replicas, in: 0...1000); Button("Scale…") { apply(replicas) }.buttonStyle(WorkspaceButtonStyle(compact: true)) }.font(.caption)
    }
}
