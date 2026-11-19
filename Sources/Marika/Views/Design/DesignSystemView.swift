import AppKit
import MarikaCore
import SwiftUI

struct DesignSystemView: View {
    let canvas: DesignCanvasModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Button"
    @State private var variantName = "Default"
    @State private var selectedComponent: UUID?
    @State private var refreshTarget: (UUID, UUID)?
    @State private var confirmsRefresh = false
    private var system: DesignSystem { canvas.doc.designSystem ?? DesignSystem() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Components & design tokens").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Text("Bind layers to shared styles, save reusable controls and define their variants.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    colorTokens
                    typeTokens
                    spacingTokens
                    components
                }.padding(4)
            }
        }.padding(22).frame(width: 760, height: 680).background(Theme.panel)
            .confirmationDialog("Update these instances? Their local edits will be reset. Undo restores the previous state.", isPresented: $confirmsRefresh) {
                Button("Update instances") {
                    if let target = refreshTarget { canvas.changeSystem { _ = try $0.refreshReusableInstances(componentID: target.0, variantID: target.1) } }
                }
            }
            #if DEBUG
            .background(DebugViewMarker(name: "design-system"))
            #endif
    }
    private var colorTokens: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Colors").font(.headline); Spacer(); Button("Add color") { canvas.changeSystem { $0.updateColorToken(DesignColorToken(name: "Color \(system.colors.count + 1)", color: canvas.selectedNodes.first?.fill ?? .blue)) } } }
            ForEach(system.colors) { token in
                HStack {
                    ColorPicker("", selection: Binding(get: { token.color.color }, set: { color in var changed = token; changed.color = DesignColor(color); canvas.changeSystem { $0.updateColorToken(changed) } })).labelsHidden()
                    TextField("Name", text: Binding(get: { token.name }, set: { text in var changed = token; changed.name = String(text.prefix(80)); canvas.changeSystem { $0.updateColorToken(changed) } }))
                    Text(token.color.hex).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Button("Apply to selection") { canvas.changeSystem { $0.bindColor(token.id, to: canvas.selection) } }.disabled(canvas.selection.isEmpty)
                    Button { canvas.changeSystem { $0.designSystem?.colors.removeAll { $0.id == token.id } } } label: { Image(systemName: "minus.circle") }
                }.textFieldStyle(.roundedBorder)
            }
        }
    }
    private var typeTokens: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Typography").font(.headline); Spacer(); Button("Add text style") { canvas.changeSystem { $0.updateTypeToken(DesignTypeToken(name: "Text \(system.typography.count + 1)", size: canvas.selectedNodes.first?.fontSize ?? 16, weight: canvas.selectedNodes.first?.fontWeight)) } } }
            ForEach(system.typography) { token in
                HStack {
                    TextField("Name", text: Binding(get: { token.name }, set: { text in var changed = token; changed.name = String(text.prefix(80)); canvas.changeSystem { $0.updateTypeToken(changed) } }))
                    Stepper(value: Binding(get: { token.size }, set: { size in var changed = token; changed.size = size; canvas.changeSystem { $0.updateTypeToken(changed) } }), in: 1...200) { Text("\(Int(token.size)) pt").monospacedDigit() }.frame(width: 100)
                    Button("Apply to selection") { canvas.changeSystem { $0.bindTypography(token.id, to: canvas.selection) } }.disabled(canvas.selection.isEmpty)
                    Button { canvas.changeSystem { $0.designSystem?.typography.removeAll { $0.id == token.id } } } label: { Image(systemName: "minus.circle") }
                }.textFieldStyle(.roundedBorder)
            }
        }
    }
    private var spacingTokens: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Spacing").font(.headline); Spacer(); Button("Add spacing") { canvas.changeSystem { doc in if doc.designSystem == nil { doc.designSystem = DesignSystem() }; doc.designSystem?.spacing.append(DesignSpacingToken(name: "Space \(system.spacing.count + 1)", value: 16)) } } }
            ForEach(system.spacing) { token in
                HStack {
                    TextField("Name", text: Binding(get: { token.name }, set: { text in editSpacing(token.id) { $0.name = String(text.prefix(80)) } }))
                    Stepper(value: Binding(get: { token.value }, set: { value in editSpacing(token.id) { $0.value = value } }), in: 0...256) { Text("\(Int(token.value)) px").monospacedDigit() }.frame(width: 110)
                    Text("Used by frame layout").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { canvas.changeSystem { $0.designSystem?.spacing.removeAll { $0.id == token.id } } } label: { Image(systemName: "minus.circle") }
                }.textFieldStyle(.roundedBorder)
            }
        }
    }
    private var components: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reusable components").font(.headline)
            HStack {
                TextField("Component name", text: $name)
                TextField("Variant, e.g. Default / Hover / Disabled", text: $variantName)
                Button("Save selection") { canvas.changeSystem { _ = try $0.saveReusableComponent(name: name, variant: variantName, selection: canvas.selection) } }.disabled(canvas.selection.isEmpty)
            }.textFieldStyle(.roundedBorder)
            ForEach(system.components) { component in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(component.name).font(.headline)
                        Spacer()
                        Button("Add selection as variant") { canvas.changeSystem { _ = try $0.saveReusableComponent(name: component.name, variant: variantName, selection: canvas.selection, componentID: component.id) } }.disabled(canvas.selection.isEmpty)
                    }
                    ForEach(component.variants) { variant in
                        HStack {
                            Text(variant.name).frame(minWidth: 100, alignment: .leading)
                            Text("\(variant.clip.nodes.count) layers").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Insert") { canvas.insertReusable(component.id, variant: variant.id) }
                            Menu("Edit") {
                                Button("Replace variant from selection") { canvas.changeSystem { try $0.replaceReusableVariant(componentID: component.id, variantID: variant.id, selection: canvas.selection) } }.disabled(canvas.selection.isEmpty)
                                Button("Update instances…") { refreshTarget = (component.id, variant.id); confirmsRefresh = true }
                            }.fixedSize()
                        }
                    }
                }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func editSpacing(_ id: UUID, _ change: (inout DesignSpacingToken) -> Void) {
        canvas.changeSystem { doc in
            guard let index = doc.designSystem?.spacing.firstIndex(where: { $0.id == id }), var token = doc.designSystem?.spacing[index] else { return }
            change(&token); doc.designSystem?.spacing[index] = token
        }
    }
}

extension DesignCanvasModel {
    func changeSystem(_ change: (inout DesignDocument) throws -> Void) {
        do { var next = doc; try change(&next); edit { $0 = next }; prune() }
        catch { errorTitle = "Design system"; errorMessage = error.localizedDescription }
    }
    func insertReusable(_ component: UUID, variant: UUID) {
        var inserted: UUID?
        let center = toDoc(CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        changeSystem { inserted = try $0.insertReusableComponent(component, variantID: variant, at: center) }
        if let inserted { selection = [inserted]; selectedConnection = nil; fitSelection() }
    }
}
