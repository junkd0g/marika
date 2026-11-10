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
            Ellipse().fill(node.fill.color).overlay(stroke(Ellipse()))
        case .rectangle, .frame:
            RoundedRectangle(cornerRadius: node.cornerRadius).fill(node.fill.color)
                .overlay(stroke(RoundedRectangle(cornerRadius: node.cornerRadius)))
        }
    }

    @ViewBuilder private func stroke<S: InsettableShape>(_ shape: S) -> some View {
        if let color = node.stroke { shape.strokeBorder(color.color, lineWidth: node.strokeWidth) }
    }
}

private struct DesignScene: View {
    let nodes: [DesignNode]
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(nodes.filter { !$0.isHidden }) { DesignNodeView(node: $0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ProjectDesignView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var doc = DesignDocument()
    @State private var loaded = false
    @State private var undo: [DesignDocument] = []
    @State private var redo: [DesignDocument] = []
    @State private var lastCheckpoint = Date.distantPast
    @State private var tool = DesignTool.select
    @State private var selection: Set<UUID> = []
    @State private var zoom = 1.0
    @State private var offset = CGSize(width: 240, height: 120)
    @State private var drag: Drag?
    @State private var marquee: CGRect?
    @State private var draftRect: CGRect?
    @State private var magnifyBase: Double?
    @FocusState private var focused: Bool

    private enum Drag {
        case move(last: CGPoint), resize(UUID, DesignHandle), create(DesignNode.Kind, start: CGPoint)
        case marquee(start: CGPoint, base: Set<UUID>), pan(start: CGSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                layers.frame(width: 210)
                Divider()
                canvas
                Divider()
                properties.frame(width: 250)
            }
        }
        .background(Theme.canvas)
        .onAppear { if !loaded { doc = project.design ?? DesignDocument(); loaded = true } }
        .onChange(of: doc) { _, new in if loaded { model.updateProject(project.id) { $0.design = new } } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(DesignTool.allCases, id: \.self) { item in
                Button { tool = item } label: {
                    Image(systemName: item.symbol).frame(width: 26, height: 22)
                        .background(tool == item ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain).help("\(item.rawValue) (\(String(item.key).uppercased()))")
            }
            Divider().frame(height: 18)
            Button { undoEdit() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(undo.isEmpty).help("Undo")
            Button { redoEdit() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(redo.isEmpty).help("Redo")
            Button { duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                .disabled(selection.isEmpty).help("Duplicate")
            Spacer()
            Button { zoom = max(0.1, zoom / 1.25) } label: { Image(systemName: "minus") }
            Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 44)
            Button { zoom = min(8, zoom * 1.25) } label: { Image(systemName: "plus") }
            Button("Fit") { fit() }.disabled(doc.nodes.isEmpty)
            Button { export() } label: { Label("Export PNG", systemImage: "square.and.arrow.up") }
                .disabled(doc.nodes.isEmpty)
        }
        .buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: Layers

    private var layers: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Layers").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(10)
            if doc.nodes.isEmpty {
                Text("Pick a shape tool and drag on the canvas to draw.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                Spacer()
            } else {
                List(selection: $selection) {
                    ForEach(doc.nodes.reversed()) { node in
                        HStack(spacing: 6) {
                            Image(systemName: node.kind.symbol).frame(width: 16).foregroundStyle(.secondary)
                            Text(node.name).lineLimit(1).opacity(node.isHidden ? 0.4 : 1)
                            Spacer(minLength: 0)
                            Button { edit { $0.update([node.id]) { $0.isHidden.toggle() } } } label: {
                                Image(systemName: node.isHidden ? "eye.slash" : "eye")
                            }.buttonStyle(.borderless).help(node.isHidden ? "Show" : "Hide")
                            Button { edit { $0.update([node.id]) { $0.isLocked.toggle() } } } label: {
                                Image(systemName: node.isLocked ? "lock.fill" : "lock.open")
                            }.buttonStyle(.borderless).help(node.isLocked ? "Unlock" : "Lock")
                        }
                        .font(.callout).tag(node.id)
                    }
                    .onMove { source, destination in
                        // The list is reversed (front first); translate back to back-to-front order.
                        edit { document in
                            var front = Array(document.nodes.reversed())
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
            DesignScene(nodes: doc.nodes)
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
            zoom = min(8, max(0.1, base * value.magnification))
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
        if selection.count == 1, let node = doc.node(selection.first!), !node.isLocked {
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
        guard selection.count == 1, let node = doc.node(selection.first!), !node.isLocked else { return nil }
        for handle in DesignHandle.allCases {
            let point = toScreen(handlePoint(handle, of: node.frame))
            if abs(point.x - screen.x) <= 7, abs(point.y - screen.y) <= 7 { return (node.id, handle) }
        }
        return nil
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                focused = true
                let point = toDoc(value.location)
                if drag == nil { begin(value) }
                switch drag {
                case .move(let last):
                    doc.move(selection, by: CGSize(width: point.x - last.x, height: point.y - last.y))
                    drag = .move(last: point)
                case .resize(let id, let handle): doc.resize(id, handle: handle, to: point)
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
                defer { drag = nil; marquee = nil; draftRect = nil }
                if case .create(let kind, let start) = drag {
                    var area = rect(start, toDoc(value.location))
                    if area.width < 4 && area.height < 4 { area = CGRect(origin: start, size: kind == .text ? CGSize(width: 120, height: 28) : CGSize(width: 100, height: 100)) }
                    let id = doc.add(kind, in: area)
                    selection = [id]
                    tool = .select
                }
            }
    }

    private func begin(_ value: DragGesture.Value) {
        let point = toDoc(value.startLocation)
        if tool == .hand { drag = .pan(start: offset); return }
        if let kind = tool.kind { checkpoint(); drag = .create(kind, start: point); return }
        if let (id, handle) = handleHit(at: value.startLocation) { checkpoint(); drag = .resize(id, handle); return }
        let extend = NSEvent.modifierFlags.contains(.shift)
        if let hit = doc.hitTest(point) {
            if extend { if selection.contains(hit) { selection.remove(hit) } else { selection.insert(hit) } }
            else if !selection.contains(hit) { selection = [hit] }
            if selection.contains(hit) { checkpoint(); drag = .move(last: point) } else { drag = .pan(start: offset) }
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
            edit { $0.remove(selection) }; selection = []
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
        edit(coalesce: true) { $0.move(selection, by: CGSize(width: dx, height: dy)) }
    }

    // MARK: Editing and history

    private func checkpoint() {
        undo.append(doc); if undo.count > 100 { undo.removeFirst() }
        redo = []; lastCheckpoint = Date()
    }

    /// Apply a change as one undo step. `coalesce` merges rapid changes, such as typing or nudging.
    private func edit(coalesce: Bool = false, _ change: (inout DesignDocument) -> Void) {
        if !(coalesce && Date().timeIntervalSince(lastCheckpoint) < 1) { checkpoint() } else { lastCheckpoint = Date() }
        change(&doc)
    }

    private func undoEdit() {
        guard let previous = undo.popLast() else { return }
        redo.append(doc); doc = previous; selection = selection.filter { doc.node($0) != nil }
    }
    private func redoEdit() {
        guard let next = redo.popLast() else { return }
        undo.append(doc); doc = next; selection = selection.filter { doc.node($0) != nil }
    }

    private func duplicateSelection() {
        edit { selection = Set($0.duplicate(selection)) }
    }

    private func fit() {
        guard let box = doc.bounds(of: Set(doc.nodes.map(\.id))), box.width > 0, box.height > 0 else { return }
        let view = CGSize(width: 700, height: 500)
        zoom = min(4, max(0.1, min(view.width / box.width, view.height / box.height) * 0.9))
        offset = CGSize(width: 40 - box.minX * zoom + (view.width - box.width * zoom) / 2 - 40,
                        height: 40 - box.minY * zoom + (view.height - box.height * zoom) / 2 - 40)
    }

    @MainActor private func export() {
        let ids = selection.isEmpty ? Set(doc.nodes.map(\.id)) : selection
        guard let box = doc.bounds(of: ids)?.insetBy(dx: -16, dy: -16) else { return }
        let scene = DesignScene(nodes: doc.nodes).offset(x: -box.minX, y: -box.minY)
            .frame(width: box.width, height: box.height, alignment: .topLeading).clipped()
            .background(Color.white)
        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(project.name) design.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }

    // MARK: Properties

    private var properties: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let id = selection.first, selection.count == 1, let node = doc.node(id) {
                    singleProperties(node)
                } else if selection.count > 1 {
                    Text("\(selection.count) layers selected").font(.callout.weight(.semibold))
                    alignmentRow
                    arrangeRow
                    Button("Delete", role: .destructive) { edit { $0.remove(selection) }; selection = [] }
                } else {
                    Text("Nothing selected").font(.callout).foregroundStyle(.secondary)
                    Text("Shortcuts: V select, H hand, F frame, R rectangle, O ellipse, T text. Delete removes, arrows nudge, ⇧ extends selection, pinch zooms.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding<T>(_ id: UUID, _ path: WritableKeyPath<DesignNode, T>, coalesce: Bool = true) -> Binding<T> {
        Binding(get: { doc.node(id)![keyPath: path] },
                set: { value in edit(coalesce: coalesce) { $0.update([id]) { $0[keyPath: path] = value } } })
    }

    private func singleProperties(_ node: DesignNode) -> some View {
        let id = node.id
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: binding(id, \.name)).textFieldStyle(.roundedBorder).font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow { number("X", binding(id, \.x)); number("Y", binding(id, \.y)) }
                GridRow { number("W", binding(id, \.width, coalesce: true)); number("H", binding(id, \.height)) }
            }
            if node.kind == .text {
                TextField("Text", text: binding(id, \.text), axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
                number("Size", binding(id, \.fontSize))
            }
            if node.kind == .rectangle || node.kind == .frame {
                number("Radius", binding(id, \.cornerRadius))
            }
            ColorPicker(node.kind == .text ? "Color" : "Fill", selection: Binding(
                get: { node.fill.color }, set: { value in edit(coalesce: true) { $0.update([id]) { $0.fill = DesignColor(value) } } }))
            if node.kind != .text {
                Toggle("Stroke", isOn: Binding(
                    get: { node.stroke != nil },
                    set: { on in edit { $0.update([id]) { $0.stroke = on ? .black : nil } } }))
                if let stroke = node.stroke {
                    HStack {
                        ColorPicker("", selection: Binding(
                            get: { stroke.color }, set: { value in edit(coalesce: true) { $0.update([id]) { $0.stroke = DesignColor(value) } } }))
                            .labelsHidden()
                        number("Width", binding(id, \.strokeWidth))
                    }
                }
            }
            HStack {
                Text("Opacity").font(.caption).foregroundStyle(.secondary)
                Slider(value: binding(id, \.opacity), in: 0...1)
            }
            arrangeRow
            Button("Delete", role: .destructive) { edit { $0.remove([id]) }; selection = [] }
        }
    }

    private func number(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: label.count > 2 ? 44 : 16, alignment: .leading)
            TextField("", value: Binding(get: { value.wrappedValue.rounded() }, set: { value.wrappedValue = $0 }), format: .number)
                .textFieldStyle(.roundedBorder).frame(minWidth: 50)
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
