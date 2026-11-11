import AppKit
import MarikaCore
import SwiftUI

/// The Design tab: layers on the left, the canvas with a floating toolbar, and an inspector on the right.
/// Side panels fold into popovers when the pane is narrow.
struct ProjectDesignView: View {
    let project: Project
    let canvas: DesignCanvasModel
    @State private var width: CGFloat = 1000
    @State private var showsLayers = false
    @State private var showsInspector = false
    @State private var showsComponents = false

    // Reserve a useful drawing area before pinning either panel open.
    private var hasLayers: Bool { width >= 1_150 }
    private var hasInspector: Bool { width >= 900 }

    var body: some View {
        HStack(spacing: 0) {
            if hasLayers {
                DesignLayersPanel(canvas: canvas, projectName: project.name).frame(width: 200)
                Divider()
            }
            DesignCanvasView(canvas: canvas)
                .overlay(alignment: .top) { foldedPanels.padding(10) }
                .overlay(alignment: .bottom) { DesignToolbar(canvas: canvas).padding(.bottom, 14) }
            if hasInspector {
                Divider()
                DesignInspector(canvas: canvas).frame(width: 244)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Theme.panel)
        .onChange(of: canvas.editor.document) { _, _ in canvas.prune() }
        .onChange(of: canvas.selection) { _, _ in canvas.revealSelectedLayers() }
        .onChange(of: canvas.editor.externalRevision) { _, _ in canvas.externalChange() }
        .sheet(isPresented: Binding(get: { canvas.showsTemplates }, set: { canvas.showsTemplates = $0 })) { DesignTemplatePicker(canvas: canvas) }
        .sheet(isPresented: Binding(get: { canvas.showsHistory }, set: { canvas.showsHistory = $0 })) { DesignHistoryView(canvas: canvas) }
        .sheet(isPresented: Binding(get: { canvas.showsHealth }, set: { canvas.showsHealth = $0 })) { DesignHealthView(canvas: canvas) }
        .sheet(item: Binding(get: { canvas.ticketDraft }, set: { canvas.ticketDraft = $0 })) { DesignTicketEditor(canvas: canvas, draft: $0) }
        .alert(canvas.errorTitle, isPresented: Binding(
            get: { canvas.errorMessage != nil }, set: { if !$0 { canvas.errorMessage = nil } }
        )) { Button("OK") { canvas.errorMessage = nil } } message: { Text(canvas.errorMessage ?? "") }
        #if DEBUG
        .background(DebugViewMarker(name: "project-design"))
        #endif
    }

    private var foldedPanels: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { showsComponents.toggle() } label: {
                    Label { if width >= 800 { Text("Components") } } icon: { Image(systemName: "square.stack.3d.up") }
                }
                    .buttonStyle(WorkspaceButtonStyle(compact: true))
                    .accessibilityLabel("Components").help("Engineering components")
                    .popover(isPresented: $showsComponents, arrowEdge: .bottom) {
                        DesignComponentLibrary { component in
                            showsComponents = false
                            canvas.insertComponent(component)
                        }
                    }
                    #if DEBUG
                    .background(DebugViewMarker(name: "design-components-toggle"))
                    #endif
                Menu {
                    Button("Insert template…") { canvas.showsTemplates = true }
                    Menu("Tidy layout") {
                        Button("Left to right") { canvas.tidy(.horizontal) }
                        Button("Top to bottom") { canvas.tidy(.vertical) }
                    }.disabled(canvas.doc.nodes.isEmpty)
                    Button("Create implementation ticket…") { canvas.prepareTicket() }.disabled(canvas.selection.isEmpty)
                    Divider()
                    Button("Versions and changes…") { canvas.showsHistory = true }
                } label: {
                    Label { if width >= 800 { Text("Diagram") } } icon: { Image(systemName: "square.grid.3x3") }
                }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Diagram actions")
                Button { canvas.showsHealth = true } label: {
                    Label { if width >= 800 { Text("Health") } } icon: { Image(systemName: "checkmark.shield") }
                }.buttonStyle(WorkspaceButtonStyle(compact: true)).accessibilityLabel("Design health")
                #if DEBUG
                .background(DebugViewMarker(name: "design-health-toggle"))
                #endif
                if !hasLayers {
                    Button { showsLayers.toggle() } label: {
                        Label { if width >= 800 { Text("Layers") } } icon: { Image(systemName: "square.3.layers.3d") }
                    }
                    .buttonStyle(WorkspaceButtonStyle(compact: true))
                    .accessibilityLabel("Layers").help("Layers")
                    .popover(isPresented: $showsLayers, arrowEdge: .bottom) {
                        DesignLayersPanel(canvas: canvas, projectName: project.name).frame(width: 250, height: 380)
                    }
                    #if DEBUG
                    .background(DebugViewMarker(name: "design-layers-toggle"))
                    #endif
                }
                if !hasInspector {
                    Button { showsInspector.toggle() } label: {
                        Label { if width >= 800 { Text("Properties") } } icon: { Image(systemName: "slider.horizontal.3") }
                    }
                    .buttonStyle(WorkspaceButtonStyle(compact: true))
                    .accessibilityLabel("Properties").help("Properties")
                    .popover(isPresented: $showsInspector, arrowEdge: .bottom) {
                        DesignInspector(canvas: canvas).frame(width: 250, height: 480)
                    }
                    #if DEBUG
                    .background(DebugViewMarker(name: "design-properties-toggle"))
                    #endif
                }
            }
            Spacer(minLength: 4)
            if !hasInspector {
                HStack(spacing: 0) {
                    DesignZoomMenu(canvas: canvas)
                    DesignExportMenu(canvas: canvas, compact: width < 640)
                }
                .modifier(DesignFloatingSurface())
            }
        }
    }
}

private struct DesignFloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(4)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline) }
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
    }
}

/// Tools float over the bottom of the canvas, where the pointer already is.
private struct DesignToolbar: View {
    let canvas: DesignCanvasModel

    var body: some View {
        HStack(spacing: 2) {
            tool(.select)
            tool(.hand)
            separator
            tool(.frame)
            HStack(spacing: 0) {
                DesignIconButton(symbol: canvas.lastShape.symbol, help: canvas.lastShape.help,
                                 active: DesignTool.shapes.contains(canvas.tool), size: 32) { canvas.choose(canvas.lastShape) }
                Menu {
                    ForEach(DesignTool.shapes, id: \.self) { shape in
                        Button { canvas.choose(shape) } label: { Label(shape.help, systemImage: shape.symbol) }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 14, height: 32).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Shapes").accessibilityLabel("Shapes")
            }
            tool(.text)
            tool(.connector)
            separator
            DesignIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", size: 32) { canvas.editor.undo(); canvas.prune() }
                .disabled(!canvas.editor.canUndo)
            DesignIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", size: 32) { canvas.editor.redo(); canvas.prune() }
                .disabled(!canvas.editor.canRedo)
            separator
            DesignIconButton(symbol: "text.bubble", help: "Use in Chat: add the selected elements, or the visible canvas if nothing is selected, to your chat draft.", size: 32) {
                canvas.useInChat()
            }
            .disabled(!canvas.hasDesignReference || canvas.preparingReference)
        }
        .modifier(DesignFloatingSurface())
        #if DEBUG
        .background(DebugViewMarker(name: "design-toolbar"))
        #endif
    }

    private var separator: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 20).padding(.horizontal, 4)
    }

    private func tool(_ tool: DesignTool) -> some View {
        DesignIconButton(symbol: tool.symbol, help: tool.help, active: canvas.tool == tool, size: 32) { canvas.tool = tool }
    }
}
