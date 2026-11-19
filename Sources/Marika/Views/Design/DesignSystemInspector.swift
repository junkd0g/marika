import MarikaCore
import SwiftUI

struct DesignSystemInspector: View {
    let canvas: DesignCanvasModel
    private var node: DesignNode? { canvas.selectedNodes.count == 1 ? canvas.selectedNodes.first : nil }
    private var system: DesignSystem { canvas.doc.designSystem ?? DesignSystem() }
    var body: some View {
        DesignSection("Shared styles") {
            Picker("Color", selection: Binding(get: { node?.colorTokenID }, set: { value in canvas.changeSystem { $0.bindColor(value, to: canvas.selection) } })) {
                Text("Custom").tag(nil as UUID?)
                ForEach(system.colors) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Text", selection: Binding(get: { node?.typeTokenID }, set: { value in canvas.changeSystem { $0.bindTypography(value, to: canvas.selection) } })) {
                Text("Custom").tag(nil as UUID?)
                ForEach(system.typography) { Text($0.name).tag(Optional($0.id)) }
            }
            Button("Manage design system…") { canvas.showsSystem = true }.buttonStyle(WorkspaceButtonStyle(compact: true))
        }
        if let node, node.kind == .frame {
            DesignSection("Frame layout") {
                Picker("Flow", selection: Binding(get: { node.autoLayout?.axis }, set: { axis in
                    canvas.changeSystem { doc in try doc.configureLayout(node.id, configuration: axis.map { DesignAutoLayout(axis: $0, gap: node.autoLayout?.gap ?? 16, padding: node.autoLayout?.padding ?? 16, spacingTokenID: node.autoLayout?.spacingTokenID) }) }
                })) {
                    Text("Free position").tag(nil as DesignAutoLayout.Axis?)
                    Text("Row").tag(Optional(DesignAutoLayout.Axis.row))
                    Text("Column").tag(Optional(DesignAutoLayout.Axis.column))
                }
                if let layout = node.autoLayout {
                    Stepper("Gap \(Int(layout.gap))", value: Binding(get: { layout.gap }, set: { value in changeLayout(node) { $0.gap = value; $0.spacingTokenID = nil } }), in: 0...256)
                    Stepper("Padding \(Int(layout.padding))", value: Binding(get: { layout.padding }, set: { value in changeLayout(node) { $0.padding = value } }), in: 0...256)
                    Picker("Gap token", selection: Binding(get: { layout.spacingTokenID }, set: { value in changeLayout(node) { $0.spacingTokenID = value } })) {
                        Text("Custom").tag(nil as UUID?)
                        ForEach(system.spacing) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Text("Frame size follows its contents. Children reflow when their size or the spacing token changes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let node, let instance = node.reusableInstance, let component = system.components.first(where: { $0.id == instance.componentID }) {
            DesignSection("Component instance") {
                Text(component.name).font(.headline)
                Menu("Switch variant (resets edits)") {
                    ForEach(component.variants) { variant in Button(variant.name) { canvas.changeSystem { try $0.switchComponentVariant(node.id, variantID: variant.id) } } }
                }
                Button("Detach instance") { canvas.changeSystem { $0.update([node.id]) { $0.reusableInstance = nil } } }
            }
        }
    }
    private func changeLayout(_ node: DesignNode, _ change: (inout DesignAutoLayout) -> Void) {
        guard var layout = node.autoLayout else { return }
        change(&layout)
        canvas.changeSystem { try $0.configureLayout(node.id, configuration: layout) }
    }
}
