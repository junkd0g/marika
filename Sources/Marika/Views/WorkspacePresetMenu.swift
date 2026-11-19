import MarikaCore
import SwiftUI

struct WorkspacePresetMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var body: some View {
        Menu {
            ForEach(WorkspaceFocus.allCases) { focus in
                Button { model.applyViewPreset(focus.preset, project: project) } label: { Label(focus.rawValue, systemImage: focus.symbol) }
            }
            if let presets = model.project(id: project.id)?.viewPresets, !presets.isEmpty {
                Divider()
                ForEach(presets) { preset in Button(preset.name) { model.applyViewPreset(preset, project: project) } }
                Menu("Remove saved layout") {
                    ForEach(presets) { preset in Button(preset.name) { model.updateProject(project.id) { $0.viewPresets?.removeAll { $0.id == preset.id } } } }
                }
            }
            Divider()
            Button("Save current layout…") { model.promptForViewPreset(project: project) }
        } label: { Image(systemName: "rectangle.3.group") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Focused workspace layouts").accessibilityLabel("Workspace layouts")
        #if DEBUG
        .background(DebugViewMarker(name: "workspace-layouts"))
        #endif
    }
}
