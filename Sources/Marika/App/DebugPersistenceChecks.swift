#if DEBUG
import Foundation
import MarikaCore

@MainActor enum DebugPersistenceChecks {
    /// Drive the app's real autosave path while both output and a draft keep changing.
    /// The caller exits without shutdown afterwards to check crash recovery on restart.
    static func streamingRecovery(_ model: AppModel) async throws {
        guard let id = model.selectedSessionID else { throw AgentError.launchFailed("No session selected") }
        await model.open(id)
        guard let session = model.controllers[id] else { throw AgentError.launchFailed("Session did not open") }
        guard await model.save() else { throw AgentError.launchFailed("Initial save failed") }
        session.apply(.phaseChanged(.running))
        var savedLengths = Set<Int>()
        for index in 0..<65 {
            session.apply(.textDelta(id: "stream-answer", delta: "stream checkpoint \(index)\n", parentToolID: nil))
            session.draft = "Draft changed while streaming \(index)"
            try await Task.sleep(for: .milliseconds(50))
            let items = try await model.store.loadTranscript(id)
            if let item = items.first(where: { $0.id == "stream-answer" }), case .assistant(let text) = item.content {
                savedLengths.insert(text.count)
            }
        }
        guard session.isBusy, savedLengths.count >= 2 else {
            throw AgentError.launchFailed("Autosave did not checkpoint continuous output while the draft changed")
        }
    }
}
#endif
