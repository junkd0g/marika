import MarikaCore
import SwiftUI

struct DesignHealthView: View {
    let canvas: DesignCanvasModel
    @Environment(\.dismiss) private var dismiss
    private var health: DesignHealthModel { canvas.health }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Design health").font(.title2.weight(.semibold))
                Spacer()
                if health.isRunning { ProgressView().controlSize(.small); Button("Cancel") { health.cancel() } }
                else { Button("Check again") { health.refresh(canvas) }.buttonStyle(WorkspaceButtonStyle(compact: true)) }
            }
            Text("Check linked files, declarations, API endpoints, and disconnected components.").foregroundStyle(.secondary)
            if health.isStale(canvas) {
                Label("The design, open code, or API collection changed. Check again for current results.", systemImage: "arrow.clockwise")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let error = health.error { Text(error).foregroundStyle(.red) }
            if health.checkedAt != nil {
                HStack(spacing: 16) {
                    Text("\(health.issues.filter(\.needsRepair).count) need attention")
                    Text("\(health.issues.filter { $0.kind == .unverified }.count) unverified")
                    Text("\(health.issues.filter { $0.kind == .disconnected }.count) disconnected")
                }.font(.callout.weight(.medium))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if health.issues.isEmpty, health.checkedAt != nil, !health.isRunning {
                        Label("No issues found in the checks performed.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding(.vertical, 24)
                    }
                    ForEach(health.issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: issue.needsRepair ? "exclamationmark.triangle" : "info.circle")
                                .foregroundStyle(issue.needsRepair ? Color.orange : .secondary).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.title).font(.headline)
                                Text(canvas.doc.node(issue.nodeID)?.name ?? "Removed element").font(.callout.weight(.medium))
                                Text(issue.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            Button("Show element") {
                                canvas.selection = [issue.nodeID]; canvas.selectedConnection = nil; canvas.fitSelection(); dismiss()
                            }.disabled(canvas.doc.node(issue.nodeID) == nil).buttonStyle(WorkspaceButtonStyle(compact: true))
                            #if DEBUG
                            .background(DebugViewMarker(name: "design-health-show-" + issue.kind.rawValue))
                            #endif
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }.frame(height: 330)
            Text("Checks do not change your design. Documentation URLs are validated without visiting them. Changes on disk require another check.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let date = health.checkedAt { Text("Last checked \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 640)
            .onAppear { health.refresh(canvas) }.onDisappear { health.cancel() }
        #if DEBUG
            .background(DebugViewMarker(name: "design-health-panel"))
        #endif
    }
}
