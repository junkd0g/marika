import AppKit
import MarikaCore
import SwiftUI

private enum DesignTool: String, CaseIterable {
    case select = "Select", hand = "Hand", frame = "Frame", rectangle = "Rectangle", ellipse = "Ellipse", text = "Text"
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .frame: "number.square"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        }
    }
    var key: Character {
        switch self { case .select: "v"; case .hand: "h"; case .frame: "f"; case .rectangle: "r"; case .ellipse: "o"; case .text: "t" }
    }
    var kind: DesignNode.Kind? {
        switch self { case .frame: .frame; case .rectangle: .rectangle; case .ellipse: .ellipse; case .text: .text; default: nil }
    }
}

private extension DesignColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}

/// Draws one node; shared by the live canvas and PNG export.
private struct DesignNodeView: View {
    let node: DesignNode

    var body: some View {
        content
            .frame(width: node.width, height: node.height)
            .opacity(node.opacity)
            .offset(x: node.x, y: node.y)
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .text:
            Text(node.text).font(.system(size: node.fontSize)).foregroundStyle(node.fill.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .ellipse:
            Ellipse().fill(node.fill.color).overlay(stroke(Ellipse())).overlay(shapeLabel)
        case .rectangle, .frame:
            RoundedRectangle(cornerRadius: node.cornerRadius).fill(node.fill.color)
                .overlay(stroke(RoundedRectangle(cornerRadius: node.cornerRadius))).overlay(shapeLabel)
        }
    }

    private var shapeLabel: some View {
        let brightness = node.fill.red * 0.299 + node.fill.green * 0.587 + node.fill.blue * 0.114
        return Text(node.text).font(.system(size: node.fontSize, weight: .medium))
            .foregroundStyle(brightness < 0.55 ? Color.white : Color.black.opacity(0.85))
            .multilineTextAlignment(.center).padding(12)
    }

    @ViewBuilder private func stroke<S: InsettableShape>(_ shape: S) -> some View {
        if let color = node.stroke { shape.strokeBorder(color.color, lineWidth: node.strokeWidth) }
    }
}

private struct DesignScene: View {
    let nodes: [DesignNode]
    var connections: [DesignConnection] = []
    var exporting = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(connections) { connection in
                if let points = connection.route(in: nodes) {
                    DesignConnectionView(points: points, label: connection.label, exporting: exporting)
                }
            }
            ForEach(nodes.filter { !$0.isHidden }) { DesignNodeView(node: $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DesignConnectionView: View {
    let points: [CGPoint]
    let label: String
    var exporting = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addLines(points)
                if let end = points.last, let before = points.dropLast().last(where: { $0 != end }) {
                    let angle = atan2(end.y - before.y, end.x - before.x)
                    path.move(to: CGPoint(x: end.x - 10 * cos(angle - .pi / 6), y: end.y - 10 * sin(angle - .pi / 6)))
                    path.addLine(to: end)
                    path.addLine(to: CGPoint(x: end.x - 10 * cos(angle + .pi / 6), y: end.y - 10 * sin(angle + .pi / 6)))
                }
            }.stroke(Color.gray, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if !label.isEmpty, points.count == 4 {
                let middle = CGPoint(x: (points[1].x + points[2].x) / 2, y: (points[1].y + points[2].y) / 2)
                Text(label).font(.system(size: 11)).foregroundStyle(exporting ? Color.black : Color.primary)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(exporting ? Color.white : Theme.canvas, in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize().position(middle)
            }
        }
    }
}

@MainActor
enum DesignRenderer {
    static func png(document: DesignDocument, selection: Set<UUID> = []) throws -> Data {
        let plan = try DesignExportPlan(document: document, selection: selection)
        let scene = DesignScene(nodes: plan.nodes, connections: plan.connections, exporting: true)
            .offset(x: -plan.bounds.minX, y: -plan.bounds.minY)
            .frame(width: plan.bounds.width, height: plan.bounds.height, alignment: .topLeading).clipped()
            .background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: scene)
        renderer.scale = plan.scale
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw DesignToolError("The image couldn't be rendered. Try exporting fewer shapes.")
        }
        return png
    }
}

struct ProjectDesignView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @Bindable var editor: DesignWorkspace
    private var doc: DesignDocument { editor.document }
    @State private var tool = DesignTool.select
    @State private var selection: Set<UUID> = []
    @State private var zoom = 1.0
    @State private var offset = CGSize(width: 240, height: 120)
    @State private var drag: Drag?
    @State private var ignoreDragUntilEnd = false
    @State private var marquee: CGRect?
    @State private var draftRect: CGRect?
    @State private var magnifyBase: Double?
    @State private var canvasSize = CGSize.zero
    @State private var automaticallyFits = true
    @State private var exportError: String?
    @State private var panelWidth: CGFloat = 1000
    @State private var layerPopover = false
    @State private var propertyPopover = false
    @FocusState private var focused: Bool

    private enum Drag {
        case move(last: CGPoint), resize(UUID, DesignHandle), create(DesignNode.Kind, start: CGPoint)
        case marquee(start: CGPoint, base: Set<UUID>), pan(start: CGSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if geometry.size.width >= 780 {
                        layers.frame(width: 200)
                        Divider()
                    }
                    canvas.onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        canvasSize = size
                        if automaticallyFits, size.width > 0, size.height > 0 { fit() }
                    }
                    if geometry.size.width >= 580 {
                        Divider()
                        properties.frame(width: 230)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { panelWidth = $0 }
            }
        }
        .background(Theme.canvas)
        .onAppear { fit() }
        .onChange(of: doc) { _, next in
            selection = selection.filter { next.node($0) != nil }
        }
        .onChange(of: editor.externalRevision) { _, _ in
            ignoreDragUntilEnd = drag != nil
            drag = nil; marquee = nil; draftRect = nil
            fit()
        }
        .alert("Couldn't export design", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button("OK") { exportError = nil } } message: { Text(exportError ?? "") }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ScrollView(.horizontal) {
        HStack(spacing: 6) {
            if panelWidth < 780 {
                Button { layerPopover.toggle() } label: { Image(systemName: "square.3.layers.3d") }
                    .help("Layers").popover(isPresented: $layerPopover) { layers.frame(width: 240, height: 340) }
            }
            if panelWidth < 580 {
                Button { propertyPopover.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Properties").popover(isPresented: $propertyPopover) { properties.frame(width: 250, height: 440) }
            }
            ForEach(DesignTool.allCases, id: \.self) { item in
                Button { tool = item } label: {
                    Image(systemName: item.symbol).frame(width: 26, height: 22)
                        .background(tool == item ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain).help("\(item.rawValue) (\(String(item.key).uppercased()))")
            }
            Divider().frame(height: 18)
            Button { undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editor.canUndo).help("Undo")
            Button { redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editor.canRedo).help("Redo")
            Button { duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                .disabled(selection.intersection(doc.editableIDs).isEmpty).help("Duplicate")
            if panelWidth >= 780, let title = doc.title {
                Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { changeZoom(zoom / 1.25) } label: { Image(systemName: "minus") }
            Text(zoom < 0.01 ? "<1%" : "\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 44)
            Button { changeZoom(zoom * 1.25) } label: { Image(systemName: "plus") }
            Button("Fit") { fit() }.disabled(doc.visibleBounds == nil)
            Button { export() } label: { Label("Export PNG", systemImage: "square.and.arrow.up") }
                .disabled(doc.visibleBounds == nil)
        }
        .frame(minWidth: max(0, panelWidth - 20))
        .buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 6)
        }.scrollIndicators(.hidden).frame(height: 38)
    }

    // MARK: Layers

    private var layers: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Layers").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(10)
            if doc.nodes.isEmpty {
                Text("Ask your project chat to draw an architecture diagram here, or pick a shape tool and drag to draw.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(doc.nodes.reversed()) { node in
                        HStack(spacing: 6) {
                            Image(systemName: node.kind.symbol).frame(width: 16).foregroundStyle(.secondary)
                            Text(node.name).lineLimit(1).opacity(node.isHidden ? 0.4 : 1)
                            Spacer(minLength: 0)
                            Button { edit { $0.setHidden(node.id, !node.isHidden) } } label: {
                                Image(systemName: node.isHidden ? "eye.slash" : "eye")
                            }.buttonStyle(.borderless).help(node.isHidden ? "Show" : "Hide")
                            Button { edit { $0.setLocked(node.id, !node.isLocked) } } label: {
                                Image(systemName: node.isLocked ? "lock.fill" : "lock.open")
                            }.buttonStyle(.borderless).help(node.isLocked ? "Unlock" : "Lock")
                        }
                        .font(.callout).tag(node.id)
                    }
                    .onMove { source, destination in
                        // The list is reversed (front first); translate back to back-to-front order.
                        edit { document in
                            var front = Array(document.nodes.reversed())
                            guard source.allSatisfy({ !front[$0].isLocked }) else { return }
                            front.move(fromOffsets: source, toOffset: destination)
                            document.nodes = front.reversed()
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: Canvas

    private func toDoc(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / zoom, y: (point.y - offset.height) / zoom)
    }
    private func toScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + offset.width, y: point.y * zoom + offset.height)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let step = 24 * zoom
                guard step > 6 else { return }
                var path = Path()
                var x = offset.width.truncatingRemainder(dividingBy: step)
                while x < size.width { var y = offset.height.truncatingRemainder(dividingBy: step)
                    while y < size.height { path.addEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4)); y += step }
                    x += step }
                context.fill(path, with: .color(.primary.opacity(0.18)))
            }
            DesignScene(nodes: doc.nodes, connections: doc.connections ?? [])
                .scaleEffect(zoom, anchor: .topLeading).offset(offset)
                .allowsHitTesting(false)
            overlays.allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .gesture(MagnifyGesture().onChanged { value in
            let base = magnifyBase ?? zoom
            magnifyBase = base
            changeZoom(base * value.magnification)
        }.onEnded { _ in magnifyBase = nil })
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress { press in handleKey(press) }
        .onTapGesture { focused = true }
        .overlay(alignment: .center) {
            if doc.nodes.isEmpty { Text("Empty canvas").font(.title3).foregroundStyle(.tertiary).allowsHitTesting(false) }
        }
    }

    @ViewBuilder private var overlays: some View {
        ForEach(doc.nodes.filter { selection.contains($0.id) && !$0.isHidden }) { node in
            let origin = toScreen(node.frame.origin)
            Rectangle().stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: node.width * zoom, height: node.height * zoom).offset(x: origin.x, y: origin.y)
        }
        if selection.count == 1, let node = doc.node(selection.first!), !node.isLocked, !node.isHidden {
            ForEach(DesignHandle.allCases, id: \.self) { handle in
                let point = toScreen(handlePoint(handle, of: node.frame))
                Rectangle().fill(.white).overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 8, height: 8).offset(x: point.x - 4, y: point.y - 4)
            }
        }
        if let draftRect {
            let origin = toScreen(draftRect.origin)
            Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4]))
                .frame(width: draftRect.width * zoom, height: draftRect.height * zoom).offset(x: origin.x, y: origin.y)
        }
        if let marquee {
            Rectangle().fill(Color.accentColor.opacity(0.1)).overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .frame(width: marquee.width, height: marquee.height).offset(x: marquee.minX, y: marquee.minY)
        }
    }

    private func handlePoint(_ handle: DesignHandle, of rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handleHit(at screen: CGPoint) -> (UUID, DesignHandle)? {
        guard selection.count == 1, let node = doc.node(selection.first!), !node.isLocked, !node.isHidden else { return nil }
        for handle in DesignHandle.allCases {
            let point = toScreen(handlePoint(handle, of: node.frame))
            if abs(point.x - screen.x) <= 7, abs(point.y - screen.y) <= 7 { return (node.id, handle) }
        }
        return nil
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !ignoreDragUntilEnd else { return }
                focused = true
                let point = toDoc(value.location)
                if drag == nil { begin(value) }
                switch drag {
                case .move(let last):
                    editor.updateInteraction { $0.move(selection, by: CGSize(width: point.x - last.x, height: point.y - last.y)) }
                    drag = .move(last: point)
                case .resize(let id, let handle): editor.updateInteraction { $0.resize(id, handle: handle, to: point) }
                case .create(_, let start): draftRect = rect(start, point)
                case .marquee(let start, let base):
                    let screenRect = rect(toScreen(start), value.location)
                    marquee = screenRect
                    selection = base.union(doc.nodes(in: rect(start, point)))
                case .pan(let start):
                    offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                case nil: break
                }
            }
            .onEnded { value in
                defer { drag = nil; marquee = nil; draftRect = nil; editor.endInteraction() }
                if ignoreDragUntilEnd { ignoreDragUntilEnd = false; return }
                if case .create(let kind, let start) = drag {
                    var area = rect(start, toDoc(value.location))
                    if area.width < 4 && area.height < 4 { area = CGRect(origin: start, size: kind == .text ? CGSize(width: 120, height: 28) : CGSize(width: 100, height: 100)) }
                    editor.updateInteraction { selection = [$0.add(kind, in: area)] }
                    tool = .select
                }
            }
    }

    private func begin(_ value: DragGesture.Value) {
        let point = toDoc(value.startLocation)
        if tool == .hand { automaticallyFits = false; drag = .pan(start: offset); return }
        if let kind = tool.kind { editor.beginInteraction(); drag = .create(kind, start: point); return }
        if let (id, handle) = handleHit(at: value.startLocation) { editor.beginInteraction(); drag = .resize(id, handle); return }
        let extend = NSEvent.modifierFlags.contains(.shift)
        if let hit = doc.hitTest(point) {
            if extend { if selection.contains(hit) { selection.remove(hit) } else { selection.insert(hit) } }
            else if !selection.contains(hit) { selection = [hit] }
            if selection.contains(hit) { editor.beginInteraction(); drag = .move(last: point) } else { drag = .pan(start: offset) }
            return
        }
        drag = .marquee(start: point, base: extend ? selection : [])
        if !extend { selection = [] }
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        if let item = DesignTool.allCases.first(where: { $0.key == press.characters.lowercased().first }) {
            tool = item; return .handled
        }
        let nudge = press.modifiers.contains(.shift) ? 10.0 : 1.0
        switch press.key {
        case .delete, .deleteForward:
            guard !selection.isEmpty else { return .ignored }
            deleteSelection()
        case .leftArrow: nudgeSelection(-nudge, 0)
        case .rightArrow: nudgeSelection(nudge, 0)
        case .upArrow: nudgeSelection(0, -nudge)
        case .downArrow: nudgeSelection(0, nudge)
        case .escape: selection = []; tool = .select
        default: return .ignored
        }
        return .handled
    }

    private func nudgeSelection(_ dx: Double, _ dy: Double) {
        guard !selection.isEmpty else { return }
        edit(coalescing: "nudge:" + selection.map(\.uuidString).sorted().joined()) { $0.move(selection, by: CGSize(width: dx, height: dy)) }
    }

    // MARK: Editing and history

    private func edit(coalescing key: String? = nil, _ change: (inout DesignDocument) -> Void) {
        editor.edit(coalescing: key, change)
    }

    private func undoEdit() { editor.undo() }
    private func redoEdit() { editor.redo() }

    private func deleteSelection() {
        edit { $0.remove(selection) }
        selection = selection.filter { doc.node($0) != nil }
    }

    private func duplicateSelection() {
        edit { selection = Set($0.duplicate(selection)) }
    }

    private func fit() {
        automaticallyFits = true
        guard let box = doc.visibleBounds, box.width > 0, box.height > 0 else { return }
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        zoom = min(4, max(0.0001, min(max(1, canvasSize.width - 64) / box.width, max(1, canvasSize.height - 64) / box.height)))
        offset = CGSize(width: (canvasSize.width - box.width * zoom) / 2 - box.minX * zoom,
                        height: (canvasSize.height - box.height * zoom) / 2 - box.minY * zoom)
    }

    private func changeZoom(_ value: Double) {
        automaticallyFits = false
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let point = toDoc(center)
        zoom = min(8, max(0.0001, value))
        offset = CGSize(width: center.x - point.x * zoom, height: center.y - point.y * zoom)
    }

    @MainActor private func export() {
        do {
            let png = try DesignRenderer.png(document: doc, selection: selection)
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                throw DesignToolError("Open a project window to export.")
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.directoryURL = project.url
            let name = String(project.name.map { "/\\:".contains($0) ? "-" : $0 }.prefix(90))
            panel.nameFieldStringValue = "\(name) design.png"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                Task {
                    do { try await Task.detached { try png.write(to: url, options: .atomic) }.value }
                    catch { exportError = error.localizedDescription }
                }
            }
        } catch { exportError = error.localizedDescription }
    }

    // MARK: Properties

    private var properties: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let id = selection.first, selection.count == 1, let node = doc.node(id) {
                    if node.isLocked {
                        Label("Layer is locked", systemImage: "lock.fill").foregroundStyle(.secondary)
                        Button("Unlock layer") { edit { $0.setLocked(node.id, false) } }
                    }
                    singleProperties(node).disabled(node.isLocked)
                } else if selection.count > 1 {
                    Text("\(selection.count) layers selected").font(.callout.weight(.semibold))
                    alignmentRow
                    arrangeRow
                    Button("Delete", role: .destructive) { deleteSelection() }
                } else {
                    Text("Nothing selected").font(.callout).foregroundStyle(.secondary)
                    Text("Shortcuts: V select, H hand, F frame, R rectangle, O ellipse, T text. Delete removes, arrows nudge, ⇧ extends selection, pinch zooms.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding<T>(_ node: DesignNode, _ path: WritableKeyPath<DesignNode, T>) -> Binding<T> {
        Binding(get: { (doc.node(node.id) ?? node)[keyPath: path] },
                set: { value in edit(coalescing: "property:\(node.id):\(path)") { $0.update([node.id]) { $0[keyPath: path] = value } } })
    }

    private func singleProperties(_ node: DesignNode) -> some View {
        let id = node.id
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: binding(node, \.name)).textFieldStyle(.roundedBorder).font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow { number("X", binding(node, \.x)); number("Y", binding(node, \.y)) }
                GridRow { number("W", binding(node, \.width)); number("H", binding(node, \.height)) }
            }
            TextField("Text", text: binding(node, \.text), axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
            number("Size", binding(node, \.fontSize))
            if node.kind == .rectangle || node.kind == .frame {
                number("Radius", binding(node, \.cornerRadius))
            }
            ColorPicker(node.kind == .text ? "Color" : "Fill", selection: Binding(
                get: { node.fill.color }, set: { value in edit(coalescing: "color:\(id)") { $0.update([id]) { $0.fill = DesignColor(value) } } }))
            if node.kind != .text {
                Toggle("Stroke", isOn: Binding(
                    get: { node.stroke != nil },
                    set: { on in edit { $0.update([id]) { $0.stroke = on ? .black : nil } } }))
                if let stroke = node.stroke {
                    HStack {
                        ColorPicker("", selection: Binding(
                            get: { stroke.color }, set: { value in edit(coalescing: "color:\(id)") { $0.update([id]) { $0.stroke = DesignColor(value) } } }))
                            .labelsHidden()
                        number("Width", binding(node, \.strokeWidth))
                    }
                }
            }
            HStack {
                Text("Opacity").font(.caption).foregroundStyle(.secondary)
                Slider(value: binding(node, \.opacity), in: 0...1)
            }
            arrangeRow
            Button("Delete", role: .destructive) { deleteSelection() }
        }
    }

    private func number(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: label.count > 2 ? 44 : 16, alignment: .leading)
            TextField("", value: Binding(get: { value.wrappedValue.rounded() }, set: { value.wrappedValue = $0 }), format: .number)
                .textFieldStyle(.roundedBorder).frame(minWidth: 50)
                .accessibilityLabel(["X": "X position", "Y": "Y position", "W": "Width", "H": "Height", "Size": "Font size" ][label] ?? label)
        }
    }

    private var arrangeRow: some View {
        HStack {
            Button { edit { $0.reorder(selection, toFront: true) } } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                .help("Bring to front")
            Button { edit { $0.reorder(selection, toFront: false) } } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                .help("Send to back")
        }.buttonStyle(.bordered)
    }

    private var alignmentRow: some View {
        HStack {
            ForEach([("align.horizontal.left", DesignDocument.Alignment.left, "Align left"),
                     ("align.horizontal.center", .centerX, "Align horizontal centers"),
                     ("align.horizontal.right", .right, "Align right"),
                     ("align.vertical.top", .top, "Align top"),
                     ("align.vertical.center", .centerY, "Align vertical centers"),
                     ("align.vertical.bottom", .bottom, "Align bottom")], id: \.2) { symbol, alignment, help in
                Button { edit { $0.align(selection, alignment) } } label: { Image(systemName: symbol) }.help(help)
            }
        }.buttonStyle(.bordered).controlSize(.small)
    }
}
