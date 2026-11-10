import MarikaCore
import SwiftUI

struct NoteTicketCreateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: NoteTicketDraft
    var onCreated: (UUID) -> Void
    @State private var creating = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    private var projects: [Project] { model.workspace.projects(in: draft.spaceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.3.group").font(.system(size: 19)).foregroundStyle(Theme.action)
                    .frame(width: 42, height: 42).background(Theme.action.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create ticket from note").font(.system(size: 20, weight: .semibold))
                    Text("Keep the idea connected to its source.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            WorkspaceFormField(title: "Title") {
                TextField("What needs to be done?", text: $draft.title).textFieldStyle(.plain)
                    .padding(10).workspaceControl(height: 38).focused($titleFocused).accessibilityLabel("New ticket title")
                    .background(SpaceContentMarker(name: "note-ticket-title"))
            }
            WorkspaceFormField(title: "Description") {
                TextEditor(text: $draft.body).font(.system(size: 13)).scrollContentBackground(.hidden).padding(10)
                    .frame(height: 145).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline) }
                    .accessibilityLabel("New ticket description")
                    .background(SpaceContentMarker(name: "note-ticket-description"))
            }
            WorkspaceFormField(title: "Project") {
                WorkspaceSelect(title: "Ticket project", selection: $draft.projectID,
                    options: [Optional<UUID>.none] + projects.map { Optional($0.id) },
                    label: { $0.flatMap(model.project(id:))?.name ?? "No project" }, symbol: "folder")
                if draft.projectID == nil { Text("You can choose a project later to start an agent.").font(.caption).foregroundStyle(.secondary) }
            }
            Label("Linked note: " + draft.noteTitle, systemImage: "doc.text").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            if let error { Text(error).font(.caption).foregroundStyle(Theme.attention).textSelection(.enabled) }
            HStack {
                Text("The note stays unchanged.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(WorkspaceButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction).disabled(creating)
                    .background(SpaceContentMarker(name: "note-ticket-cancel"))
                Button(creating ? "Creating…" : "Create ticket", systemImage: "plus") { create() }
                    .buttonStyle(WorkspaceButtonStyle(kind: .primary)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(creating || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .background(SpaceContentMarker(name: "note-ticket-submit"))
            }
        }.disabled(creating).padding(24).frame(width: 570).background(Theme.canvas)
            .interactiveDismissDisabled(creating)
            .onAppear { titleFocused = true }
            .onChange(of: projects.map(\.id)) { if let id = draft.projectID, !projects.contains(where: { $0.id == id }) { draft.projectID = nil } }
            .background(SpaceContentMarker(name: "note-ticket-create"))
    }
    private func create() {
        creating = true; error = nil
        let submitted = draft
        Task {
            do { let id = try await model.createNoteTicket(submitted); onCreated(id); dismiss() }
            catch { self.error = error.localizedDescription; creating = false }
        }
    }
}
