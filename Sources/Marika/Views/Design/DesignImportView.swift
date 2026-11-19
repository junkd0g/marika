import AppKit
import MarikaCore
import SwiftUI

struct DesignImportView: View {
    @State private var model: DesignImportModel
    @Environment(\.dismiss) private var dismiss

    init(projectID: UUID, app: AppModel, selection: Set<UUID> = []) { _model = State(initialValue: DesignImportModel(projectID: projectID, app: app, selection: selection)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import design from project").font(.title2.weight(.semibold))
                    Text("Reconstruct editable screens, components and a design system from saved UI code.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if let run = model.run, run.isActive { progress(run) }
            else if let proposal = model.run?.proposal, model.run?.status == .ready { review(proposal) }
            else { sourcePicker }
            if let error = model.error ?? model.run?.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    #if DEBUG
                    .background(DebugViewMarker(name: "design-import-error"))
                    #endif
            }
        }
        .padding(22).frame(width: 760, height: 710).background(Theme.panel)
        .task { await model.load() }
        #if DEBUG
        .background(DebugViewMarker(name: "design-import-sheet"))
        #endif
    }

    private var sourcePicker: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Agent", selection: $model.agent) {
                    ForEach(AgentKind.allCases) { Text($0.shortName).tag($0) }
                }.frame(width: 220).onChange(of: model.agent) { _, _ in model.modelID = "" }
                Picker("Model", selection: $model.modelID) {
                    Text("Provider default").tag("")
                    ForEach(model.models) { Text($0.name).tag($0.id) }
                    if !model.modelID.isEmpty && !model.models.contains(where: { $0.id == model.modelID }) { Text(model.modelID).tag(model.modelID) }
                }
            }
            if model.updateBatchID != nil {
                Toggle("Update selected imported layers; preserve manual edits", isOn: $model.updatesSelection).font(.callout)
            }
            HStack {
                Button("Capture local preview") { Task { await model.capturePreview() } }.disabled(model.working)
                Button("Attach screenshot…") { model.chooseReference() }
                if let reference = model.reference {
                    Text(reference.source).font(.caption).lineLimit(1)
                    Button { model.reference = nil; model.referenceImage = nil } label: { Image(systemName: "xmark.circle.fill") }
                }
            }
            TextField("Focus (optional), e.g. checkout screens and shared controls", text: $model.focus, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...3)
            HStack {
                TextField("Filter source files", text: $model.filter).textFieldStyle(.roundedBorder)
                Button("Refresh") { Task { await model.load() } }.disabled(model.loading)
            }
            if model.loading { ProgressView("Finding UI source files…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.files.isEmpty {
                ContentUnavailableView("No UI source files found", systemImage: "doc.text.magnifyingglass",
                    description: Text("Open a Swift, Kotlin, HTML, React or Vue project. Build output and dependencies are excluded."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.visibleFiles) { file in
                            Toggle(isOn: Binding(get: { model.selected.contains(file.path) }, set: { if $0 { model.selected.insert(file.path) } else { model.selected.remove(file.path) } })) {
                                HStack {
                                    Text(file.path).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(file.framework).foregroundStyle(.secondary)
                                }.font(.system(size: 12))
                            }.toggleStyle(.checkbox).disabled(model.selected.count >= DesignImportSources.maximumFiles && !model.selected.contains(file.path))
                        }
                    }.padding(10)
                }.background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("\(model.selected.count) of \(DesignImportSources.maximumFiles) files selected · \(model.frameworks)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("Selected source snippets are sent to your configured \(model.agent.shortName) agent. Analysis runs in read-only mode; you review the result before adding it to Design.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.run?.status == .applied { Label("Previous import added", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.caption) }
                Spacer()
                Button("Generate design draft") { Task { await model.generate() } }
                    .buttonStyle(WorkspaceButtonStyle(kind: .primary)).disabled(model.loading || model.working || model.selected.isEmpty)
                    #if DEBUG
                    .background(DebugViewMarker(name: "design-import-generate"))
                    #endif
            }
        }
    }

    private func progress(_ run: DesignImportRun) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            ProgressView(run.status == .preparing ? "Reading selected source…" : "Reconstructing the UI with \(run.agent.shortName)…")
            Text(model.controller?.pendingApproval == nil ? model.controller?.activity ?? "Extracting screens, component structure, colours and typography." : "The agent needs your attention. Open its conversation to continue.")
                .font(.callout).foregroundStyle(.secondary)
            Text("You can close this window while the analysis continues. Open Import again to review the draft.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Stop analysis") { model.stop() }
                    #if DEBUG
                    .background(DebugViewMarker(name: "design-import-stop"))
                    #endif
                Spacer()
                Button("Open conversation") { model.openConversation(); dismiss() }.disabled(model.controller == nil)
            }
        }
    }

    private func review(_ proposal: DesignImportProposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DesignImportPreview(document: proposal.document)
            if let reference = model.run?.reference {
                let comparison = DesignReferenceComparison(reference: reference, document: proposal.document)
                HStack(alignment: .top) {
                    if let path = reference.imagePath, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 160, height: 95)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reference: " + reference.source).font(.caption.weight(.medium))
                        if comparison.measured > 0 {
                            Text("Matched text: \(comparison.matched)/\(comparison.measured) measured elements").font(.caption)
                            if let error = comparison.meanSizeError { Text("Mean size difference: " + error.formatted(.percent.precision(.fractionLength(0))) + " · compare visually before applying").font(.caption) }
                        } else { Text("Screenshot supplied; geometry was not measured.").font(.caption) }
                    }
                }
            }
            Text(proposal.summary).font(.callout).textSelection(.enabled)
            Text("\(proposal.document.nodes.count) editable layers · \(model.run?.files.count ?? 0) source files").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(proposal.notes.enumerated()), id: \.offset) { _, note in Text("• " + note).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 95)
            if let plan = model.mergePlan {
                Text("\(plan.added) added · \(plan.changed) changed · \(plan.removed) removed · \(plan.conflicts.count) manual edits preserved").font(.caption)
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(plan.conflicts) { conflict in
                            Toggle("Use generated: " + conflict.name + " — " + conflict.reason, isOn: Binding(get: { model.useGenerated.contains(conflict.id) }, set: { if $0 { model.useGenerated.insert(conflict.id) } else { model.useGenerated.remove(conflict.id) } })).font(.caption)
                        }
                    }
                }.frame(maxHeight: 90)
                Button("Refresh comparison") { model.refreshReview() }.font(.caption)
            } else {
                Text("Adds a new section beside the current artwork, with source links and one-step undo.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Discard draft") { model.startOver() }.disabled(model.working)
                Button("Open conversation") { model.openConversation(); dismiss() }
                Spacer()
                Button(model.run?.updatingBatchID == nil ? "Add to canvas" : "Apply reviewed update") { Task { if await model.apply() { dismiss() } } }
                    .buttonStyle(WorkspaceButtonStyle(kind: .primary)).disabled(model.working)
                    #if DEBUG
                    .background(DebugViewMarker(name: "design-import-apply"))
                    #endif
            }
        }
        #if DEBUG
        .background(DebugViewMarker(name: "design-import-review"))
        #endif
    }
}

private struct DesignImportPreview: View {
    let document: DesignDocument
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit().padding(8) }
            else { ContentUnavailableView("Preview unavailable", systemImage: "square.stack.3d.up", description: Text("The editable layers can still be added to the canvas.")) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 220)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .task { image = (try? DesignRenderer.png(document: document)).flatMap(NSImage.init(data:)) }
    }
}
