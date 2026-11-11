#if DEBUG
import AppKit
import MarikaCore

@MainActor
enum DebugDesignComponents {
    private static func canvas(_ model: AppModel) throws -> DesignCanvasModel {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil,
              let project = model.selectedProject ?? model.spaceProjects.first else {
            throw DesignToolError("Component checks require an isolated project")
        }
        model.openProject(project, tab: .design)
        guard let canvas = model.designCanvases[project.id] else { throw DesignToolError("Canvas missing") }
        return canvas
    }

    static func prepare(_ model: AppModel) throws {
        let canvas = try canvas(model)
        canvas.edit { $0 = DesignDocument() }
        canvas.selection = []; canvas.tool = .select
        canvas.zoom = 1; canvas.offset = CGSize(width: 80, height: 80)
    }

    static func check(_ model: AppModel, directory: String) throws {
        let canvas = try canvas(model)
        guard canvas.doc.nodes.count == 1, let added = canvas.doc.nodes.first, added.component == .service,
              canvas.selection == [added.id] else { throw DesignToolError("Clicking the library did not insert a selected service") }
        canvas.editor.undo()
        guard canvas.doc.nodes.isEmpty else { throw DesignToolError("Component insertion was not one undo step") }
        canvas.editor.redo()
        guard canvas.doc.node(added.id)?.component == .service else { throw DesignToolError("Redo lost the component type") }
        let location = CGPoint(x: 300, y: 260)
        let expected = canvas.toDoc(location)
        guard !canvas.acceptComponentDrop(["arbitrary text", DesignComponentLibrary.dragPrefix + "unknown"], at: location),
              canvas.doc.nodes.count == 1 else { throw DesignToolError("Unrelated drops changed the canvas") }
        guard canvas.acceptComponentDrop([DesignComponentLibrary.dragPrefix + "database"], at: location),
              let dropped = canvas.doc.nodes.last, dropped.component == .database, dropped.center == expected else {
            throw DesignToolError("Dropping a component ignored its location or type")
        }
        canvas.editor.undo()
        guard canvas.doc.nodes.count == 1 else { throw DesignToolError("Drop was not one undo step") }
        canvas.edit { $0 = DesignDocument() }
        for (index, component) in DesignComponent.allCases.enumerated() {
            let center = CGPoint(x: Double(index % 3) * 290 + 118, y: Double(index / 3) * 148 + 50)
            canvas.insertComponent(component, at: canvas.toScreen(center))
        }
        guard canvas.doc.nodes.map(\.component) == DesignComponent.allCases.map(Optional.some) else {
            throw DesignToolError("Component gallery lost a type")
        }
        let source = canvas.doc.nodes[2].id, target = canvas.doc.nodes[5].id
        canvas.edit { $0.connect(source, target, label: "query") }
        canvas.selection = [source]
        canvas.fit()
        let reference = try DesignTools.referencePrompt(canvas.doc)
        guard reference.contains("Engineering component: Database"), reference.contains("Architecture placeholder") else {
            throw DesignToolError("Engineering role or description missing from chat context")
        }
        let png = try DesignRenderer.png(document: canvas.doc)
        guard let bitmap = NSBitmapImageRep(data: png) else { throw DesignToolError("Component export is empty") }
        let plan = try DesignExportPlan(document: canvas.doc, selection: [])
        for node in canvas.doc.nodes {
            var ink = 0
            for x in stride(from: node.x + 14, through: node.x + 38, by: 2) {
                for y in stride(from: node.center.y - 14, through: node.center.y + 14, by: 2) {
                    let px = Int((x - plan.bounds.minX) * plan.scale), py = Int((y - plan.bounds.minY) * plan.scale)
                    if let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 { ink += 1 }
                }
            }
            guard ink >= 3 else { throw DesignToolError("Missing component icon: " + node.name) }
        }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("engineering-export.png"))
    }

    static func capture(_ model: AppModel, path: String) throws {
        let canvas = try canvas(model)
        func findSurface(_ view: NSView) -> DesignEventView? {
            view as? DesignEventView ?? view.subviews.lazy.compactMap(findSurface).first
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let root = window.contentView, let surface = findSurface(root) else { throw DesignToolError("Canvas window missing") }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
        try capture.run(); capture.waitUntilExit()
        guard capture.terminationStatus == 0, let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))) else {
            throw DesignToolError("Component screenshot failed")
        }
        let sx = Double(bitmap.pixelsWide) / window.frame.width, sy = Double(bitmap.pixelsHigh) / window.frame.height
        for node in canvas.doc.nodes where node.component != nil {
            let a = surface.convert(canvas.toScreen(CGPoint(x: node.x + 50, y: node.center.y - 12)), to: nil)
            let b = surface.convert(canvas.toScreen(CGPoint(x: node.x + node.width - 12, y: node.center.y + 12)), to: nil)
            let minX = max(0, Int(a.x * sx)), maxX = min(bitmap.pixelsWide - 1, Int(b.x * sx))
            let minY = max(0, Int((window.frame.height - a.y) * sy)), maxY = min(bitmap.pixelsHigh - 1, Int((window.frame.height - b.y) * sy))
            guard minX < maxX, minY < maxY else { throw DesignToolError("Component outside screenshot") }
            var ink = 0
            for y in minY...maxY {
                for x in minX...maxX {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       max(color.redComponent, color.greenComponent, color.blueComponent) < 0.6 { ink += 1 }
                }
            }
            let expected = Double(node.text.count) * 8 * canvas.zoom * canvas.zoom * sx * sy
            guard Double(ink) > expected else { throw DesignToolError("Component label clipped or missing: " + node.name) }
        }
    }
}
#endif
