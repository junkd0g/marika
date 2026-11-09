import Foundation
import MarikaCore

extension AppModel {
    func openSpaceSection(_ section: SpaceSection) {
        guard isReady else { return }
        let id = selectedSpace.id
        editSpaceContent { workspace in
            if let index = workspace.spaces.firstIndex(where: { $0.id == id }) { workspace.spaces[index].section = section }
        }
        showsWelcome = false
    }
    func note(_ id: UUID, in spaceID: UUID) -> SpaceNote? { workspace.spaces.first { $0.id == spaceID }?.notes.first { $0.id == id } }
    func ticket(_ id: UUID, in spaceID: UUID) -> SpaceTicket? { workspace.spaces.first { $0.id == spaceID }?.tickets.first { $0.id == id } }
    @discardableResult func addSpaceNote(in spaceID: UUID) -> UUID? {
        guard let note = editSpaceContent({ $0.createNote(in: spaceID) }) else { return nil }
        spaceNoteSelections[spaceID] = note.id
        scheduleSave()
        return note.id
    }
    func updateSpaceNote(_ id: UUID, in spaceID: UUID, _ change: (inout SpaceNote) -> Void) {
        _ = editSpaceContent { $0.updateNote(id, in: spaceID, change: change) }
    }
    @discardableResult func addSpaceTicket(in spaceID: UUID, status: SpaceTicket.Status = .todo) -> UUID? {
        guard let ticket = editSpaceContent({ $0.createTicket(in: spaceID, status: status) }) else { return nil }
        scheduleSave()
        return ticket.id
    }
    func updateSpaceTicket(_ id: UUID, in spaceID: UUID, _ change: (inout SpaceTicket) -> Void) {
        _ = editSpaceContent { $0.updateTicket(id, in: spaceID, change: change) }
    }
}
