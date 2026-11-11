import AppKit
import MarikaCore
import SwiftUI

/// The drawing surface: artwork, selection chrome, native pointer and keyboard input, and inline text editing.
struct DesignCanvasView: View {
    let canvas: DesignCanvasModel

    var body: some View {
        let doc = canvas.doc, zoom = canvas.zoom, offset = canvas.offset
        ZStack(alignment: .topLeading) {
            DesignGrid(zoom: zoom, offset: offset)
            DesignScene(nodes: doc.nodes, connections: doc.connections ?? [], editing: canvas.editingText,
                        zoom: zoom, offset: offset)
                .allowsHitTesting(false)
            DesignChrome(canvas: canvas).allowsHitTesting(false)
            DesignEventSurface(canvas: canvas, focusRequests: canvas.focusRequests)
            if let id = canvas.editingText, let node = doc.node(id) {
                DesignTextEditor(canvas: canvas, node: node).id(id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.designCanvas)
        .clipped()
        .dropDestination(for: String.self) { values, point in
            canvas.acceptComponentDrop(values, at: point)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvas.resize(to: $0) }
        .overlay {
            if doc.nodes.isEmpty {
                VStack(spacing: 6) {
                    Text("Empty canvas").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                    Text("Pick a tool below and drag to draw, or ask your project chat to design it here.")
                        .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 320).allowsHitTesting(false)
            }
        }
    }
}

private struct DesignGrid: View {
    let zoom: Double
    let offset: CGSize

    var body: some View {
        Canvas { context, size in
            let step = 24 * zoom
            guard step > 8 else { return }
            var path = Path()
            var x = offset.width.truncatingRemainder(dividingBy: step)
            while x < size.width {
                var y = offset.height.truncatingRemainder(dividingBy: step)
                while y < size.height { path.addEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4)); y += step }
                x += step
            }
            context.fill(path, with: .color(.primary.opacity(0.13)))
        }
    }
}

/// Selection outlines, handles, guides and previews, drawn in screen space above the artwork.
private struct DesignChrome: View {
    let canvas: DesignCanvasModel
    private static let guide = Color(red: 1, green: 0.24, blue: 0.42)

    var body: some View {
        // Read everything here: the drawing closure runs outside observation tracking.
        let doc = canvas.doc, selection = canvas.selection, hovered = canvas.hovered, tool = canvas.tool
        let labels = canvas.frameLabels, sole = canvas.soleNode, box = canvas.groupBox, knob = canvas.rotationKnob
        let guides = canvas.guides, marquee = canvas.marquee, draft = canvas.draft
        let edge = canvas.activeConnection, editing = canvas.editingText != nil
        let zoom = canvas.zoom, offset = canvas.offset
        let badges = canvas.implementationBadges
        Canvas { context, _ in
            func screen(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * zoom + offset.width, y: point.y * zoom + offset.height) }
            func area(_ rect: CGRect) -> CGRect { CGRect(origin: screen(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom)) }
            func outline(_ node: DesignNode) -> Path {
                var path = Path()
                if node.isLinear {
                    path.move(to: screen(node.endpoints.start)); path.addLine(to: screen(node.endpoints.end))
                } else {
                    path.addLines(node.corners.map(screen)); path.closeSubpath()
                }
                return path
            }
            func knobs(_ points: [CGPoint], round: Bool = false) {
                for point in points {
                    let spot = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                    let path = round ? Path(ellipseIn: spot) : Path(spot)
                    context.fill(path, with: .color(.white))
                    context.stroke(path, with: .color(Theme.action), lineWidth: 1.5)
                }
            }
            func badge(_ text: String, below rect: CGRect) {
                let resolved = context.resolve(Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white))
                let size = resolved.measure(in: CGSize(width: 400, height: 40))
                let pill = CGRect(x: rect.midX - size.width / 2 - 6, y: rect.maxY + 8, width: size.width + 12, height: size.height + 4)
                context.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color(Theme.action))
                context.draw(resolved, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
            }
            func measure(_ value: Double) -> String { String(Int(value.rounded())) }

            for label in labels {
                var layer = context
                layer.clip(to: Path(label.rect))
                let active = selection.contains(label.id) || hovered == label.id
                layer.draw(Text(label.name).font(.system(size: 11)).foregroundStyle(active ? Theme.action : Color.secondary),
                           at: label.rect.origin, anchor: .topLeading)
            }
            if let edge, let route = edge.route(in: doc.nodes) {
                let path = DesignConnectionPath.path(route).applying(CGAffineTransform(scaleX: zoom, y: zoom)
                    .concatenating(CGAffineTransform(translationX: offset.width, y: offset.height)))
                context.stroke(path, with: .color(Theme.action), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if !edge.label.isEmpty {
                    // Repaint the label over the highlight so it stays readable.
                    let text = context.resolve(Text(edge.label).font(.system(size: 11 * zoom)).foregroundStyle(.white))
                    let size = text.measure(in: CGSize(width: 2_000, height: 200))
                    let middle = screen(DesignConnection.point(on: route, fraction: edge.labelFraction))
                    let pill = CGRect(x: middle.x - size.width / 2 - 5 * zoom, y: middle.y - size.height / 2 - 3 * zoom,
                                      width: size.width + 10 * zoom, height: size.height + 6 * zoom)
                    context.fill(Path(roundedRect: pill, cornerRadius: 4 * zoom), with: .color(Theme.action))
                    context.draw(text, at: middle, anchor: .center)
                }
            }
            for badge in badges {
                let color: Color = badge.status == .done ? .green : badge.status == .inProgress ? .blue : badge.status == .todo ? .orange : .secondary
                if badge.label.isEmpty {
                    context.fill(Path(ellipseIn: badge.rect), with: .color(color))
                    context.stroke(Path(ellipseIn: badge.rect), with: .color(Theme.panel), lineWidth: 2)
                } else {
                    context.fill(Path(roundedRect: badge.rect, cornerRadius: 5), with: .color(Theme.panel))
                    context.stroke(Path(roundedRect: badge.rect, cornerRadius: 5), with: .color(color.opacity(0.5)), lineWidth: 1)
                    context.draw(Text(badge.label).font(.system(size: 9, weight: .medium)).foregroundStyle(color),
                                 at: CGPoint(x: badge.rect.midX, y: badge.rect.midY))
                }
            }
            if let hovered, !selection.contains(hovered), let node = doc.node(hovered) {
                context.stroke(outline(node), with: .color(Theme.action), lineWidth: 2)
            }
            for node in doc.nodes where selection.contains(node.id) && !node.isHidden {
                context.stroke(outline(node), with: .color(Theme.action.opacity(node.isLocked ? 0.5 : 1)), lineWidth: selection.count == 1 ? 1.5 : 1)
            }
            if let sole, !editing, tool == .select {
                if sole.isLinear {
                    knobs([sole.endpoints.start, sole.endpoints.end].map(screen), round: true)
                } else {
                    if let knob {
                        let top = screen(sole.toWorld(CGPoint(x: sole.frame.midX, y: sole.frame.minY)))
                        var stem = Path()
                        stem.move(to: top); stem.addLine(to: knob)
                        context.stroke(stem, with: .color(Theme.action), lineWidth: 1)
                        knobs([knob], round: true)
                    }
                    knobs(sole.corners.map(screen))
                    if sole.rotation == nil { badge("\(measure(sole.width)) × \(measure(sole.height))", below: area(sole.frame)) }
                }
            } else if let box, tool == .select {
                let rect = area(box)
                context.stroke(Path(rect), with: .color(Theme.action), lineWidth: 1.5)
                knobs([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
                badge("\(measure(box.width)) × \(measure(box.height))", below: rect)
            }
            for guide in guides {
                var path = Path()
                if guide.axis == .vertical {
                    path.move(to: screen(CGPoint(x: guide.position, y: guide.start))); path.addLine(to: screen(CGPoint(x: guide.position, y: guide.end)))
                } else {
                    path.move(to: screen(CGPoint(x: guide.start, y: guide.position))); path.addLine(to: screen(CGPoint(x: guide.end, y: guide.position)))
                }
                context.stroke(path, with: .color(Self.guide), lineWidth: 1)
            }
            if let marquee {
                let rect = area(marquee)
                context.fill(Path(rect), with: .color(Theme.action.opacity(0.1)))
                context.stroke(Path(rect), with: .color(Theme.action), lineWidth: 1)
            }
            switch draft {
            case .shape(let kind, let shape):
                let rect = area(shape)
                let path: Path = switch kind {
                case .ellipse: Path(ellipseIn: rect)
                case .polygon, .star: DesignPolygon(kind: kind, sides: nil).path(in: rect)
                default: Path(rect)
                }
                if kind != .text { context.fill(path, with: .color(Theme.action.opacity(0.14))) }
                context.stroke(path, with: .color(Theme.action), lineWidth: 1)
                badge("\(measure(shape.width)) × \(measure(shape.height))", below: rect)
            case .line(_, let start, let end):
                var path = Path()
                path.move(to: screen(start)); path.addLine(to: screen(end))
                context.stroke(path, with: .color(Theme.action), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            case .connector(let source, let end, let target):
                guard let from = doc.node(source) else { break }
                let goal = target.flatMap { doc.node($0) }
                var path = Path()
                path.move(to: screen(CGPoint(x: from.bounds.midX, y: from.bounds.midY)))
                path.addLine(to: screen(goal.map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) } ?? end))
                context.stroke(path, with: .color(Theme.action), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                context.stroke(outline(from), with: .color(Theme.action), lineWidth: 2)
                if let goal { context.stroke(outline(goal), with: .color(Theme.action), lineWidth: 2) }
            case nil: break
            }
        }
    }
}

/// An in-place field over the layer whose text is being edited. Return or Escape finishes; ⌥Return adds a line.
private struct DesignTextEditor: View {
    let canvas: DesignCanvasModel
    let node: DesignNode
    @FocusState private var focused: Bool

    var body: some View {
        let zoom = canvas.zoom, isText = node.kind == .text
        TextField("", text: Binding(get: { canvas.doc.node(node.id)?.text ?? "" }, set: { canvas.updateText($0) }), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: node.fontSize * zoom, weight: node.resolvedWeight.font))
            .foregroundStyle(node.textColor)
            .tint(node.textColor)
            .multilineTextAlignment(node.resolvedAlign.text)
            .padding(.leading, isText ? 0 : (node.component == nil ? 12 : 50) * zoom)
            .padding(.trailing, isText ? 0 : 12 * zoom)
            .padding(.vertical, isText ? 0 : 12 * zoom)
            .frame(width: max(24, node.width * zoom), height: max(16, node.height * zoom),
                   alignment: Alignment(horizontal: node.resolvedAlign.horizontal, vertical: isText ? .top : .center))
            .rotationEffect(.degrees(node.rotation ?? 0))
            .position(canvas.toScreen(node.center))
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onSubmit { canvas.commitText() }
            .onExitCommand { canvas.commitText() }
            .onChange(of: focused) { was, now in if was, !now { canvas.commitText() } }
            .accessibilityLabel("Layer text")
    }
}

/// Native input for the canvas: SwiftUI gestures cannot see scroll wheels, modifier keys or secondary clicks.
private struct DesignEventSurface: NSViewRepresentable {
    let canvas: DesignCanvasModel
    let focusRequests: Int

    func makeNSView(context: Context) -> DesignEventView { DesignEventView(canvas: canvas) }
    func updateNSView(_ view: DesignEventView, context: Context) {
        view.canvas = canvas
        guard view.focusRequests != focusRequests else { return }
        view.focusRequests = focusRequests
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

final class DesignEventView: NSView {
    var canvas: DesignCanvasModel
    var focusRequests = 0
    private var tracking: NSTrackingArea?

    init(canvas: DesignCanvasModel) {
        self.canvas = canvas
        focusRequests = canvas.focusRequests
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("design-canvas")
        setAccessibilityLabel("Design canvas")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Like other drawing tools, the click that brings the window forward also selects what it lands on.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func pointer(_ event: NSEvent) -> DesignPointer {
        DesignPointer(location: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags, clicks: event.clickCount)
    }
    private func refreshCursor(_ event: NSEvent) { canvas.cursor(at: convert(event.locationInWindow, from: nil)).set() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        canvas.pointerDown(pointer(event))
        refreshCursor(event)
    }
    override func mouseDragged(with event: NSEvent) { canvas.pointerDragged(pointer(event)) }
    override func mouseUp(with event: NSEvent) {
        canvas.pointerUp(pointer(event))
        refreshCursor(event)
    }

    // A middle button pans from any tool.
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        canvas.pointerDown(pointer(event), panning: true)
        refreshCursor(event)
    }
    override func otherMouseDragged(with event: NSEvent) { canvas.pointerDragged(pointer(event)) }
    override func otherMouseUp(with event: NSEvent) {
        canvas.pointerUp(pointer(event))
        refreshCursor(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return canvas.contextMenu(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        // Wheel mice report lines; trackpads report points.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        canvas.scroll(dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale,
                      at: convert(event.locationInWindow, from: nil),
                      zooming: !event.modifierFlags.intersection([.command, .control]).isEmpty)
    }
    override func magnify(with event: NSEvent) {
        canvas.setZoom(canvas.zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseMoved(with event: NSEvent) { canvas.pointerMoved(pointer(event)).set() }
    override func mouseExited(with event: NSEvent) {
        if canvas.hovered != nil, !canvas.isDragging { canvas.hovered = nil }
        NSCursor.arrow.set()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let characters = event.charactersIgnoringModifiers ?? ""
        guard event.modifierFlags.contains(.command) else {
            return canvas.handleKey(characters, keyCode: event.keyCode, modifiers: event.modifierFlags)
        }
        return canvas.handleCommand(characters, modifiers: event.modifierFlags)
    }
    override func keyDown(with event: NSEvent) {
        guard handle(event) else { return super.keyDown(with: event) }
        refreshCursor(event)
    }
    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49 else { return super.keyUp(with: event) }
        canvas.spaceDown = false
        refreshCursor(event)
    }
    // The menu bar also binds ⌘D, ⌘[, ⌘] and Escape for the browser and editor. A focused canvas answers first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown, handle(event) else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
    override func resignFirstResponder() -> Bool {
        canvas.spaceDown = false
        return super.resignFirstResponder()
    }
}

/// A menu item that runs a closure, for menus assembled from the current selection.
private final class DesignMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

extension DesignCanvasModel {
    /// Selects what was clicked, as a secondary click does elsewhere on the Mac, and lists what can be done with it.
    func contextMenu(at location: CGPoint) -> NSMenu {
        if editingText != nil { commitText() }
        if let hit = nodeHit(at: location) {
            if !selection.contains(hit) { selection = [hit] }
            selectedConnection = nil
        } else {
            selection = []
            selectedConnection = doc.connection(at: toDoc(location), tolerance: 5 / zoom)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true, _ handler: @escaping () -> Void) {
            menu.addItem(DesignMenuItem(title, key: key, modifiers: modifiers, enabled: enabled, handler: handler))
        }
        if let edge = activeConnection {
            add("Reverse Direction") { [self] in edit { $0.updateConnection(edge.id) { ($0.from, $0.to) = ($0.to, $0.from) } } }
            add("Delete Connection", key: "\u{8}", modifiers: []) { [self] in deleteSelection() }
            return menu
        }
        let nodes = selectedNodes, editable = !editableSelection.isEmpty
        if !nodes.isEmpty {
            add("Copy", key: "c") { [self] in copySelection() }
            add("Cut", key: "x", enabled: editable) { [self] in if copySelection() { deleteSelection() } }
            add("Duplicate", key: "d", enabled: editable) { [self] in duplicateSelection() }
            add("Delete", key: "\u{8}", modifiers: [], enabled: editable) { [self] in deleteSelection() }
            menu.addItem(.separator())
        }
        add("Paste Here", key: "v", enabled: canPaste) { [self] in paste(at: location) }
        guard !nodes.isEmpty else {
            add("Select All", key: "a", enabled: !doc.nodes.isEmpty) { [self] in selectAll() }
            menu.addItem(.separator())
            add("Zoom to Fit", key: "1", modifiers: .shift, enabled: doc.visibleBounds != nil) { [self] in fit() }
            add("Zoom to 100%", key: "0", modifiers: .shift) { [self] in setZoom(1) }
            return menu
        }
        menu.addItem(.separator())
        add("Bring to Front", key: "]", modifiers: [], enabled: editable) { [self] in reorder(toFront: true) }
        add("Bring Forward", key: "]", enabled: editable) { [self] in step(forward: true) }
        add("Send Backward", key: "[", enabled: editable) { [self] in step(forward: false) }
        add("Send to Back", key: "[", modifiers: [], enabled: editable) { [self] in reorder(toFront: false) }
        menu.addItem(.separator())
        add("Frame Selection", key: "g", modifiers: [.command, .option], enabled: editable) { [self] in frameSelection() }
        if nodes.contains(where: { $0.kind == .frame && !$0.isLocked }) {
            add("Ungroup", key: "g", modifiers: [.command, .shift]) { [self] in ungroup() }
        }
        if let node = soleNode, !node.isLinear {
            add("Edit Text", key: "\r", modifiers: []) { [self] in beginEditing(node.id) }
        }
        menu.addItem(.separator())
        let locked = nodes.allSatisfy(\.isLocked), hidden = nodes.allSatisfy(\.isHidden)
        add(locked ? "Unlock" : "Lock") { [self] in setLocked(!locked) }
        add(hidden ? "Show" : "Hide") { [self] in setHidden(!hidden) }
        menu.addItem(.separator())
        add("Use in Chat", enabled: !preparingReference) { [self] in useInChat() }
        add("Copy as PNG", key: "c", modifiers: [.command, .shift]) { [self] in copyImage() }
        return menu
    }
}
