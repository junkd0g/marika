import AppKit
import MarikaCore
import SwiftUI

/// Layers front to back. Drag to reorder, double-click to rename, hover for visibility and lock.
struct DesignLayersPanel: View {
    @Bindable var canvas: DesignCanvasModel
    let projectName: String

    private struct Row: Identifiable {
        let node: DesignNode
        let entry: DesignLayerEntry
        var id: UUID { node.id }
    }

    private var rows: [Row] {
        canvas.layerRows.compactMap { entry in
            canvas.doc.node(entry.id).map { Row(node: $0, entry: entry) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(canvas.doc.title ?? "Untitled design").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(projectName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider()
            HStack {
                Text("Layers").font(.system(size: 11, weight: .semibold))
                Spacer()
                if !canvas.doc.nodes.isEmpty {
                    Text("\(canvas.doc.nodes.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            if canvas.doc.nodes.isEmpty {
                Text("Layers appear here as you draw, or when your project chat designs on this canvas.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 4)
                Spacer()
            } else {
                List(selection: $canvas.selection) {
                    ForEach(rows) { row in
                        DesignLayerRow(canvas: canvas, node: row.node, entry: row.entry).tag(row.id)
                    }
                    .onMove { source, destination in
                        canvas.moveLayerRows(from: source, to: destination)
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
            }
        }
        .background(Theme.panel)
        .onAppear { canvas.revealSelectedLayers() }
        #if DEBUG
        .background(DebugViewMarker(name: "design-layers"))
        #endif
    }
}

private struct DesignLayerRow: View {
    let canvas: DesignCanvasModel
    let node: DesignNode
    let entry: DesignLayerEntry
    @State private var hovered = false
    @FocusState private var renaming: Bool

    var body: some View {
        HStack(spacing: 6) {
            if entry.hasChildren {
                Button {
                    if !canvas.collapsedFrames.insert(node.id).inserted { canvas.collapsedFrames.remove(node.id) }
                } label: {
                    Image(systemName: canvas.collapsedFrames.contains(node.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 12, height: 22)
                }
                .buttonStyle(.borderless)
                .help(canvas.collapsedFrames.contains(node.id) ? "Expand frame" : "Collapse frame")
                .accessibilityLabel("\(canvas.collapsedFrames.contains(node.id) ? "Expand" : "Collapse") \(node.name)")
                #if DEBUG
                .background(DebugViewMarker(name: "design-disclosure-" + node.id.uuidString))
                #endif
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: node.component?.symbol ?? node.kind.symbol).font(.system(size: 11)).frame(width: 16).foregroundStyle(.secondary)
            if canvas.renaming == node.id {
                TextField("Name", text: Binding(
                    get: { canvas.doc.node(node.id)?.name ?? "" },
                    set: { value in canvas.edit(coalescing: "name:\(node.id)") { $0.update([node.id]) { $0.name = String(value.prefix(500)) } } }))
                    .textFieldStyle(.plain).focused($renaming)
                    .onAppear { DispatchQueue.main.async { renaming = true } }
                    .onSubmit { canvas.renaming = nil }
                    .onExitCommand { canvas.renaming = nil }
                    .onChange(of: renaming) { was, now in if was, !now, canvas.renaming == node.id { canvas.renaming = nil } }
            } else {
                Button { canvas.selectLayer(node.id, modifiers: NSEvent.modifierFlags) } label: {
                    HStack {
                        Text(node.name).lineLimit(1).opacity(node.isHidden ? 0.4 : 1)
                        Spacer(minLength: 0)
                    }.foregroundStyle(Theme.ink).contentShape(Rectangle())
                }.buttonStyle(.borderless)
            }
            if hovered || node.isHidden {
                Button { canvas.edit { $0.setHidden(node.id, !node.isHidden) } } label: {
                    Image(systemName: node.isHidden ? "eye.slash" : "eye")
                }.buttonStyle(.borderless).help(node.isHidden ? "Show" : "Hide")
            }
            if hovered || node.isLocked {
                Button { canvas.edit { $0.setLocked(node.id, !node.isLocked) } } label: {
                    Image(systemName: node.isLocked ? "lock.fill" : "lock.open")
                }.buttonStyle(.borderless).help(node.isLocked ? "Unlock" : "Lock")
            }
        }
        .padding(.leading, CGFloat(entry.depth) * 14)
        .font(.system(size: 12))
        .contentShape(Rectangle())
        #if DEBUG
        .background(DebugViewMarker(name: "design-layer-" + node.id.uuidString))
        #endif
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !node.isLocked { canvas.renaming = node.id } })
        .onHover { inside in
            hovered = inside
            if inside { canvas.hovered = node.isHidden ? nil : node.id } else if canvas.hovered == node.id { canvas.hovered = nil }
        }
        .contextMenu {
            Button("Rename") { canvas.renaming = node.id }.disabled(node.isLocked)
            Button("Zoom to Layer") { canvas.selection = [node.id]; canvas.fitSelection() }.disabled(node.isHidden)
            Divider()
            Button(node.isHidden ? "Show" : "Hide") { canvas.edit { $0.setHidden(node.id, !node.isHidden) } }
            Button(node.isLocked ? "Unlock" : "Lock") { canvas.edit { $0.setLocked(node.id, !node.isLocked) } }
            Divider()
            Button("Bring to Front") { canvas.edit { $0.reorder([node.id], toFront: true) } }.disabled(node.isLocked)
            Button("Send to Back") { canvas.edit { $0.reorder([node.id], toFront: false) } }.disabled(node.isLocked)
            Divider()
            Button("Delete", role: .destructive) { canvas.selection = [node.id]; canvas.deleteSelection() }.disabled(node.isLocked)
        }
    }
}
