#if DEBUG
import AppKit
import MarikaCore

/// Regression checks for defects that document/model assertions cannot see.
@MainActor
enum DebugDesignVisualChecks {
    static func run(_ model: AppModel, directory: String) async throws {
        guard DebugFixtureSettings.value("MARIKA_DATA") != nil,
              let project = model.selectedProject ?? model.spaceProjects.first else {
            throw DesignToolError("Visual checks require an isolated Design fixture.")
        }
        model.openProject(project, tab: .design)
        guard let canvas = model.designCanvases[project.id] else { throw DesignToolError("Canvas missing") }
        let original = canvas.doc
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Task.sleep(for: .seconds(0.3))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let surface = eventView(window.contentView) else { throw DesignToolError("Canvas window missing") }
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(0.3))
        let samples = ["Web app", "Mobile app", "API gateway", "Auth check", "Queue", "Worker"]
        let nodes = original.nodes.filter { samples.contains($0.name) }
        guard nodes.count == samples.count else { throw DesignToolError("Visual fixture is missing shapes") }
        for (name, selected, dark, compact) in [
            ("visual-single", ["API gateway"], false, false),
            ("visual-multiple", ["Web app", "Mobile app", "Sign-in note"], false, false),
            ("visual-dark", ["Auth check"], true, false),
            ("visual-compact", ["Worker"], false, true),
            ("visual-restored", [String](), false, false),
        ] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(compact ? CGSize(width: 900, height: 600) : CGSize(width: 1440, height: 900))
            canvas.selection = Set(original.nodes.filter { selected.contains($0.name) }.map(\.id))
            canvas.selectedConnection = nil
            canvas.fit()
            try await Task.sleep(for: .seconds(0.5))
            window.contentView?.layoutSubtreeIfNeeded()
            guard !compact || canvas.canvasSize.width >= 600 else {
                throw DesignToolError("Compact Design still leaves too little room for artwork: \(canvas.canvasSize.width)")
            }
            let url = folder.appendingPathComponent(name + ".png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
            try capture.run(); capture.waitUntilExit()
            guard capture.terminationStatus == 0, let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
                throw DesignToolError("Native Design screenshot failed")
            }
            let sx = Double(bitmap.pixelsWide) / window.frame.width
            let sy = Double(bitmap.pixelsHigh) / window.frame.height
            func pixel(_ point: CGPoint) -> CGPoint {
                let local = surface.convert(canvas.toScreen(point), to: nil)
                return CGPoint(x: local.x * sx, y: (window.frame.height - local.y) * sy)
            }
            try verify(bitmap, nodes: nodes, connections: original.connections ?? [], allNodes: original.nodes,
                       pixel: pixel, context: name)
        }
        // Folding never drops layers or changes the saved document.
        guard let frame = original.nodes.first(where: { $0.kind == .frame }),
              let child = original.nodes.first(where: { original.parents[$0.id] == frame.id }) else {
            throw DesignToolError("Visual fixture has no nested layers")
        }
        canvas.collapsedFrames = [frame.id]
        guard !canvas.layerRows.contains(where: { $0.id == child.id }) else { throw DesignToolError("Frame did not collapse") }
        canvas.selection = [child.id]; canvas.revealSelectedLayers()
        guard canvas.layerRows.contains(where: { $0.id == child.id && $0.depth > 0 }) else {
            throw DesignToolError("Selecting a child did not reveal its frame")
        }
        let siblings = original.nodes.filter { original.parents[$0.id] == frame.id }
        guard siblings.count >= 3 else { throw DesignToolError("Layer selection fixture needs three siblings") }
        let first = siblings[0].id, second = siblings[1].id
        canvas.selectLayer(first, modifiers: [])
        canvas.selectLayer(second, modifiers: .command)
        guard canvas.selection == [first, second] else { throw DesignToolError("Command-click did not extend the layer selection") }
        canvas.selectLayer(second, modifiers: .command)
        guard canvas.selection == [first] else { throw DesignToolError("Command-click did not toggle the layer selection") }
        canvas.selectLayer(first, modifiers: [])
        canvas.selectLayer(siblings[2].id, modifiers: .shift)
        guard canvas.selection == Set(siblings.map(\.id)) else { throw DesignToolError("Shift-click did not select a layer range") }
        guard canvas.doc == original else { throw DesignToolError("Visual checks changed the document") }
        canvas.selection = []
        let plan = try DesignExportPlan(document: original, selection: [])
        let png = try DesignRenderer.png(document: original)
        try png.write(to: folder.appendingPathComponent("visual-export.png"))
        guard let bitmap = NSBitmapImageRep(data: png) else { throw DesignToolError("Export could not be decoded") }
        try verify(bitmap, nodes: nodes, connections: original.connections ?? [], allNodes: original.nodes,
                   pixel: { CGPoint(x: ($0.x - plan.bounds.minX) * plan.scale, y: ($0.y - plan.bounds.minY) * plan.scale) },
                   context: "PNG export")
    }

    private static func eventView(_ root: NSView?) -> DesignEventView? {
        guard let root else { return nil }
        return root as? DesignEventView ?? root.subviews.lazy.compactMap { eventView($0) }.first
    }

    private static func verify(_ bitmap: NSBitmapImageRep, nodes: [DesignNode], connections: [DesignConnection],
                               allNodes: [DesignNode], pixel: (CGPoint) -> CGPoint, context: String) throws {
        func color(_ x: Int, _ y: Int) -> NSColor? {
            guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return nil }
            return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        }
        func count(in rect: CGRect, matching test: (NSColor) -> Bool) -> Int {
            var result = 0
            for y in Int(rect.minY.rounded(.down))...Int(rect.maxY.rounded(.up)) {
                for x in Int(rect.minX.rounded(.down))...Int(rect.maxX.rounded(.up)) {
                    if let value = color(x, y), test(value) { result += 1 }
                }
            }
            return result
        }
        for node in nodes {
            let fill = pixel(CGPoint(x: node.x + node.width * 0.35, y: node.y + node.height * 0.25))
            let fillCount = count(in: CGRect(x: fill.x - 2, y: fill.y - 2, width: 4, height: 4)) {
                // HDR window captures can tone-map colors. A missing tint must still fail.
                let expectedInk = 1 - min(node.fill.red, node.fill.green, node.fill.blue)
                let actualInk = 1 - min($0.redComponent, $0.greenComponent, $0.blueComponent)
                return abs($0.redComponent - node.fill.red) < 0.13 && abs($0.greenComponent - node.fill.green) < 0.13
                    && abs($0.blueComponent - node.fill.blue) < 0.13 && actualInk >= expectedInk * 0.4
            }
            guard fillCount > 2 else {
                throw DesignToolError("\(context): \(node.name) fill missing at \(fill): \(String(describing: color(Int(fill.x), Int(fill.y))))")
            }
            let a = pixel(CGPoint(x: node.x + node.width * 0.15, y: node.y + node.height * 0.35))
            let b = pixel(CGPoint(x: node.x + node.width * 0.85, y: node.y + node.height * 0.65))
            let dark = node.fill.red * 0.299 + node.fill.green * 0.587 + node.fill.blue * 0.114 < 0.55
            let ink = count(in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)) {
                dark ? min($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.85
                     : max($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.5
            }
            guard ink >= 8 else { throw DesignToolError("\(context): \(node.name) label disappeared") }
        }
        for edge in connections where edge.label.isEmpty {
            guard let route = edge.route(in: allNodes) else { continue }
            let segments = zip(route, route.dropFirst()).map { ($0, $1, hypot($1.x - $0.x, $1.y - $0.y)) }
            func point(at fraction: Double) -> CGPoint {
                var remaining = segments.reduce(0) { $0 + $1.2 } * fraction
                for (a, b, length) in segments where length > 0 {
                    if remaining <= length {
                        return pixel(CGPoint(x: a.x + (b.x - a.x) * remaining / length,
                                             y: a.y + (b.y - a.y) * remaining / length))
                    }
                    remaining -= length
                }
                return pixel(route[0])
            }
            // A selection's size badge may cover the midpoint of a short connection.
            let ink = [0.25, 0.5, 0.75].map { fraction in
                let point = point(at: fraction)
                return count(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)) {
                    let high = max($0.redComponent, $0.greenComponent, $0.blueComponent)
                    let low = min($0.redComponent, $0.greenComponent, $0.blueComponent)
                    return high - low < 0.06 && low > 0.2 && high < 0.8
                }
            }
            guard ink.contains(where: { $0 > 2 }) else {
                throw DesignToolError("\(context): connector to \(allNodes.first { $0.id == edge.to }?.name ?? "?") is missing")
            }
        }
    }
}
#endif
