import MarikaCore
import SwiftUI

extension ProjectSpaceColor {
    var tint: Color {
        switch self {
        case .blue: .blue
        case .violet: .purple
        case .teal: .teal
        case .amber: .orange
        case .rose: .pink
        case .graphite: .secondary
        }
    }
}

struct SpaceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let spaceID: UUID?
    @State private var name: String
    @State private var color: ProjectSpaceColor
    @State private var symbol: String
    @FocusState private var nameFocused: Bool

    init(space: ProjectSpace?) {
        spaceID = space?.id
        _name = State(initialValue: space?.name ?? "")
        _color = State(initialValue: space?.color ?? .violet)
        _symbol = State(initialValue: space?.symbol ?? "briefcase.fill")
    }

    private var validName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 40
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(color.tint)
                    .frame(width: 44, height: 44).background(color.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(spaceID == nil ? "New space" : "Edit space").font(.system(size: 19, weight: .semibold))
                    Text("A place for projects that belong together.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Name").font(.system(size: 12, weight: .medium))
                TextField("Space name", text: $name).textFieldStyle(.roundedBorder).focused($nameFocused)
                    .onSubmit(save).accessibilityLabel("Space name")
                if name.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
                    Text("Use 40 characters or fewer.").font(.caption).foregroundStyle(Theme.attention)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Icon").font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    ForEach(ProjectSpace.symbols, id: \.self) { choice in
                        Button { symbol = choice } label: {
                            Image(systemName: choice).font(.system(size: 15)).frame(width: 36, height: 34)
                                .foregroundStyle(symbol == choice ? color.tint : .secondary)
                                .background(symbol == choice ? color.tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel("Space icon " + choice)
                            .accessibilityAddTraits(symbol == choice ? [.isSelected] : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Color").font(.system(size: 12, weight: .medium))
                HStack(spacing: 12) {
                    ForEach(ProjectSpaceColor.allCases, id: \.self) { choice in
                        Button { color = choice } label: {
                            Circle().fill(choice.tint).frame(width: 23, height: 23)
                                .padding(4).overlay { Circle().strokeBorder(color == choice ? choice.tint : .clear, lineWidth: 1.5) }
                        }.buttonStyle(.plain).help(choice.rawValue.capitalized)
                            .accessibilityLabel(choice.rawValue.capitalized)
                            .accessibilityAddTraits(color == choice ? [.isSelected] : [])
                        #if DEBUG
                            .background(DebugViewMarker(name: "space-color-" + choice.rawValue))
                        #endif
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(spaceID == nil ? "Create Space" : "Save") { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!validName)
                    #if DEBUG
                        .background(DebugViewMarker(name: "space-editor-save"))
                    #endif
            }.padding(.top, 2)
        }.padding(24).frame(width: 420).background(Theme.canvas)
            .onAppear { nameFocused = true }
        #if DEBUG
            .background(DebugViewMarker(name: "space-editor"))
        #endif
    }

    private func save() {
        guard validName else { return }
        if model.saveSpace(spaceID, name: name, color: color, symbol: symbol) { dismiss() }
    }
}

struct SpaceEmptyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: model.selectedSpace.symbol).font(.system(size: 34, weight: .light))
                .foregroundStyle(model.selectedSpace.color.tint).frame(width: 80, height: 80)
                .background(model.selectedSpace.color.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))
            VStack(spacing: 8) {
                Text(model.selectedSpace.name).font(.system(size: 25, weight: .semibold))
                Text("Add a project to this space.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { model.chooseProject() } label: { Label("Open Project", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                if !model.workspace.projects.isEmpty {
                    Menu("Move Existing Project") {
                        ForEach(model.workspace.spaces.filter { $0.id != model.selectedSpace.id }) { space in
                            Menu(space.name) {
                                ForEach(model.workspace.projects(in: space.id)) { project in
                                    Button(project.name) {
                                        if model.moveProject(project.id, toSpace: model.selectedSpace.id) { model.openProject(project) }
                                    }
                                }
                            }
                        }
                    }
                }
            }.controlSize(.large).fixedSize(horizontal: true, vertical: false).padding(.top, 4)
            Text("Open a folder or drop one here · ⌘O").font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
        #if DEBUG
            .background(DebugViewMarker(name: "space-empty"))
        #endif
    }
}
