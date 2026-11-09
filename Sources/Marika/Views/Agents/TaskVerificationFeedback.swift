import MarikaCore
import SwiftUI

struct TaskVerificationFeedback: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID
    init(sessionID: UUID) { self.sessionID = sessionID }
    init(session: SessionController) { sessionID = session.id }
    private var checks: TaskVerificationWorkspace? { model.taskVerifications[sessionID] }
    private var record: TaskVerificationRecord? { model.controllers[sessionID]?.meta.taskVerification }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(checks?.label ?? "Checking freshness…", systemImage: checks?.passed == true ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(checks?.passed == true ? .green : Theme.attention)
            if checks?.status != .current, let record {
                Text("Last run: " + (record.succeeded == true ? "passed" : record.succeeded == false ? "failed" : "incomplete"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let detail = checks?.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: record) { if record != nil { await model.taskVerification(for: sessionID).monitor() } }
        #if DEBUG
            .background(DebugViewMarker(name: "verification-freshness"))
        #endif
    }
}
