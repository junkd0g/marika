#if DEBUG
import Foundation
import MarikaCore

@MainActor enum DebugNoteTicketChecks {
    static func saveFailure(model: AppModel) async throws {
        let space = model.selectedSpace
        guard let note = space.notes.first, let block = note.blocks.first else { throw TicketWorkError("Missing source note") }
        let draft = try NoteTicketDraft(note: note, spaceID: space.id, blockID: block.id)
        guard await model.save() else { throw TicketWorkError("Initial note save failed") }
        let file = model.store.root.appendingPathComponent("workspace.json"), backup = model.store.root.appendingPathComponent("qa-note-ticket.saved")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            var failed = false
            do { _ = try await model.createNoteTicket(draft) } catch { failed = true }
            guard failed, model.selectedSpace.tickets.count == space.tickets.count, model.note(note.id, in: space.id) == note else {
                throw TicketWorkError("A failed creation left a partial ticket or changed the note")
            }
            try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
        } catch {
            try? FileManager.default.removeItem(at: file); try? FileManager.default.moveItem(at: backup, to: file); throw error
        }
        guard await model.save() else { throw TicketWorkError("Couldn't recover note-ticket storage") }
    }
}
#endif
