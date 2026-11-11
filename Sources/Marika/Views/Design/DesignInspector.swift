import MarikaCore
import SwiftUI

/// Properties of the selection. Every control edits all selected layers and shows "Mixed" where they differ.
struct DesignInspector: View {
    let canvas: DesignCanvasModel
    @State private var editingLinks = false

    private var nodes: [DesignNode] { canvas.selectedNodes }
    private var only: DesignNode? { nodes.count == 1 ? nodes[0] : nil }

    private func shared<Value: Equatable>(_ path: KeyPath<DesignNode, Value>) -> Value? {
        guard let first = nodes.first?[keyPath: path], nodes.allSatisfy({ $0[keyPath: path] == first }) else { return nil }
        return first
    }

    private func number(_ label: String = "", symbol: String? = nil, _ path: WritableKeyPath<DesignNode, Double>,
                        range: ClosedRange<Double> = -100_000...100_000, help: String) -> DesignNumberField {
        DesignNumberField(label: label, symbol: symbol, value: shared(path), range: range, help: help) { value in
            canvas.update(help) { $0[keyPath: path] = value }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                DesignZoomMenu(canvas: canvas)
                Spacer(minLength: 4)
                DesignExportMenu(canvas: canvas)
            }
            .padding(.horizontal, 6).frame(height: 40)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let edge = canvas.activeConnection {
                        connection(edge)
                    } else if nodes.isEmpty {
                        document
                    } else {
                        layers
                    }
                }
            }
        }
        .background(Theme.panel)
        .sheet(isPresented: $editingLinks) {
            if let only { DesignLinksEditor(canvas: canvas, nodeID: only.id) }
        }
        #if DEBUG
        .background(DebugViewMarker(name: "design-inspector"))
        #endif
    }

    // MARK: Layers

    @ViewBuilder private var layers: some View {
        let locked = nodes.allSatisfy(\.isLocked)
        header(locked: locked)
        if let only {
            DesignSection("Code & documentation") {
                ForEach(only.links ?? []) { link in
                    Button {
                        Task {
                            do { try await canvas.app?.openDesignLink(link, projectID: canvas.projectID) }
                            catch { canvas.errorTitle = "Open link"; canvas.errorMessage = error.localizedDescription }
                        }
                    } label: { Label(link.displayName, systemImage: "arrow.up.forward.app").lineLimit(2) }
                    .buttonStyle(.link)
                }
                Button("Manage links…") { editingLinks = true }.buttonStyle(WorkspaceButtonStyle(compact: true)).disabled(locked)
                #if DEBUG
                .background(DebugViewMarker(name: "design-manage-links"))
                #endif
            }
        }
        DesignSection("Implementation") {
            ForEach(canvas.linkedTickets) { ticket in
                Button { canvas.app?.openTicket(ticket.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ticket.key + " · " + ticket.status.rawValue).font(.caption)
                        Text(ticket.displayTitle).font(.system(size: 12)).lineLimit(2)
                    }
                }.buttonStyle(.link)
            }
            Button("Create ticket…") { canvas.prepareTicket() }.buttonStyle(WorkspaceButtonStyle(compact: true))
        }
        if let component = only?.component {
            DesignSection("Component") {
                Label(component.title, systemImage: component.symbol).font(.system(size: 12, weight: .semibold))
                Text(component.summary).font(.caption).foregroundStyle(.secondary)
                Button("Use plain shape") {
                    canvas.update("component") {
                        $0.fontWeight = $0.fontWeight ?? .semibold
                        $0.textAlign = $0.textAlign ?? .left
                        $0.component = nil
                    }
                }
                    .buttonStyle(WorkspaceButtonStyle(compact: true))
            }
            .disabled(locked)
        }
        Group {
            position
            layout
            if nodes.contains(where: { !$0.isLinear }) { typography }
            if nodes.contains(where: { !$0.isLinear }) { fill }
            stroke
            shadow
        }
        .disabled(locked)
        if let only { description(only).disabled(locked) }
        DesignSection {
            Button { canvas.useInChat() } label: { Label("Use in Chat", systemImage: "text.bubble").frame(maxWidth: .infinity) }
                .buttonStyle(WorkspaceButtonStyle(kind: .primary, compact: true))
                .disabled(canvas.preparingReference)
                .help("Add the selected elements to your chat draft.")
        }
    }

    private func header(locked: Bool) -> some View {
        DesignSection {
            HStack(spacing: 8) {
                Image(systemName: only?.component?.symbol ?? only?.kind.symbol ?? "square.on.square").foregroundStyle(.secondary).frame(width: 16)
                if let only {
                    TextField("Name", text: Binding(
                        get: { canvas.doc.node(only.id)?.name ?? "" },
                        set: { value in canvas.update("name") { $0.name = String(value.prefix(500)) } }))
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).disabled(locked)
                        .accessibilityLabel("Layer name")
                } else {
                    Text("\(nodes.count) layers").font(.system(size: 13, weight: .semibold))
                }
                Spacer(minLength: 0)
                if locked {
                    DesignIconButton(symbol: "lock.fill", help: "Unlock") { canvas.setLocked(false) }
                }
            }
        }
    }

    private var position: some View {
        DesignSection("Position") {
            HStack(spacing: 1) {
                ForEach([("align.horizontal.left", DesignDocument.Alignment.left, "Align left"),
                         ("align.horizontal.center", .centerX, "Align horizontal centers"),
                         ("align.horizontal.right", .right, "Align right"),
                         ("align.vertical.top", .top, "Align top"),
                         ("align.vertical.center", .centerY, "Align vertical centers"),
                         ("align.vertical.bottom", .bottom, "Align bottom")], id: \.2) { symbol, alignment, help in
                    DesignIconButton(symbol: symbol, help: help) { canvas.align(alignment) }.disabled(!canvas.canAlign)
                }
                Spacer(minLength: 0)
                DesignIconButton(symbol: "distribute.horizontal.center", help: "Distribute horizontal spacing") { canvas.distribute(.horizontal) }
                    .disabled(canvas.editableSelection.count < 3)
                DesignIconButton(symbol: "distribute.vertical.center", help: "Distribute vertical spacing") { canvas.distribute(.vertical) }
                    .disabled(canvas.editableSelection.count < 3)
            }
            HStack(spacing: 6) {
                number("X", \.x, help: "X position")
                number("Y", \.y, help: "Y position")
            }
            HStack(spacing: 6) {
                DesignNumberField(symbol: "angle", value: shared(\.rotation).map { $0 ?? 0 }, range: -360...360, help: "Rotation") { value in
                    canvas.update("Rotation") { $0.rotation = value }
                }
                HStack(spacing: 1) {
                    DesignIconButton(symbol: "square.3.layers.3d.top.filled", help: "Bring to front (])") { canvas.reorder(toFront: true) }
                    DesignIconButton(symbol: "square.3.layers.3d.bottom.filled", help: "Send to back ([)") { canvas.reorder(toFront: false) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var layout: some View {
        DesignSection("Layout") {
            HStack(spacing: 6) {
                if nodes.allSatisfy(\.isLinear) {
                    number(symbol: "ruler", \.width, range: DesignDocument.minimumSize...20_000, help: "Length")
                } else {
                    number("W", \.width, range: DesignDocument.minimumSize...20_000, help: "Width")
                    number("H", \.height, range: DesignDocument.minimumSize...20_000, help: "Height")
                }
            }
            HStack(spacing: 6) {
                DesignNumberField(symbol: "circle.lefthalf.filled", value: shared(\.opacity).map { $0 * 100 }, range: 0...100, help: "Opacity") { value in
                    canvas.update("Opacity") { $0.opacity = value / 100 }
                }
                if nodes.allSatisfy({ $0.kind == .rectangle || $0.kind == .frame }) {
                    number(symbol: "square.dashed", \.cornerRadius, range: 0...20_000, help: "Corner radius")
                } else if nodes.allSatisfy({ $0.kind == .polygon || $0.kind == .star }) {
                    DesignNumberField(symbol: "pentagon", value: shared(\.kind).flatMap { kind in shared(\.sides).map { Double($0 ?? (kind == .star ? 5 : 3)) } },
                                      range: 3...12, help: nodes.contains { $0.kind == .star } ? "Points" : "Corners") { value in
                        canvas.update("Sides") { $0.sides = Int(value.rounded()) }
                    }
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
        }
    }

    private var typography: some View {
        DesignSection(nodes.allSatisfy { $0.kind == .text } ? "Text" : "Label") {
            if let only {
                TextField(only.kind == .text ? "Text" : "Label shown inside the shape", text: Binding(
                    get: { canvas.doc.node(only.id)?.text ?? "" },
                    set: { value in canvas.update("text") { $0.text = String(value.prefix(10_000)); DesignCanvasModel.growToFit(&$0) } }), axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...5)
                    .padding(.vertical, 6).modifier(DesignTextSurface())
                    .accessibilityLabel("Layer text")
            }
            HStack(spacing: 6) {
                DesignNumberField(symbol: "textformat.size", value: shared(\.fontSize), range: 1...500, help: "Font size") { value in
                    canvas.update("Font size") { $0.fontSize = value; DesignCanvasModel.growToFit(&$0) }
                }
                DesignMenuField(value: shared(\.resolvedWeight), options: DesignFontWeight.allCases, title: { $0.rawValue.capitalized },
                                help: "Font weight") { weight in
                    canvas.update("Font weight") { $0.fontWeight = weight; DesignCanvasModel.growToFit(&$0) }
                }
            }
            HStack(spacing: 1) {
                ForEach([(DesignTextAlign.left, "text.alignleft", "Align text left"), (.center, "text.aligncenter", "Center text"),
                         (.right, "text.alignright", "Align text right")], id: \.2) { align, symbol, help in
                    DesignIconButton(symbol: symbol, help: help, active: shared(\.resolvedAlign) == align) {
                        canvas.update("Text align") { $0.textAlign = align }
                    }
                }
            }
        }
    }

    private var fill: some View {
        DesignSection(nodes.allSatisfy { $0.kind == .text } ? "Color" : "Fill") {
            DesignColorRow(color: shared(\.fill), help: "Fill") { color in canvas.update("Fill") { $0.fill = color } }
        }
    }

    private var stroke: some View {
        // Outer nil means the layers disagree; inner nil means none of them has a stroke.
        let current = shared(\.stroke)
        let removable = nodes.contains { !$0.isLinear }
        return DesignSection(title: "Stroke", accessory: {
            if current == .some(nil) {
                DesignIconButton(symbol: "plus", help: "Add stroke", size: 22) { canvas.update("Stroke") { $0.stroke = .black } }
            } else if removable {
                DesignIconButton(symbol: "minus", help: "Remove stroke", size: 22) {
                    canvas.update("Stroke") { if !$0.isLinear { $0.stroke = nil } }
                }
            }
        }, content: {
            if current != .some(nil) {
                DesignColorRow(color: current.flatMap { $0 }, help: "Stroke") { color in canvas.update("Stroke color") { $0.stroke = color } }
                HStack(spacing: 6) {
                    number(symbol: "lineweight", \.strokeWidth, range: 0...100, help: "Stroke width")
                    DesignMenuField(value: shared(\.strokeStyle).map { $0 ?? .solid }, options: DesignStrokeStyle.allCases,
                                    title: { $0.rawValue.capitalized }, help: "Stroke style") { style in
                        canvas.update("Stroke style") { $0.strokeStyle = style }
                    }
                }
            }
        })
    }

    private var shadow: some View {
        let current = shared(\.shadow)
        func set(_ change: @escaping (inout DesignShadow) -> Void) {
            canvas.update("Shadow") { node in
                var value = node.shadow ?? DesignShadow()
                change(&value)
                node.shadow = value
            }
        }
        return DesignSection(title: "Shadow", accessory: {
            if current == .some(nil) {
                DesignIconButton(symbol: "plus", help: "Add shadow", size: 22) { canvas.update("Shadow") { $0.shadow = DesignShadow() } }
            } else {
                DesignIconButton(symbol: "minus", help: "Remove shadow", size: 22) { canvas.update("Shadow") { $0.shadow = nil } }
            }
        }, content: {
            if current != .some(nil) {
                let value = current.flatMap { $0 }
                DesignColorRow(color: value?.color, help: "Shadow") { color in set { $0.color = color } }
                HStack(spacing: 6) {
                    DesignNumberField(label: "X", value: value?.x, range: -1_000...1_000, help: "Shadow X offset") { x in set { $0.x = x } }
                    DesignNumberField(label: "Y", value: value?.y, range: -1_000...1_000, help: "Shadow Y offset") { y in set { $0.y = y } }
                    DesignNumberField(symbol: "drop", value: value?.blur, range: 0...1_000, help: "Shadow blur") { blur in set { $0.blur = blur } }
                }
            }
        })
    }

    private func description(_ node: DesignNode) -> some View {
        DesignSection("Description") {
            TextField("Describe its purpose, behavior, or requirements…", text: Binding(
                get: { canvas.doc.node(node.id)?.description ?? "" },
                set: { value in canvas.update("description") { $0.description = value } }), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(3...8)
                .padding(.vertical, 6).modifier(DesignTextSurface())
                .accessibilityLabel("Element description")
                .help("These notes are included when chat reads or uses the element. Up to 8,000 characters.")
            Text("Chat uses this alongside the element’s appearance.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Connection

    private func connection(_ edge: DesignConnection) -> some View {
        let from = canvas.doc.node(edge.from)?.name ?? "Missing", to = canvas.doc.node(edge.to)?.name ?? "Missing"
        return DesignSection("Connection") {
            HStack(spacing: 6) {
                Text(from).lineLimit(1)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(to).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            Picker("Flow", selection: Binding(get: { canvas.activeConnection?.flow ?? .request }, set: { value in
                canvas.edit { $0.updateConnection(edge.id) { $0.style = value == .request ? nil : value } }
            })) { ForEach(DesignFlow.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("From", selection: Binding(get: { canvas.activeConnection?.fromPort ?? .auto }, set: { value in
                canvas.edit { $0.updateConnection(edge.id) { $0.fromPort = value == .auto ? nil : value } }
            })) { ForEach(DesignPort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Picker("To", selection: Binding(get: { canvas.activeConnection?.toPort ?? .auto }, set: { value in
                canvas.edit { $0.updateConnection(edge.id) { $0.toPort = value == .auto ? nil : value } }
            })) { ForEach(DesignPort.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Toggle("Route around shapes", isOn: Binding(get: { canvas.activeConnection?.avoidsObstacles != false }, set: { value in
                canvas.edit { $0.updateConnection(edge.id) { $0.avoidsObstacles = value ? nil : false } }
            }))
            Text("Label position").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { canvas.activeConnection?.labelFraction ?? 0.5 }, set: { value in
                canvas.edit(coalescing: "edge-label") { $0.updateConnection(edge.id) { $0.labelPosition = value } }
            }), in: 0.1...0.9)
            Text("You can also drag the label on the canvas.").font(.caption2).foregroundStyle(.secondary)
            TextField("Label", text: Binding(
                get: { canvas.activeConnection?.label ?? "" },
                set: { value in canvas.edit(coalescing: "connection:\(edge.id)") { $0.updateConnection(edge.id) { $0.label = value } } }))
                .textFieldStyle(.plain).font(.system(size: 12)).modifier(DesignTextSurface())
                .accessibilityLabel("Connection label")
            HStack(spacing: 8) {
                Button("Reverse") { canvas.edit { $0.updateConnection(edge.id) { $0.reverse() } } }
                    .buttonStyle(WorkspaceButtonStyle(compact: true))
                Button("Delete") { canvas.deleteSelection() }
                    .buttonStyle(WorkspaceButtonStyle(kind: .destructive, compact: true))
            }
        }
    }

    // MARK: Nothing selected

    @ViewBuilder private var document: some View {
        DesignSection("Design") {
            TextField("Untitled", text: Binding(
                get: { canvas.doc.title ?? "" },
                set: { value in canvas.edit(coalescing: "title") { $0.title = value.isEmpty ? nil : String(value.prefix(200)) } }))
                .textFieldStyle(.plain).font(.system(size: 12)).modifier(DesignTextSurface())
                .accessibilityLabel("Design title")
            Button { canvas.useInChat() } label: { Label("Use Canvas in Chat", systemImage: "text.bubble").frame(maxWidth: .infinity) }
                .buttonStyle(WorkspaceButtonStyle(compact: true))
                .disabled(!canvas.hasDesignReference || canvas.preparingReference)
                .help("Add the visible canvas to your chat draft.")
        }
        DesignSection("Shortcuts") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach([("Move, Hand", "V, H or Space"), ("Frame, Text", "F, T"), ("Rectangle, Ellipse", "R, O"),
                         ("Line, Arrow", "L, ⇧L"), ("Connector", "C"), ("Pan", "Scroll"), ("Zoom", "⌘ Scroll or pinch"),
                         ("Zoom to fit", "⇧1"), ("Edit text", "Double-click or ↩"), ("Duplicate", "⌥ Drag or ⌘D"),
                         ("Constrain", "⇧ Drag"), ("Frame selection", "⌥⌘G"), ("Layer order", "⌘] ⌘[")], id: \.0) { name, keys in
                    GridRow {
                        Text(name).foregroundStyle(.secondary)
                        Text(keys).foregroundStyle(Theme.ink).gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.system(size: 11))
        }
    }
}

/// Background for free-text fields in the inspector.
private struct DesignTextSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
