import AppKit
import MarikaCore
import SwiftUI

struct ContainerCreationSheet: View {
    let workspace: ContainerWorkspace
    let request: ContainerFormRequest
    @Environment(\.dismiss) private var dismiss
    @State private var image = "nginx:alpine"
    @State private var name = ""
    @State private var host = "8080"
    @State private var remote = "80"
    @State private var error: String?
    private var title: String { switch request.kind { case .run: "Run a container"; case .pull: "Pull an image"; case .cluster: "Create a local Kubernetes cluster"; case .forward: "Forward a port" } }
    private var action: String { switch request.kind { case .run: "Run container"; case .pull: "Pull image"; case .cluster: "Create cluster"; case .forward: "Start forwarding" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Label(request.target.name, systemImage: "scope").font(.callout.weight(.medium))
            if request.kind == .run || request.kind == .pull {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Image").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. nginx:alpine", text: $image).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Container image")
                }
            }
            if request.kind == .run || request.kind == .cluster {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.kind == .cluster ? "Cluster name" : "Container name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Resource name")
                }
            }
            if request.kind == .run || request.kind == .forward {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local port").font(.caption).foregroundStyle(.secondary)
                        TextField("Optional", text: $host).textFieldStyle(.roundedBorder).accessibilityLabel("Local port")
                    }
                    Image(systemName: "arrow.right").padding(.bottom, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Container / service port").font(.caption).foregroundStyle(.secondary)
                        TextField("Optional", text: $remote).textFieldStyle(.roundedBorder).accessibilityLabel("Container or service port")
                    }
                }
                Text(request.kind == .run ? "Ports are optional. Published ports bind to 127.0.0.1." : "The connection binds to 127.0.0.1 and stays open until stopped or Marika closes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if request.kind == .cluster {
                Text("Uses kind and the selected Docker context. The cluster has its own kubeconfig and does not change your default Kubernetes context. Creation can take a few minutes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action, action: submit).buttonStyle(WorkspaceButtonStyle(kind: .primary))
                    #if DEBUG
                    .background(DebugViewMarker(name: "container-create-submit"))
                    #endif
            }
        }.padding(24).frame(width: 520)
        .onAppear {
            let project = workspace.root.lastPathComponent.lowercased().replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            name = (request.kind == .cluster ? "marika-" : "") + String((project.isEmpty ? "project" : project).prefix(30)) + "-" + String(workspace.projectID.uuidString.prefix(6)).lowercased()
            if request.kind == .forward { remote = String(request.resource?.targetPort ?? 80) }
        }
        #if DEBUG
        .background(DebugViewMarker(name: "container-creation-sheet"))
        #endif
    }
    private func submit() {
        do {
            guard request.scope == workspace.scope else { throw ContainerHubError("The target changed. Reopen this form.") }
            let operation: ContainerOperation
            switch request.kind {
            case .run:
                let h = host.isEmpty ? nil : Int(host), r = remote.isEmpty ? nil : Int(remote)
                guard host.isEmpty || h != nil, remote.isEmpty || r != nil else { throw ContainerHubError("Ports must be numbers.") }
                operation = .command(try ContainerPlans.runImage(image, name: name, hostPort: h, containerPort: r, projectID: workspace.projectID, target: request.target), nil, nil)
            case .pull:
                guard ContainerPlans.image(image) else { throw ContainerHubError("Enter a valid image reference.") }
                operation = .command(try ContainerPlans.docker(request.target, ["pull", image], timeout: 180), nil, nil)
            case .cluster:
                guard request.target.isLocalDocker, ContainerPlans.name(name), name.count <= 50 else { throw ContainerHubError("Choose a local Docker context and a lowercase name of up to 50 characters.") }
                operation = .create(LocalCluster(name: name, dockerContext: request.target.name))
            case .forward:
                guard let resource = request.resource, let local = Int(host), let port = Int(remote) else { throw ContainerHubError("Enter both ports.") }
                try workspace.startForward(resource, localPort: local, remotePort: port); dismiss(); return
            }
            workspace.submit(ContainerOperationPrompt(title: title, detail: request.target.name, scope: request.scope, operation: operation))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ContainerOutputView: View {
    let title: String
    let output: String
    var busy = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.title3.weight(.semibold)); if busy { ProgressView().controlSize(.small) }; Spacer(); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) } }
            ScrollView { Text(output.isEmpty ? "Waiting for output…" : output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 740, height: 500)
        #if DEBUG
        .background(DebugViewMarker(name: "container-output"))
        #endif
    }
}

struct ContainerManifestSheet: View {
    let workspace: ContainerWorkspace
    let review: ContainerManifestReview
    @Environment(\.dismiss) private var dismiss
    private var current: Bool { workspace.target == review.target && workspace.settings.namespace == review.namespace }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Kubernetes changes").font(.title2.weight(.semibold))
            Text(review.target.name + " · namespace " + review.namespace).font(.headline)
            Text(review.source).font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(review.difference).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            Text("Applies the reviewed file contents. Cluster-scoped resources in this manifest apply to the selected cluster.").font(.caption).foregroundStyle(.secondary)
            if !current { Text("The target changed. Close this preview and generate a new diff.").foregroundStyle(.orange).font(.caption) }
            HStack {
                Button("Cancel") { workspace.review = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply reviewed manifest") {
                    guard current else { return }
                    workspace.submit(ContainerOperationPrompt(title: "Apply " + review.source, detail: review.target.name, scope: workspace.scope, operation: .apply(review)))
                    workspace.review = nil; dismiss()
                }.buttonStyle(WorkspaceButtonStyle(kind: .primary)).disabled(!current || workspace.isBusy)
                    #if DEBUG
                    .background(DebugViewMarker(name: "container-apply-submit"))
                    #endif
            }
        }.padding(24).frame(width: 740, height: 580)
        #if DEBUG
        .background(DebugViewMarker(name: "container-manifest-review"))
        #endif
    }
}
