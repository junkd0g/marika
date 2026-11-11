#if DEBUG
import Foundation
import MarikaCore
import AppKit

@MainActor
enum DebugDesignChecks {
    static func descriptions(_ model: AppModel) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.spaceProjects.first else {
            throw DesignToolError("Description checks require an isolated project.")
        }
        model.openProject(project, tab: .design)
        let editor = model.design(for: project)
        guard let id = editor.document.nodes.first(where: { !$0.isLocked })?.id,
              let chatID = model.selectedSessionID else { throw DesignToolError("Fixture element or chat missing") }
        editor.edit { $0.update([id]) { $0.description = "Opens account settings. Preserve unsaved changes before navigating." } }
        await model.open(chatID)
        guard let chat = model.controllers[chatID] else { throw DesignToolError("Fixture chat couldn't load") }
        chat.draft = "Implement the selected component."
        let count = chat.items.count
        try await model.useDesignElementsInChat(projectID: project.id, selection: [id])
        guard model.selectedSessionID == chatID, model.projectTabs[project.id] == .conversation,
              chat.draft.hasPrefix("Implement the selected component."),
              chat.draft.contains("Opens account settings."), chat.draft.contains(id.uuidString),
              chat.items.count == count, !chat.isBusy else { throw DesignToolError("Design reference was not added safely to the existing chat draft") }
        let read = await model.performAgentTool(["name": "project_get_design"], callerID: chatID, projectID: project.id)
        guard read["content"]?[0]?["text"]?.string?.contains("Opens account settings.") == true else {
            throw DesignToolError("Element descriptions are missing from the agent's design context")
        }
        guard await model.save() else { throw DesignToolError("Description fixture couldn't save") }
        let saved = try await model.store.loadWorkspace()
        guard saved.projects.first(where: { $0.id == project.id })?.design?.node(id)?.description == editor.document.node(id)?.description else {
            throw DesignToolError("Element description did not persist")
        }
    }

    /// Drives the canvas the way a pointer and keyboard would, then repeats the essentials with real window events.
    @discardableResult
    static func canvas(_ model: AppModel) async throws -> Bool {
        var menuPath = false
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject ?? model.spaceProjects.first else {
            throw DesignToolError("Canvas checks require an isolated fixture project.")
        }
        model.openProject(project, tab: .design)
        let editor = model.design(for: project)
        guard let canvas = model.designCanvases[project.id] else { throw DesignToolError("Canvas state missing") }
        try await Task.sleep(for: .seconds(0.5))
        let original = editor.document
        editor.edit { $0 = DesignDocument() }
        canvas.selection = []; canvas.selectedConnection = nil; canvas.tool = .select
        canvas.automaticallyFits = false; canvas.zoom = 1; canvas.offset = .zero
        func expect(_ condition: Bool, _ message: String) throws { if !condition { throw DesignToolError("Canvas: " + message) } }
        func at(_ x: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> DesignPointer {
            DesignPointer(location: CGPoint(x: x, y: y), modifiers: flags, clicks: clicks)
        }
        func drag(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ flags: NSEvent.ModifierFlags = []) {
            canvas.pointerDown(at(x0, y0, flags))
            canvas.pointerDragged(at((x0 + x1) / 2, (y0 + y1) / 2, flags))
            canvas.pointerDragged(at(x1, y1, flags))
            canvas.pointerUp(at(x1, y1, flags))
        }
        func frame(_ id: UUID) -> CGRect { editor.document.node(id)?.frame ?? .null }

        // Drawing leaves the new shape selected, returns to Move, and is one undo step.
        canvas.tool = .rectangle
        drag(100, 100, 300, 200)
        guard let a = editor.document.nodes.first?.id else { throw DesignToolError("Canvas: dragging the rectangle tool drew nothing") }
        try expect(frame(a) == CGRect(x: 100, y: 100, width: 200, height: 100) && canvas.tool == .select && canvas.selection == [a], "a drawn rectangle has the wrong frame, tool or selection")
        editor.undo()
        try expect(editor.document.nodes.isEmpty, "drawing was not a single undo step")
        editor.redo()
        canvas.tool = .rectangle
        drag(400, 103, 500, 203, .command)
        let b = editor.document.nodes[1].id
        try expect(frame(b) == CGRect(x: 400, y: 103, width: 100, height: 100), "⌘ did not bypass snapping while drawing")

        // Moving snaps to the neighbor's edges and shows guides only during the drag.
        canvas.pointerDown(at(450, 150))
        canvas.pointerDragged(at(450, 148))
        try expect(frame(b).minY == 103, "a two-pixel wobble moved a layer")
        canvas.pointerDragged(at(452, 146))
        try expect(!canvas.guides.isEmpty && frame(b) == CGRect(x: 402, y: 100, width: 100, height: 100), "moving did not snap to the neighboring edge")
        canvas.pointerUp(at(452, 146))
        try expect(canvas.guides.isEmpty && canvas.selection == [b], "guides or selection were wrong after a move")

        // ⇧-click extends the selection; the shared box scales both layers.
        canvas.pointerDown(at(150, 150, .shift)); canvas.pointerUp(at(150, 150, .shift))
        try expect(canvas.selection == [a, b] && canvas.groupBox == CGRect(x: 100, y: 100, width: 402, height: 100), "⇧-click did not extend the selection")
        try expect(canvas.grip(at: CGPoint(x: 502, y: 200)) == .resize(.bottomRight), "the selection box has no corner handle")
        drag(502, 200, 904, 300)
        try expect(frame(a) == CGRect(x: 100, y: 100, width: 400, height: 200) && frame(b) == CGRect(x: 704, y: 100, width: 200, height: 200), "resizing a multiple selection did not scale its layers")

        // Clicking one layer of a multiple selection narrows to it; its knob rotates it.
        canvas.pointerDown(at(150, 150)); canvas.pointerUp(at(150, 150))
        try expect(canvas.selection == [a], "clicking inside a multiple selection did not narrow it")
        guard let knob = canvas.rotationKnob else { throw DesignToolError("Canvas: no rotation knob") }
        try expect(canvas.grip(at: knob) == .rotate, "the rotation knob is not grabbable")
        drag(knob.x, knob.y, 422, 200)
        try expect(editor.document.node(a)?.rotation == 90, "dragging the knob a quarter turn did not rotate 90°")
        editor.undo()
        try expect(editor.document.node(a)?.rotation == nil, "rotation was not one undo step")

        // The connector tool joins two layers; Delete removes the selected connection.
        canvas.tool = .connector
        drag(300, 200, 804, 200)
        try expect(editor.document.connections?.count == 1 && canvas.activeConnection != nil && canvas.tool == .select, "the connector tool did not connect two layers")
        try expect(canvas.handleKey("", keyCode: 51, modifiers: []) && (editor.document.connections ?? []).isEmpty, "Delete did not remove the selected connection")
        canvas.tool = .connector
        drag(300, 200, 804, 200)

        // Text: click to type, an abandoned empty layer disappears, double-click edits a shape's label.
        canvas.tool = .text
        canvas.pointerDown(at(100, 500)); canvas.pointerUp(at(100, 500))
        guard let text = canvas.editingText else { throw DesignToolError("Canvas: clicking with the text tool did not start typing") }
        canvas.updateText("Hello canvas")
        canvas.commitText()
        try expect(editor.document.node(text)?.text == "Hello canvas" && frame(text).width > 40 && canvas.editingText == nil, "typed text was not kept and sized")
        let count = editor.document.nodes.count
        canvas.tool = .text
        canvas.pointerDown(at(300, 520)); canvas.pointerUp(at(300, 520))
        canvas.commitText()
        try expect(editor.document.nodes.count == count, "an empty text layer was left behind")
        canvas.pointerDown(at(300, 200, clicks: 2)); canvas.pointerUp(at(300, 200, clicks: 2))
        try expect(canvas.editingText == a, "double-click did not edit the label")
        canvas.updateText("API")
        canvas.pointerDown(at(980, 640)); canvas.pointerUp(at(980, 640))
        try expect(editor.document.node(a)?.text == "API" && canvas.editingText == nil, "clicking away did not keep the label")

        // A frame drawn around layers holds them: it sits beneath, its inside selects contents, its title moves everything.
        canvas.tool = .frame
        drag(50, 50, 950, 450, .command)
        guard let holder = editor.document.nodes.first, holder.kind == .frame else { throw DesignToolError("Canvas: a frame drawn around layers covered them") }
        try expect(editor.document.children(of: holder.id).isSuperset(of: [a, b]), "the frame does not hold the layers inside it")
        canvas.pointerDown(at(600, 400)); canvas.pointerUp(at(600, 400))
        try expect(canvas.selection.isEmpty, "clicking empty space inside a frame grabbed the frame")
        guard let label = canvas.frameLabels.first(where: { $0.id == holder.id })?.rect else { throw DesignToolError("Canvas: the frame has no title") }
        drag(label.midX, label.midY, label.midX + 60, label.midY, .command)
        try expect(canvas.selection == [holder.id] && frame(holder.id).minX == 110 && frame(a).minX == 160 && frame(b).minX == 764, "dragging a frame's title did not carry its contents")
        try expect(editor.document.connections?.first?.route(in: editor.document.nodes)?.first == CGPoint(x: 560, y: 200), "the connection did not follow its layers")

        // ⌥-drag leaves the original and moves a copy.
        let before = editor.document.nodes.count
        canvas.pointerDown(at(864, 200, .option))
        canvas.pointerDragged(at(864, 300, [.option, .command]))
        canvas.pointerDragged(at(864, 420, [.option, .command]))
        canvas.pointerUp(at(864, 420, [.option, .command]))
        guard let copy = canvas.selection.first, canvas.selection.count == 1 else { throw DesignToolError("Canvas: ⌥-drag did not select the copy") }
        try expect(editor.document.nodes.count == before + 1 && copy != b && frame(b).minY == 100 && frame(copy) == frame(b).offsetBy(dx: 0, dy: 220), "⌥-drag did not duplicate")

        // Keys: tools, nudging, duplicate, undo. ⌘G stays free for opening Design.
        try expect(canvas.handleKey("r", keyCode: 15, modifiers: []) && canvas.tool == .rectangle, "R did not pick the rectangle tool")
        try expect(canvas.handleKey("", keyCode: 53, modifiers: []) && canvas.tool == .select, "Escape did not return to Move")
        try expect(canvas.handleKey("", keyCode: 124, modifiers: .shift) && frame(copy).minX == frame(b).minX + 10, "⇧→ did not nudge by ten")
        try expect(canvas.handleCommand("d", modifiers: .command) && editor.document.nodes.count == before + 2, "⌘D did not duplicate")
        try expect(canvas.handleCommand("z", modifiers: .command) && editor.document.nodes.count == before + 1, "⌘Z did not undo")
        try expect(!canvas.handleCommand("g", modifiers: .command), "the canvas swallowed ⌘G")
        canvas.selection = [copy]
        try expect(canvas.handleCommand("g", modifiers: [.command, .option]) && editor.document.nodes.count == before + 2, "⌥⌘G did not frame the selection")
        try expect(canvas.handleCommand("g", modifiers: [.command, .shift]) && editor.document.nodes.count == before + 1 && canvas.selection == [copy], "⇧⌘G did not ungroup")

        // Zooming keeps the point under the cursor still; scrolling pans.
        let anchor = CGPoint(x: 400, y: 300), under = canvas.toDoc(anchor)
        canvas.scroll(dx: 0, dy: 40, at: anchor, zooming: true)
        let after = canvas.toDoc(anchor)
        try expect(canvas.zoom > 1 && abs(after.x - under.x) < 0.001 && abs(after.y - under.y) < 0.001, "zoom drifted away from the cursor")
        let panned = canvas.offset
        canvas.scroll(dx: 12, dy: -7, at: anchor, zooming: false)
        try expect(canvas.offset == CGSize(width: panned.width + 12, height: panned.height - 7), "scrolling did not pan")
        canvas.zoom = 1; canvas.offset = .zero

        // Real events through the window reach the same code.
        func find(_ view: NSView) -> DesignEventView? { (view as? DesignEventView) ?? view.subviews.lazy.compactMap(find).first }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let surface = window.contentView.flatMap(find) else {
            throw DesignToolError("Canvas: the event surface is not in the window")
        }
        func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: surface.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { throw DesignToolError("Canvas: could not create a mouse event") }
            return event
        }
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { throw DesignToolError("Canvas: could not create a key event") }
            return event
        }
        // The component library now occupies the canvas's top-left corner.
        window.sendEvent(try mouse(.leftMouseDown, 30, 80)); window.sendEvent(try mouse(.leftMouseUp, 30, 80))
        try expect(window.firstResponder === surface && canvas.selection.isEmpty, "clicking the canvas did not focus it")
        window.sendEvent(try key("o", 31))
        try expect(canvas.tool == .ellipse, "typing O in the focused canvas did not pick the ellipse tool")
        window.sendEvent(try mouse(.leftMouseDown, 60, 60, .command))
        window.sendEvent(try mouse(.leftMouseDragged, 90, 90, .command))
        window.sendEvent(try mouse(.leftMouseDragged, 120, 120, .command))
        window.sendEvent(try mouse(.leftMouseUp, 120, 120, .command))
        guard let ellipse = editor.document.nodes.last, ellipse.kind == .ellipse else { throw DesignToolError("Canvas: a real drag drew nothing") }
        try expect(ellipse.frame == CGRect(x: 60, y: 60, width: 60, height: 60), "a real drag drew at \(ellipse.frame)")
        try expect(surface.performKeyEquivalent(with: try key("z", 6, .command)) && editor.document.node(ellipse.id) == nil, "⌘Z in the focused canvas did not undo")
        guard let menu = surface.menu(for: try mouse(.rightMouseDown, 864, 420)) else { throw DesignToolError("Canvas: no context menu") }
        try expect(canvas.selection == [copy] && menu.items.contains { $0.title == "Duplicate" } && menu.items.contains { $0.title == "Frame Selection" }, "a secondary click did not select the layer and offer its actions")
        // The menu bar owns ⌘D, ⌘[ and Escape for the browser; with the canvas focused they must reach it first.
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(0.4))
        window.makeFirstResponder(surface)
        if window.isKeyWindow, NSApp.isActive {
            let layers = editor.document.nodes.count
            NSApp.sendEvent(try key("d", 2, .command))
            try expect(editor.document.nodes.count == layers + 1, "⌘D through the menu bar did not duplicate")
            canvas.tool = .frame
            NSApp.sendEvent(try key("\u{1B}", 53))
            try expect(canvas.tool == .select, "Escape through the menu bar did not return to Move")
            NSApp.sendEvent(try key("\u{7F}", 51))
            try expect(editor.document.nodes.count == layers, "Delete through the menu bar did not remove the selection")
            // Typing into the in-place editor and into an inspector field edits the layer.
            canvas.pointerDown(at(864, 420, clicks: 2)); canvas.pointerUp(at(864, 420, clicks: 2))
            try expect(canvas.editingText == copy, "double-click did not open the in-place editor")
            try await Task.sleep(for: .seconds(0.5))
            NSApp.sendEvent(try key("Q", 12))
            try await Task.sleep(for: .seconds(0.2))
            try expect(editor.document.node(copy)?.text.contains("Q") == true, "typing did not reach the in-place editor")
            NSApp.sendEvent(try key("\r", 36))
            try await Task.sleep(for: .seconds(0.4))
            try expect(canvas.editingText == nil && window.firstResponder === surface, "Return did not finish editing and refocus the canvas")
            func fields(_ view: NSView) -> [NSTextField] { ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields) }
            let width = fields(window.contentView!).filter { $0.isEditable && $0.stringValue == "200" && !$0.isHiddenOrHasHiddenAncestor }
            guard width.count == 2 else { throw DesignToolError("Canvas: the inspector does not show the layer's size (\(width.count) fields)") }
            window.makeFirstResponder(width[0])
            try await Task.sleep(for: .seconds(0.3))
            NSApp.sendEvent(try key("3", 20)); NSApp.sendEvent(try key("6", 22)); NSApp.sendEvent(try key("0", 29))
            try await Task.sleep(for: .seconds(0.3))
            try expect(frame(copy).width == 360 && frame(copy).height == 200, "typing a width in the inspector did not resize the layer: \(frame(copy))")
            window.makeFirstResponder(surface)
            try await Task.sleep(for: .seconds(0.2))
            menuPath = true
        }
        if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 30, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)) {
            surface.scrollWheel(with: wheel)
            try expect(canvas.offset.height != 0, "a wheel event did not pan the canvas")
        }

        editor.edit { $0 = original }
        canvas.selection = []; canvas.selectedConnection = nil; canvas.tool = .select
        canvas.fit()
        return menuPath
    }

    /// Selects fixture layers by name so screenshots show selection chrome and the inspector.
    static func select(_ model: AppModel, names: [String], connection: Bool, tool: String?, editing: Bool, clear: Bool) throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject ?? model.spaceProjects.first else {
            throw DesignToolError("Design selection requires an isolated fixture project.")
        }
        model.openProject(project, tab: .design)
        _ = model.design(for: project)
        guard let canvas = model.designCanvases[project.id] else { throw DesignToolError("Canvas state missing") }
        canvas.selection = Set(canvas.doc.nodes.filter { names.contains($0.name) }.map(\.id))
        canvas.selectedConnection = connection ? canvas.doc.connections?.first?.id : nil
        canvas.tool = tool.flatMap(DesignTool.init(rawValue:)) ?? .select
        guard canvas.selection.count == names.count else { throw DesignToolError("Fixture layers not found: \(names)") }
        if clear { canvas.edit { $0 = DesignDocument() } }
        if editing, let id = canvas.selection.first { canvas.beginEditing(id) }
    }

    static func render(_ model: AppModel, to directory: String) throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil, let project = model.selectedProject else {
            throw DesignToolError("Export checks require an isolated fixture project.")
        }
        let document = model.design(for: project).document
        for (name, selection) in [("canvas", Set<UUID>()), ("selection", Set(document.nodes.filter { !$0.isHidden }.prefix(1).map(\.id)))] {
            let plan = try DesignExportPlan(document: document, selection: selection)
            let data = try DesignRenderer.png(document: document, selection: selection)
            guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                  abs(Double(bitmap.pixelsWide) - plan.bounds.width * plan.scale) < 2,
                  abs(Double(bitmap.pixelsHigh) - plan.bounds.height * plan.scale) < 2 else {
                throw DesignToolError("Export dimensions differ from visible artwork.")
            }
            var ink = 0
            for row in 0..<20 {
                for column in 0..<20 {
                    if let color = bitmap.colorAt(x: column * bitmap.pixelsWide / 20, y: row * bitmap.pixelsHigh / 20)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) < 0.98 { ink += 1 }
                }
            }
            guard ink > 5 else { throw DesignToolError("Exported image is blank.") }
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"), options: .atomic)
        }
    }

    static func run(_ model: AppModel) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil,
              model.spaceProjects.count >= 2 else {
            throw DesignToolError("Design integration checks require two isolated fixture projects.")
        }
        let first = model.spaceProjects[0], second = model.spaceProjects[1]
        model.openProject(first, tab: .design)
        guard let caller = model.selectedSessionID else { throw DesignToolError("Fixture chat missing") }
        let editor = model.design(for: first), other = model.design(for: second)
        let original = editor.document, otherOriginal = other.document
        guard let id = original.nodes.first(where: { !$0.isLocked })?.id else { throw DesignToolError("Editable fixture shape missing") }
        let staleRevision = try DesignTools.revision(of: original)
        editor.edit { $0.move([id], by: CGSize(width: 35, height: 0)) }
        guard model.project(id: first.id)?.design == editor.document else { throw DesignToolError("Manual edits were not saved synchronously") }
        let rejected = await model.performAgentTool(["name": "project_publish_design", "arguments": ["baseRevision": .string(staleRevision), "design": "{\"nodes\":[]}"]], callerID: caller, projectID: first.id)
        guard rejected["isError"]?.bool == true else { throw DesignToolError("A stale publish overwrote manual edits") }

        model.openProject(second, tab: .design)
        guard other.document == otherOriginal else { throw DesignToolError("Edits leaked into another project") }
        model.openProject(first, tab: .design)
        guard model.design(for: first) === editor, editor.canUndo else { throw DesignToolError("Tab navigation discarded undo history") }
        editor.undo()
        guard editor.document == original else { throw DesignToolError("Undo did not restore the previous document") }

        let read = await model.performAgentTool(["name": "project_get_design"], callerID: caller, projectID: first.id)
        let snapshot = try JSONValue(parsing: Data((read["content"]?[0]?["text"]?.string ?? "").utf8))
        guard var payload = snapshot["document"]?.object else { throw DesignToolError("Design snapshot missing") }
        payload["title"] = "Updated from chat"
        let published = await model.performAgentTool(["name": "project_publish_design", "arguments": ["baseRevision": snapshot["baseRevision"] ?? .null,
            "design": .string(String(decoding: try JSONValue.object(payload).serialized(), as: UTF8.self))]], callerID: caller, projectID: first.id)
        guard published["isError"]?.bool != true, editor.document.title == "Updated from chat" else { throw DesignToolError("Chat and the visible canvas diverged") }
        editor.undo()
        guard editor.document == original else { throw DesignToolError("Chat publication could not be undone") }
        editor.redo()
        guard editor.document.title == "Updated from chat" else { throw DesignToolError("Chat publication could not be redone") }
        let denied = await model.performAgentTool(["name": "project_get_design"], callerID: caller, projectID: second.id)
        guard denied["isError"]?.bool == true else { throw DesignToolError("A chat accessed another project's canvas") }

        model.openProject(second, tab: .conversation)
        model.openDesign(for: first.id)
        guard model.selectedProject?.id == first.id, model.projectTabs[first.id] == .design else { throw DesignToolError("Open Design used the wrong project") }
        guard await model.save() else { throw DesignToolError("The fixture did not save") }
        let saved = try await model.store.loadWorkspace()
        guard saved.projects.first(where: { $0.id == first.id })?.design == editor.document,
              saved.projects.first(where: { $0.id == second.id })?.design == otherOriginal else { throw DesignToolError("Stored canvases differ from the editors") }
    }
}
#endif
