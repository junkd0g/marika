import AppKit
import MarikaCore

/// Editing and clipboard commands shared by menus, shortcuts and inspectors.
extension DesignCanvasModel {
    func choose(_ shape: DesignTool) {
        tool = shape
        if DesignTool.shapes.contains(shape) { lastShape = shape }
    }

    func insertComponent(_ component: DesignComponent, at location: CGPoint? = nil) {
        if editingText != nil { commitText() }
        var center = location.map(toDoc) ?? toDoc(CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        if location == nil {
            // Keep successive insertions separate without moving the user's existing artwork.
            for _ in 0..<24 {
                let box = component.makeNode(centeredAt: center).frame.insetBy(dx: -12, dy: -12)
                if !doc.nodes.contains(where: { !$0.isHidden && $0.kind != .frame && $0.bounds.intersects(box) }) { break }
                center.x += 32; center.y += 24
            }
        }
        var id: UUID?
        edit { id = $0.addComponent(component, centeredAt: center) }
        selection = Set(id.map { [$0] } ?? [])
        selectedConnection = nil
        tool = .select
        if location == nil, let id, let node = doc.node(id),
           !CGRect(origin: .zero, size: canvasSize).contains(toScreen(node.frame)) { fitSelection() }
        focusRequests += 1
    }

    @discardableResult
    func acceptComponentDrop(_ values: [String], at point: CGPoint) -> Bool {
        let components = values.compactMap { value -> DesignComponent? in
            guard value.hasPrefix(DesignComponentLibrary.dragPrefix) else { return nil }
            return DesignComponent(rawValue: String(value.dropFirst(DesignComponentLibrary.dragPrefix.count)))
        }
        for (index, component) in components.enumerated() {
            insertComponent(component, at: CGPoint(x: point.x + Double(index) * 24, y: point.y + Double(index) * 24))
        }
        return !components.isEmpty
    }

    // MARK: Editing

    func edit(coalescing key: String? = nil, _ change: (inout DesignDocument) -> Void) {
        editor.edit(coalescing: key, change)
    }

    /// Applies an inspector change to every selected layer as one undo step per property.
    func update(_ key: String, _ change: (inout DesignNode) -> Void) {
        let ids = selection
        edit(coalescing: "property:\(key):\(ids.hashValue)") { $0.update(ids, change) }
    }

    func deleteSelection() {
        if let edge = activeConnection {
            edit { $0.removeConnection(edge.id) }
            selectedConnection = nil
            return
        }
        let ids = doc.carried(by: selection)
        guard !ids.isEmpty else { return }
        edit { $0.remove(ids) }
        prune()
    }

    func duplicateSelection() {
        let ids = doc.carried(by: selection)
        guard !ids.isEmpty else { return }
        let sources = doc.nodes.filter { ids.contains($0.id) }.map(\.id)
        var copies: [UUID] = []
        edit { copies = $0.duplicate(ids) }
        selection = Set(zip(sources, copies).filter { selection.contains($0.0) }.map(\.1))
    }

    func selectAll() {
        selectedConnection = nil
        selection = Set(doc.nodes.filter { !$0.isLocked && !$0.isHidden }.map(\.id))
    }

    func nudge(_ dx: Double, _ dy: Double) {
        let ids = doc.carried(by: selection)
        guard !ids.isEmpty else { return }
        edit(coalescing: "nudge:\(ids.hashValue)") { $0.move(ids, by: CGSize(width: dx, height: dy)) }
    }

    func reorder(toFront: Bool) {
        let ids = editableSelection
        guard !ids.isEmpty else { return }
        edit { $0.reorder(ids, toFront: toFront) }
    }

    func step(forward: Bool) {
        // Start from the end being moved toward so selected neighbors do not leapfrog each other.
        let ordered = doc.nodes.filter { editableSelection.contains($0.id) }.map(\.id)
        guard !ordered.isEmpty else { return }
        edit { doc in for id in forward ? ordered.reversed() : ordered { doc.step(id, forward: forward) } }
    }

    func frameSelection() {
        let ids = editableSelection
        guard !ids.isEmpty else { return }
        var frame: UUID?
        edit { frame = $0.wrapInFrame(ids) }
        if let frame { selection = [frame] }
    }

    /// Removes selected frames and keeps what they held.
    func ungroup() {
        let frames = Set(selectedNodes.filter { $0.kind == .frame && !$0.isLocked }.map(\.id))
        guard !frames.isEmpty else { return }
        let held = frames.reduce(into: Set<UUID>()) { $0.formUnion(doc.children(of: $1)) }.subtracting(frames)
        edit { $0.remove(frames) }
        selection = held
    }

    func setLocked(_ locked: Bool) {
        let ids = selection
        edit { doc in for id in ids { doc.setLocked(id, locked) } }
    }

    func setHidden(_ hidden: Bool) {
        let ids = selection
        edit { doc in for id in ids { doc.setHidden(id, hidden) } }
    }

    /// One layer aligns inside the frame that holds it; several align to each other.
    func align(_ alignment: DesignDocument.Alignment) {
        let ids = editableSelection
        let container = ids.count == 1 ? doc.parents[ids.first!].flatMap { doc.node($0)?.bounds } : nil
        edit { $0.align(ids, alignment, within: container) }
    }

    var canAlign: Bool {
        editableSelection.count > 1 || (editableSelection.count == 1 && doc.parents[editableSelection.first!] != nil)
    }

    func distribute(_ axis: DesignDocument.Axis) {
        let ids = editableSelection
        edit { $0.distribute(ids, axis) }
    }

    // MARK: Clipboard

    @discardableResult
    func copySelection() -> Bool {
        let clip = doc.clip(doc.carried(by: selection))
        guard !clip.nodes.isEmpty, let data = try? JSONEncoder().encode(clip) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: Self.pasteboardType)
        let text = clip.nodes.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        if !text.isEmpty { board.setString(text, forType: .string) }
        return true
    }

    var canPaste: Bool {
        NSPasteboard.general.availableType(from: [Self.pasteboardType, .string]) != nil
    }

    /// Pastes copied layers beside their originals while those are in view, or at `location`.
    func paste(at location: CGPoint? = nil) {
        let board = NSPasteboard.general
        let middle = toDoc(CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        if let data = board.data(forType: Self.pasteboardType), let clip = try? JSONDecoder().decode(DesignClip.self, from: data),
           !clip.nodes.isEmpty, clip.nodes.count <= 2_000 {
            var center = location.map(toDoc)
            let visible = CGRect(origin: toDoc(.zero), size: CGSize(width: canvasSize.width / zoom, height: canvasSize.height / zoom))
            if center == nil, !clip.nodes.contains(where: { visible.intersects($0.bounds.offsetBy(dx: 16, dy: 16)) }) { center = middle }
            var pasted: [UUID] = []
            edit { pasted = $0.paste(clip, centeredAt: center) }
            selection = Set(pasted); selectedConnection = nil
        } else if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            var created: UUID?
            edit { doc in
                let id = doc.add(.text, in: CGRect(origin: location.map(toDoc) ?? middle, size: CGSize(width: 100, height: 24)))
                doc.update([id]) { node in
                    node.text = String(text.prefix(10_000))
                    let size = DesignText.size(of: node.text, in: node, width: 480)
                    node.width = ceil(size.width) + 2; node.height = ceil(size.height)
                }
                created = id
            }
            if let created { selection = [created]; selectedConnection = nil }
        }
    }
}
