import AppKit
import MarikaCore
import SwiftUI

struct SpaceNotesView: View {
    @Environment(AppModel.self) private var model
    let spaceID: UUID
    @State private var query = ""
    private var archived: Bool {
        get { model.spaceNoteArchives[spaceID] ?? false }
        nonmutating set { model.spaceNoteArchives[spaceID] = newValue }
    }
    private var space: ProjectSpace { model.workspace.spaces.first { $0.id == spaceID } ?? model.selectedSpace }
    private var notes: [SpaceNote] {
        space.notes.filter { $0.archived == archived && (query.isEmpty || $0.searchableText.localizedStandardContains(query)) }
            .sorted { $0.pinned == $1.pinned ? $0.updatedAt > $1.updatedAt : $0.pinned }
    }
    private var selection: UUID? {
        let id = model.spaceNoteSelections[spaceID]
        // Keep the editor open when an edit removes the selected note's search match.
        return space.notes.contains { $0.id == id && $0.archived == archived } ? id : notes.first?.id
    }
    var body: some View {
        VStack(spacing: 0) {
            SpaceContentHeader(title: "Notes", space: space) {
                Button { archived.toggle() } label: { Label("Archive", systemImage: archived ? "archivebox.fill" : "archivebox") }
                    .buttonStyle(WorkspaceButtonStyle(kind: .quiet))
                    .background(archived ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .background(SpaceContentMarker(name: "space-note-show-archive"))
                Button("New Note", systemImage: "plus", action: createNote)
                    .buttonStyle(WorkspaceButtonStyle(kind: .primary))
                    .background(SpaceContentMarker(name: "space-note-new"))
            }
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    WorkspaceSearchField(placeholder: "Search notes", text: $query).padding(12)
                        .accessibilityLabel("Search space notes")
                        .background(SpaceContentMarker(name: "space-note-search"))
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(notes) { note in
                                Button { model.spaceNoteSelections[spaceID] = note.id } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack(spacing: 5) {
                                            Image(systemName: note.pinned ? "pin.fill" : "doc.text").foregroundStyle(.secondary)
                                            Text(note.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        }
                                        Text(note.blocks.first { !$0.text.isEmpty }?.text ?? "Start writing…")
                                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                        Text(note.updatedAt, style: .date).font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                        .background(selection == note.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Note: " + note.displayTitle)
                                    .accessibilityAddTraits(selection == note.id ? [.isSelected] : [])
                                    .background(SpaceContentMarker(name: "space-note-" + note.id.uuidString))
                            }
                            if notes.isEmpty { Text(query.isEmpty ? (archived ? "No archived notes." : "Your space's notes live here.") : "No matching notes.").foregroundStyle(.secondary).padding(16) }
                        }.padding(.horizontal, 6)
                    }
                }.frame(width: 215).background(Theme.panel)
                Divider()
                if let id = selection {
                    SpaceNoteEditor(spaceID: spaceID, noteID: id).id(id)
                } else {
                    ContentUnavailableView {
                        Label(archived ? "No archived notes" : "A place for your ideas", systemImage: "doc.text")
                    } description: {
                        Text("Write plans, decisions and meeting notes for this space.")
                    } actions: {
                        if !archived {
                            Button("Create a Note", action: createNote).buttonStyle(WorkspaceButtonStyle(kind: .primary))
                                .background(SpaceContentMarker(name: "space-note-empty-create"))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.background(Theme.canvas)
            .background(SpaceContentMarker(name: "space-notes"))
            .onChange(of: selection, initial: true) { _, id in model.spaceNoteSelections[spaceID] = id }
            .onChange(of: query) {
                if !notes.contains(where: { $0.id == model.spaceNoteSelections[spaceID] }) {
                    model.spaceNoteSelections[spaceID] = notes.first?.id
                }
            }
    }

    private func createNote() {
        archived = false; query = ""
        model.addSpaceNote(in: spaceID)
    }
}

private struct SpaceNoteEditor: View {
    @Environment(AppModel.self) private var model
    let spaceID: UUID
    let noteID: UUID
    @FocusState private var focusedBlock: UUID?
    @FocusState private var titleFocused: Bool
    @State private var textSelection: NoteTextSelection?
    @State private var ticketDraft: NoteTicketDraft?
    @State private var createdTicketID: UUID?
    @State private var ticketError: String?
    private var note: SpaceNote? { model.note(noteID, in: spaceID) }
    private var relatedTickets: [SpaceTicket] {
        (model.workspace.spaces.first { $0.id == spaceID }?.tickets ?? []).filter { $0.linkedNoteIDs?.contains(noteID) == true }
            .sorted { $0.archived == $1.archived ? $0.updatedAt > $1.updatedAt : !$0.archived }
    }
    var body: some View {
        if let note {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(SpaceNoteBlock.Kind.allCases, id: \.self) { kind in Button(kind.rawValue) { addBlock(kind) } }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus")
                            if textSelection == nil {
                                Text("Add Block").fontWeight(.medium)
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: textSelection == nil ? 102 : 32).accessibilityLabel("Add Block")
                        .workspaceControl(height: 30).disabled(note.archived)
                        .background(SpaceContentMarker(name: "space-note-add-block"))
                    if let textSelection, !note.archived {
                        Button("Create ticket", systemImage: "rectangle.3.group") { prepareTicket(textSelection.blockID, selection: textSelection) }
                            .buttonStyle(WorkspaceButtonStyle(kind: .secondary, compact: true)).help("Create a ticket from the selected text")
                            .background(SpaceContentMarker(name: "note-selection-create-ticket"))
                    }
                    Spacer()
                    Button { update { $0.pinned.toggle() } } label: { Image(systemName: note.pinned ? "pin.fill" : "pin") }
                        .buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
                        .help(note.pinned ? "Unpin note" : "Pin note").accessibilityLabel(note.pinned ? "Unpin note" : "Pin note")
                    Button("Copy Markdown", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.markdown, forType: .string)
                    }.buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
                        .labelStyle(.iconOnly).accessibilityLabel("Copy Markdown").help("Copy note as Markdown")
                    Button(note.archived ? "Restore" : "Archive") { update { $0.archived.toggle() } }.buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
                        .background(SpaceContentMarker(name: "space-note-archive"))
                }.padding(.horizontal, 20).frame(height: 52)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("Untitled note", text: Binding(get: { self.note?.title ?? "" }, set: { value in update { $0.title = value } }), axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 29, weight: .bold)).accessibilityLabel("Note title")
                            .disabled(note.archived).focused($titleFocused)
                            .background(SpaceContentMarker(name: "space-note-title"))
                        if note.archived { Label("Archived note · Restore to continue editing", systemImage: "archivebox").foregroundStyle(.secondary) }
                        ForEach(note.blocks) { block in
                            blockRow(block).disabled(note.archived)
                        }
                        if !note.archived {
                            Button { addBlock(.text) } label: { Label("Add a block", systemImage: "plus") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).padding(.top, 4)
                        }
                        if let ticketError { Text(ticketError).font(.caption).foregroundStyle(Theme.attention) }
                        linkedTickets
                        Text("Changes save automatically · Return adds a block · Shift-Return adds a new line")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 20)
                    }.padding(30).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { titleFocused = note.title.isEmpty }
                .onChange(of: titleFocused) { if titleFocused { textSelection = nil } }
                .onChange(of: note.archived) { textSelection = nil }
                .sheet(item: $ticketDraft, onDismiss: {
                    if let id = createdTicketID { createdTicketID = nil; model.openTicket(id) }
                }) { draft in
                    NoteTicketCreateView(draft: draft) { createdTicketID = $0 }.environment(model)
                }
                .background(NoteSelectionObserver(focusedBlock: focusedBlock, blocks: note.blocks) { selection in
                    if textSelection != selection { textSelection = selection }
                })
                .background(NoteLineBreakHandler(isEditingBlock: focusedBlock != nil))
        }
    }
    private func blockRow(_ block: SpaceNoteBlock) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if block.kind == .checklist {
                Toggle("Completed", isOn: Binding(get: { self.note?.blocks.first { $0.id == block.id }?.checked ?? false }, set: { checked in editBlock(block.id) { $0.checked = checked } }))
                    .labelsHidden().toggleStyle(.checkbox).padding(.top, 4).accessibilityLabel("Complete checklist item")
            } else if block.kind == .bullet { Text("•").font(.system(size: 18)).foregroundStyle(.secondary) }
            else if block.kind == .quote { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.3)).frame(width: 3, height: 25) }
            TextField(block.kind == .code ? "Write code…" : "Write something…", text: Binding(
                get: { self.note?.blocks.first { $0.id == block.id }?.text ?? "" },
                set: { value in editBlock(block.id) { $0.text = value } }
            ), axis: .vertical)
                .textFieldStyle(.plain).font(font(block.kind)).lineSpacing(5)
                .strikethrough(block.kind == .checklist && block.checked)
                .foregroundStyle(block.kind == .checklist && block.checked ? .secondary : .primary)
                .padding(block.kind == .code ? 12 : 0)
                .background(block.kind == .code ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                .focused($focusedBlock, equals: block.id)
                .onSubmit {
                    if (block.kind == .bullet || block.kind == .checklist) && block.text.isEmpty {
                        editBlock(block.id) { $0.kind = .text }
                    } else {
                        addBlock(block.kind == .bullet || block.kind == .checklist ? block.kind : .text, after: block.id)
                    }
                }
                .accessibilityLabel(block.kind.rawValue + " block")
                .background(SpaceContentMarker(name: "space-note-block-" + block.id.uuidString))
            Menu {
                Button("Create ticket") { prepareTicket(block.id) }.disabled(block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Divider()
                Menu("Turn into") { ForEach(SpaceNoteBlock.Kind.allCases, id: \.self) { kind in Button(kind.rawValue) { editBlock(block.id) { $0.kind = kind } } } }
                Divider()
                Button("Move Up") { move(block.id, by: -1) }.disabled(note?.blocks.first?.id == block.id)
                Button("Move Down") { move(block.id, by: 1) }.disabled(note?.blocks.last?.id == block.id)
                Button("Duplicate") { update { note in if let index = note.blocks.firstIndex(where: { $0.id == block.id }) { var copy = block; copy.id = UUID(); note.blocks.insert(copy, at: index + 1) } } }
                Button("Remove Block") { update { $0.blocks.removeAll { $0.id == block.id } } }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Block options")
                .background(SpaceContentMarker(name: "note-block-options-" + block.id.uuidString))
        }
    }
    @ViewBuilder private var linkedTickets: some View {
        if !relatedTickets.isEmpty {
            Divider().padding(.top, 12)
            Text("Linked tickets (\(relatedTickets.count))").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .background(SpaceContentMarker(name: "note-linked-tickets"))
            ForEach(relatedTickets) { ticket in
                Button { model.openTicket(ticket.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: ticket.kind.symbol).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ticket.key).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            Text(ticket.displayTitle).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Text(ticket.archived ? "Archived · " + ticket.status.rawValue : ticket.status.rawValue)
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(ticket.status.tint)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline) }
                }.buttonStyle(.plain).accessibilityLabel("Open ticket " + ticket.key + ", " + ticket.status.rawValue)
                    .background(SpaceContentMarker(name: "note-linked-ticket-" + ticket.id.uuidString))
            }
        }
    }
    private func prepareTicket(_ blockID: UUID, selection: NoteTextSelection? = nil) {
        guard let note else { return }
        do {
            let project = model.selectedProject.flatMap { $0.spaceID == spaceID ? $0.id : nil }
            ticketDraft = try NoteTicketDraft(note: note, spaceID: spaceID, blockID: blockID, selection: selection, projectID: project)
            ticketError = nil
        } catch { ticketError = error.localizedDescription }
    }
    private func font(_ kind: SpaceNoteBlock.Kind) -> Font {
        switch kind {
        case .heading: .system(size: 23, weight: .semibold)
        case .subheading: .system(size: 18, weight: .semibold)
        case .code: .system(size: 13, design: .monospaced)
        default: .system(size: 14)
        }
    }
    private func update(_ change: (inout SpaceNote) -> Void) { model.updateSpaceNote(noteID, in: spaceID, change) }
    private func editBlock(_ id: UUID, _ change: (inout SpaceNoteBlock) -> Void) {
        update { note in if let index = note.blocks.firstIndex(where: { $0.id == id }) { change(&note.blocks[index]) } }
    }
    private func addBlock(_ kind: SpaceNoteBlock.Kind, after id: UUID? = nil) {
        let block = SpaceNoteBlock(kind: kind)
        update { note in
            let position = (id ?? focusedBlock).flatMap { target in note.blocks.firstIndex { $0.id == target } }.map { $0 + 1 } ?? note.blocks.count
            note.blocks.insert(block, at: position)
        }
        focusedBlock = block.id
    }
    private func move(_ id: UUID, by offset: Int) {
        update { note in
            guard let index = note.blocks.firstIndex(where: { $0.id == id }), note.blocks.indices.contains(index + offset) else { return }
            note.blocks.swapAt(index, index + offset)
        }
    }
}

/// Intercept Shift-Return before TextField submits and ends its editing session.
/// Keep the native field editor so selection, undo and input methods still work.
private struct NoteLineBreakHandler: NSViewRepresentable {
    var isEditingBlock: Bool

    func makeNSView(context: Context) -> KeyTarget { KeyTarget() }
    func updateNSView(_ view: KeyTarget, context: Context) { view.isEditingBlock = isEditingBlock }
    static func dismantleNSView(_ view: KeyTarget, coordinator: ()) { view.stopMonitoring() }

    final class KeyTarget: NSView {
        var isEditingBlock = false
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, isEditingBlock, !isHiddenOrHasHiddenAncestor, let window, event.window === window,
                      event.modifierFlags.intersection([.shift, .command, .control, .option]) == .shift,
                      [36, 76].contains(event.keyCode), let editor = window.firstResponder as? NSTextView,
                      editor.isFieldEditor, !editor.hasMarkedText() else { return event }
                editor.insertNewlineIgnoringFieldEditor(nil)
                return nil
            }
        }
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}

struct SpaceContentHeader<Actions: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let space: ProjectSpace
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 12) {
            Button { model.showsProjectSidebar.toggle() } label: { Image(systemName: "sidebar.left") }.buttonStyle(WorkspaceButtonStyle(kind: .quiet)).help("Show or hide spaces and projects")
            Text(space.name).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 20, weight: .semibold)).tracking(-0.3)
            Spacer(minLength: 8)
            actions()
        }.padding(.horizontal, 24).frame(height: 68).background(Theme.canvas)
    }
}

struct SpaceContentMarker: View {
    let name: String
    var body: some View {
        #if DEBUG
        DebugViewMarker(name: name)
        #else
        EmptyView()
        #endif
    }
}
