import AppKit
import MarikaCore
import SwiftUI

struct DesignTicketEditor: View {
    let canvas: DesignCanvasModel
    @State var draft: DesignTicketDraft
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create implementation ticket").font(.title2.weight(.semibold))
            Text("Review the requirements and acceptance criteria before creating the ticket.").foregroundStyle(.secondary)
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            Text("Requirements").font(.headline)
            TextEditor(text: $draft.requirements).font(.system(size: 12)).frame(height: 160).border(Theme.hairline)
            Text("Acceptance criteria — one per line").font(.headline)
            TextEditor(text: $draft.acceptance).font(.system(size: 12)).frame(height: 110).border(Theme.hairline)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text("The ticket links to \(draft.source.elementIDs.count) design elements.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy)
                Button(busy ? "Creating…" : "Create ticket") {
                    guard let model = canvas.app else { return }; busy = true
                    Task {
                        do { let id = try await model.createDesignTicket(draft); dismiss(); model.openTicket(id) }
                        catch { self.error = error.localizedDescription; busy = false }
                    }
                }.buttonStyle(WorkspaceButtonStyle(kind: .primary)).disabled(busy || draft.title.isEmpty || draft.acceptance.isEmpty)
                #if DEBUG
                .background(DebugViewMarker(name: "design-create-ticket"))
                #endif
            }
        }.padding(24).frame(width: 620)
        #if DEBUG
        .background(DebugViewMarker(name: "design-ticket-editor"))
        #endif
    }
}

struct DesignTemplatePicker: View {
    let canvas: DesignCanvasModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Start from a template").font(.title2.weight(.semibold))
            Text("Templates are editable examples. Inserting one preserves your existing canvas.").foregroundStyle(.secondary)
            ForEach(DesignTemplate.allCases, id: \.self) { template in
                Button {
                    var ids: Set<UUID> = []
                    canvas.edit { ids = $0.insertTemplate(template) }
                    canvas.selection = ids; canvas.fitSelection(); dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.title).font(.headline).foregroundStyle(Theme.ink)
                        Text(template.summary).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
                #if DEBUG
                .background(DebugViewMarker(name: "design-template-" + template.rawValue))
                #endif
            }
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }.padding(24).frame(width: 480)
    }
}

struct DesignHistoryView: View {
    let canvas: DesignCanvasModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: UUID?
    @State private var error: String?
    private var versions: [DesignVersion] { canvas.app?.project(id: canvas.projectID)?.designVersions ?? [] }
    private var version: DesignVersion? { versions.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Design versions").font(.title2.weight(.semibold))
            HStack {
                TextField("Name this version", text: $name).textFieldStyle(.roundedBorder)
                Button("Save version") { do { try canvas.app?.saveDesignVersion(projectID: canvas.projectID, name: name); name = ""; error = nil } catch { self.error = error.localizedDescription } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("The latest 10 named versions are saved with the project.").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                List(selection: $selected) {
                    ForEach(versions.reversed()) { version in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(version.name)
                            Text(version.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }.tag(version.id)
                    }
                }.frame(width: 180, height: 340)
                if let version {
                    let difference = DesignDifference(before: version.document, after: canvas.doc)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved version → Current canvas").font(.headline)
                        Text("\(difference.added.count) added · \(difference.changed.count) changed · \(difference.removed.count) removed · \(difference.connectionsChanged) connections")
                            .font(.caption).foregroundStyle(.secondary)
                        if difference.titleChanged { Text("Title changed: \(version.document.title ?? "Untitled") → \(canvas.doc.title ?? "Untitled")").font(.caption).lineLimit(1) }
                        DesignDifferencePreview(before: version.document, after: canvas.doc).frame(width: 480, height: 260)
                        Text("Green: added   Orange: changed   Red: removed").font(.caption)
                        Button("Restore this version") {
                            do { try canvas.app?.restoreDesignVersion(projectID: canvas.projectID, versionID: version.id); error = nil }
                            catch { self.error = error.localizedDescription }
                        }.buttonStyle(WorkspaceButtonStyle()).disabled(difference.isEmpty)
                        #if DEBUG
                        .background(DebugViewMarker(name: "design-restore-version"))
                        #endif
                    }
                } else { ContentUnavailableView("Select a version", systemImage: "clock", description: Text("Save a named version before a major change.")) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Text("Restoring is undoable.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Done") { dismiss() } }
        }.padding(24).frame(width: 730)
        .onAppear { selected = versions.last?.id }
        #if DEBUG
        .background(DebugViewMarker(name: "design-history"))
        #endif
    }
}

private struct DesignDifferencePreview: View {
    let before: DesignDocument
    let after: DesignDocument
    var body: some View {
        GeometryReader { proxy in
            let diff = DesignDifference(before: before, after: after)
            let box = (before.visibleBounds ?? .zero).union(after.visibleBounds ?? .zero).insetBy(dx: -24, dy: -24)
            let zoom = min(proxy.size.width / max(1, box.width), proxy.size.height / max(1, box.height))
            let offset = CGSize(width: (proxy.size.width - box.width * zoom) / 2 - box.minX * zoom,
                                height: (proxy.size.height - box.height * zoom) / 2 - box.minY * zoom)
            ZStack {
                DesignScene(nodes: after.nodes + before.nodes.filter { diff.removed.contains($0.id) },
                            connections: after.connections ?? [], zoom: zoom, offset: offset)
                Canvas { context, _ in
                    let transform = CGAffineTransform(scaleX: zoom, y: zoom).concatenating(CGAffineTransform(translationX: offset.width, y: offset.height))
                    for edge in before.connections ?? [] where !(after.connections ?? []).contains(edge) {
                        if let route = edge.route(in: before.nodes) {
                            context.stroke(DesignConnectionPath.path(route).applying(transform), with: .color(.red.opacity(0.65)), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        }
                    }
                    for edge in after.connections ?? [] where !(before.connections ?? []).contains(edge) {
                        if let route = edge.route(in: after.nodes) {
                            let color: Color = (before.connections ?? []).contains { $0.id == edge.id } ? .orange : .green
                            context.stroke(DesignConnectionPath.path(route).applying(transform), with: .color(color), lineWidth: 2)
                        }
                    }
                    for node in after.nodes + before.nodes.filter({ diff.removed.contains($0.id) }) {
                        let color: Color? = diff.added.contains(node.id) ? .green : diff.removed.contains(node.id) ? .red : diff.changed.contains(node.id) ? .orange : nil
                        if let color {
                            let rect = node.bounds.applying(CGAffineTransform(scaleX: zoom, y: zoom)).offsetBy(dx: offset.width, dy: offset.height)
                            context.stroke(Path(rect.insetBy(dx: -3, dy: -3)), with: .color(color), lineWidth: 3)
                        }
                    }
                }
            }.clipped().background(Theme.designCanvas)
        }
    }
}
