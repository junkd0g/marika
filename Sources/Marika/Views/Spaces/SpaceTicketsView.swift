import MarikaCore
import SwiftUI

struct SpaceTicketsView: View {
    @Environment(AppModel.self) private var model
    let spaceID: UUID
    @State private var query = ""
    @State private var archived = false
    @State private var priority: SpaceTicket.Priority?
    @State private var projectID: UUID?
    @State private var listLayout = false
    @State private var editingID: UUID?
    private var space: ProjectSpace { model.workspace.spaces.first { $0.id == spaceID } ?? model.selectedSpace }
    private var tickets: [SpaceTicket] {
        space.tickets.filter { $0.archived == archived && (priority == nil || $0.priority == priority) &&
            (projectID == nil || $0.projectID == projectID) && (query.isEmpty || $0.searchableText.localizedStandardContains(query)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        VStack(spacing: 0) {
            SpaceContentHeader(title: "Tickets", space: space) {
                Button { archived.toggle() } label: { Label("Archive", systemImage: archived ? "archivebox.fill" : "archivebox") }
                    .buttonStyle(WorkspaceButtonStyle(kind: .quiet))
                    .background(archived ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .background(SpaceContentMarker(name: "space-ticket-show-archive"))
                Button("New Ticket", systemImage: "plus") { create(.todo) }.buttonStyle(WorkspaceButtonStyle(kind: .primary))
                    .background(SpaceContentMarker(name: "space-ticket-new"))
            }
            Divider()
            filters
            Divider()
            if listLayout { ticketList }
            else { board }
        }.background(Theme.canvas)
            .sheet(item: Binding<SpaceTicket?>(get: { editingID.flatMap { model.ticket($0, in: spaceID) } }, set: { if $0 == nil { editingID = nil } })) { ticket in
                SpaceTicketEditor(spaceID: spaceID, ticketID: ticket.id).environment(model)
            }
            .background(SpaceContentMarker(name: "space-tickets"))
            .onChange(of: model.workspace.projects(in: spaceID).map(\.id), initial: true) {
                if let projectID, !model.workspace.projects(in: spaceID).contains(where: { $0.id == projectID }) {
                    self.projectID = nil
                }
            }
    }
    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { search; priorityFilter; projectFilter; Spacer(minLength: 0); layoutPicker }
            VStack(spacing: 10) { search; HStack { priorityFilter; projectFilter; Spacer(minLength: 0); layoutPicker } }
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }
    private var search: some View {
        WorkspaceSearchField(placeholder: "Search tickets", text: $query).frame(minWidth: 160, maxWidth: 310)
            .accessibilityLabel("Search space tickets")
    }
    private var priorityFilter: some View {
        WorkspaceSelect(title: "Priority", selection: $priority,
            options: [Optional<SpaceTicket.Priority>.none] + SpaceTicket.Priority.allCases.map(Optional.some),
            label: { $0?.rawValue ?? "All priorities" }, symbol: "flag", height: 36)
            .frame(width: 154)
    }
    private var projectFilter: some View {
        WorkspaceSelect(title: "Project", selection: $projectID,
            options: [Optional<UUID>.none] + model.workspace.projects(in: spaceID).map { Optional($0.id) },
            label: { $0.flatMap(model.project(id:))?.name ?? "All projects" }, symbol: "folder", height: 36)
            .frame(width: 170)
    }
    private var layoutPicker: some View {
        WorkspaceSegmentedControl(selection: $listLayout, firstTitle: "Board", firstSymbol: "rectangle.3.group",
            secondTitle: "List", secondSymbol: "list.bullet", iconsOnly: true)
            .accessibilityLabel("Ticket board or list")
    }
    private var board: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(SpaceTicket.Status.allCases, id: \.self) { status in
                        column(status).frame(width: max(225, (geometry.size.width - 82) / 4), height: max(250, geometry.size.height - 40))
                    }
                }.padding(20)
            }
        }
    }
    private func column(_ status: SpaceTicket.Status) -> some View {
        let items = tickets.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(status.tint).frame(width: 7, height: 7)
                Text(status.rawValue).font(.system(size: 12, weight: .semibold))
                Text(String(items.count)).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if !archived { Button { create(status) } label: { Image(systemName: "plus") }.buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true)).help("New ticket in " + status.rawValue) }
            }.padding(.horizontal, 12).padding(.top, 14)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { ticket in card(ticket) }
                    if items.isEmpty { Text(query.isEmpty ? "No tickets" : "No matching tickets").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 25) }
                }.padding(.horizontal, 9).padding(.bottom, 12)
            }
        }.background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline) }
            .background(SpaceContentMarker(name: "space-ticket-column-" + status.rawValue))
    }
    private func card(_ ticket: SpaceTicket) -> some View {
        Button { editingID = ticket.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(ticket.key, systemImage: ticket.kind.symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Image(systemName: ticket.priority.symbol).foregroundStyle(ticket.priority.tint).help(ticket.priority.rawValue + " priority").padding(.trailing, 22)
                }
                Text(ticket.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(4).multilineTextAlignment(.leading)
                if !ticket.body.isEmpty { Text(String(ticket.body.split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "#*>- "))).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                if let project = ticket.projectID.flatMap(model.project(id:)) {
                    Label(project.name, systemImage: "folder").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                if !ticket.assignee.isEmpty { Label(ticket.assignee, systemImage: "person.crop.circle").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                Menu { ticketActions(ticket) } label: { Image(systemName: "ellipsis").frame(width: 18, height: 16) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(10)
                    .accessibilityLabel("Actions for " + ticket.key)
            }
            .accessibilityLabel(ticket.key + ": " + ticket.displayTitle + ", " + ticket.status.rawValue)
            .contextMenu { ticketActions(ticket) }
            .background(SpaceContentMarker(name: "space-ticket-" + ticket.id.uuidString))
    }
    private var ticketList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(tickets) { ticket in
                    Button { editingID = ticket.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: ticket.kind.symbol).foregroundStyle(.secondary)
                            Text(ticket.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                            Text(ticket.displayTitle).font(.system(size: 12)).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(ticket.status.rawValue).font(.system(size: 10)).foregroundStyle(ticket.status.tint)
                            Image(systemName: ticket.priority.symbol).foregroundStyle(ticket.priority.tint)
                        }.padding(14).contentShape(Rectangle())
                    }.buttonStyle(.plain).contextMenu { ticketActions(ticket) }
                    Divider()
                }
                if tickets.isEmpty { ContentUnavailableView("No matching tickets", systemImage: "checklist", description: Text("Create a ticket or adjust the filters.")).padding(30) }
            }.padding(20)
        }
    }
    @ViewBuilder private func ticketActions(_ ticket: SpaceTicket) -> some View {
        if !ticket.archived {
            Menu("Set Status") { ForEach(SpaceTicket.Status.allCases, id: \.self) { status in Button(status.rawValue) { model.updateSpaceTicket(ticket.id, in: spaceID) { $0.status = status } } } }
        }
        Button(ticket.archived ? "Restore Ticket" : "Archive Ticket") { model.updateSpaceTicket(ticket.id, in: spaceID) { $0.archived.toggle() } }
    }
    private func create(_ status: SpaceTicket.Status) {
        archived = false; query = ""; priority = nil; projectID = nil
        editingID = model.addSpaceTicket(in: spaceID, status: status)
    }
}

private struct SpaceTicketEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let spaceID: UUID
    let ticketID: UUID
    @State private var preview = false
    private enum Field: Hashable { case title, description, assignee }
    @FocusState private var focusedField: Field?
    private var ticket: SpaceTicket? { model.ticket(ticketID, in: spaceID) }

    var body: some View {
        if let ticket {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: ticket.kind.symbol).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.action).frame(width: 36, height: 36)
                        .background(Theme.action.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ticket details").font(.system(size: 14, weight: .semibold))
                        Text(ticket.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(ticket.archived ? "Restore" : "Archive", systemImage: ticket.archived ? "arrow.uturn.backward" : "archivebox") {
                        update { $0.archived.toggle() }; dismiss()
                    }.buttonStyle(WorkspaceButtonStyle(kind: .quiet))
                        .background(SpaceContentMarker(name: "space-ticket-archive"))
                    Button("Done") { dismiss() }.buttonStyle(WorkspaceButtonStyle(kind: .primary))
                        .keyboardShortcut(.cancelAction)
                        .background(SpaceContentMarker(name: "space-ticket-done"))
                }.padding(.horizontal, 24).padding(.vertical, 18)
                Divider()
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 22) {
                        WorkspaceFormField(title: "Title") {
                            TextField("Give this ticket a clear title", text: binding(\.title, fallback: ""), axis: .vertical)
                                .textFieldStyle(.plain).font(.system(size: 23, weight: .semibold))
                                .focused($focusedField, equals: .title).lineLimit(1...4)
                                .accessibilityLabel("Ticket title")
                                .background(SpaceContentMarker(name: "space-ticket-title"))
                        }
                        VStack(spacing: 12) {
                            HStack {
                                Text("Description").font(.system(size: 12, weight: .semibold))
                                Spacer()
                                WorkspaceSegmentedControl(selection: $preview, firstTitle: "Write", firstSymbol: "square.and.pencil",
                                    secondTitle: "Preview", secondSymbol: "eye")
                            }
                            descriptionEditor(ticket)
                        }.frame(maxHeight: .infinity)
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                            Text("Changes save automatically")
                            Spacer()
                            Text("Markdown supported")
                        }.font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    properties(ticket).padding(20).frame(width: 226, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .top).background(Theme.panel)
                }
            }.frame(width: 780, height: 650).background(Theme.canvas)
                .onAppear { focusedField = ticket.title.isEmpty ? .title : nil }
                .background(SpaceContentMarker(name: "space-ticket-editor"))
        }
    }

    private func descriptionEditor(_ ticket: SpaceTicket) -> some View {
        Group {
            if preview {
                ScrollView {
                    MarkdownView(text: ticket.body.isEmpty ? "Add a description to capture the work, context and acceptance criteria." : ticket.body)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                TextEditor(text: binding(\.body, fallback: ""))
                    .focused($focusedField, equals: .description)
                    .font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(12).accessibilityLabel("Ticket description")
                    .background(SpaceContentMarker(name: "space-ticket-description"))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(focusedField == .description ? Theme.action : Theme.hairline,
                    lineWidth: focusedField == .description ? 1.5 : 1)
            }
    }

    private func properties(_ ticket: SpaceTicket) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Properties").font(.system(size: 12, weight: .semibold)).padding(.bottom, 2)
            WorkspaceFormField(title: "Status") {
                WorkspaceSelect(title: "Status", selection: binding(\.status, fallback: .todo), options: SpaceTicket.Status.allCases,
                    label: { $0.rawValue }, symbol: "circle.fill", tint: ticket.status.tint)
            }
            WorkspaceFormField(title: "Priority") {
                WorkspaceSelect(title: "Priority", selection: binding(\.priority, fallback: .medium), options: SpaceTicket.Priority.allCases,
                    label: { $0.rawValue }, symbol: ticket.priority.symbol, tint: ticket.priority.tint)
            }
            WorkspaceFormField(title: "Type") {
                WorkspaceSelect(title: "Type", selection: binding(\.kind, fallback: .task), options: SpaceTicket.Kind.allCases,
                    label: { $0.rawValue }, symbol: ticket.kind.symbol)
            }
            Divider()
            WorkspaceFormField(title: "Assignee") {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                    TextField("Unassigned", text: binding(\.assignee, fallback: ""))
                        .textFieldStyle(.plain).focused($focusedField, equals: .assignee)
                        .accessibilityLabel("Ticket assignee")
                }.workspaceControl(focused: focusedField == .assignee)
            }
            WorkspaceFormField(title: "Project") {
                WorkspaceSelect(title: "Project", selection: binding(\.projectID, fallback: nil),
                    options: [Optional<UUID>.none] + model.workspace.projects(in: spaceID).map { Optional($0.id) },
                    label: { $0.flatMap(model.project(id:))?.name ?? "No project" }, symbol: "folder")
            }
        }
    }

    private func update(_ change: (inout SpaceTicket) -> Void) { model.updateSpaceTicket(ticketID, in: spaceID, change) }
    private func binding<Value>(_ path: WritableKeyPath<SpaceTicket, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { ticket?[keyPath: path] ?? fallback }, set: { value in update { $0[keyPath: path] = value } })
    }
}

private extension SpaceTicket.Status {
    var tint: Color {
        switch self { case .backlog: .secondary; case .todo: .blue; case .inProgress: .orange; case .done: .green }
    }
}
private extension SpaceTicket.Priority {
    var tint: Color { switch self { case .low: .secondary; case .medium: .blue; case .high: .orange; case .urgent: .red } }
    var symbol: String { switch self { case .low: "arrow.down"; case .medium: "equal"; case .high: "arrow.up"; case .urgent: "exclamationmark.2" } }
}
private extension SpaceTicket.Kind {
    var symbol: String { switch self { case .task: "checkmark.square"; case .bug: "ladybug"; case .feature: "sparkles" } }
}
