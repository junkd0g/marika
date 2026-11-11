import AppKit
import MarikaCore

/// Portable vector artwork: shapes, text, connections, and component icons are SVG elements.
enum DesignSVG {
    static func render(_ document: DesignDocument, selection: Set<UUID> = []) throws -> String {
        let plan = try DesignExportPlan(document: document, selection: selection)
        func n(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value) }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
        }
        func color(_ value: DesignColor) -> String { String(value.hex.prefix(7)) }
        func points(_ values: [CGPoint]) -> String { values.map { n($0.x) + "," + n($0.y) }.joined(separator: " ") }
        var defs = "", shapes: [String] = []
        for flow in DesignFlow.allCases {
            defs += "<marker id=\"arrow-\(flow.rawValue)\" viewBox=\"0 0 10 10\" refX=\"10\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0 0 L10 5 L0 10\" fill=\"none\" stroke=\"\(color(flow.color))\" stroke-width=\"1.5\"/></marker>"
        }
        for node in plan.nodes {
            if let shadow = node.shadow {
                defs += "<filter id=\"s\(node.id)\" x=\"-100%\" y=\"-100%\" width=\"300%\" height=\"300%\"><feDropShadow dx=\"\(n(shadow.x))\" dy=\"\(n(shadow.y))\" stdDeviation=\"\(n(shadow.blur / 2))\" flood-color=\"\(color(shadow.color))\" flood-opacity=\"\(n(shadow.color.alpha))\"/></filter>"
            }
            defs += "<clipPath id=\"c\(node.id)\"><rect x=\"\(n(node.x))\" y=\"\(n(node.y))\" width=\"\(n(node.width))\" height=\"\(n(node.height))\"/></clipPath>"
        }
        func shape(_ node: DesignNode) -> String {
            let stroke = node.stroke.map { "stroke=\"\(color($0))\" stroke-opacity=\"\(n($0.alpha))\" stroke-width=\"\(n(node.strokeWidth))\"" } ?? "stroke=\"none\""
            let dash = node.strokeStyle == .dashed ? "stroke-dasharray=\"8 6\"" : node.strokeStyle == .dotted ? "stroke-dasharray=\"1 5\" stroke-linecap=\"round\"" : ""
            let style = "fill=\"\(color(node.fill))\" fill-opacity=\"\(n(node.fill.alpha))\" \(stroke) \(dash)"
            var body = ""
            switch node.kind {
            case .frame, .rectangle: body = "<rect x=\"\(n(node.x))\" y=\"\(n(node.y))\" width=\"\(n(node.width))\" height=\"\(n(node.height))\" rx=\"\(n(node.cornerRadius))\" \(style)/>"
            case .ellipse: body = "<ellipse cx=\"\(n(node.center.x))\" cy=\"\(n(node.center.y))\" rx=\"\(n(node.width / 2))\" ry=\"\(n(node.height / 2))\" \(style)/>"
            case .polygon, .star: body = "<polygon points=\"\(points(DesignNode.outline(node.kind, sides: node.sides, in: node.frame)))\" \(style)/>"
            case .line, .arrow:
                let a = CGPoint(x: node.x, y: node.y + node.height / 2), b = CGPoint(x: node.x + node.width, y: a.y)
                body = "<path d=\"M\(n(a.x)) \(n(a.y)) L\(n(b.x)) \(n(b.y))\" fill=\"none\" stroke=\"\(color(node.stroke ?? .black))\" stroke-width=\"\(n(max(1, node.strokeWidth)))\" \(dash)/>"
                if node.kind == .arrow {
                    body += "<path d=\"M\(n(b.x - 10)) \(n(b.y - 6)) L\(n(b.x)) \(n(b.y)) L\(n(b.x - 10)) \(n(b.y + 6))\" fill=\"none\" stroke=\"\(color(node.stroke ?? .black))\" stroke-width=\"\(n(max(1, node.strokeWidth)))\"/>"
                }
            case .text: break
            }
            if node.kind == .frame {
                body += "<text x=\"\(n(node.x + 12))\" y=\"\(n(node.y + 21))\" fill=\"\(color(DesignColor(node.textColor)))\" font-family=\"Arial,sans-serif\" font-size=\"11\" font-weight=\"500\">\(escape(node.name))</text>"
            }
            if !node.text.isEmpty && !node.isLinear {
                let leading = node.kind == .text ? 0.0 : node.component == nil ? 12.0 : 50.0
                let trailing = node.kind == .text ? 0.0 : 12.0
                let width = max(1, node.width - leading - trailing)
                let font = NSFont.systemFont(ofSize: node.fontSize, weight: node.resolvedWeight.native)
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                var lines: [String] = []
                for paragraph in node.text.components(separatedBy: "\n") {
                    var current = ""
                    for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                        let candidate = current.isEmpty ? String(word) : current + " " + word
                        if !current.isEmpty && DesignText.size(of: candidate, in: node, width: nil).width > width { lines.append(current); current = String(word) }
                        else { current = candidate }
                    }
                    lines.append(current)
                }
                let available = max(1, node.height - (node.kind == .text ? 0 : 24))
                lines = Array(lines.prefix(max(1, Int(available / lineHeight))))
                let x = node.resolvedAlign == .left ? node.x + leading : node.resolvedAlign == .right ? node.x + node.width - trailing : node.x + leading + width / 2
                let anchor = node.resolvedAlign == .left ? "start" : node.resolvedAlign == .right ? "end" : "middle"
                let top = node.kind == .text ? node.y : node.y + (node.height - Double(lines.count) * lineHeight) / 2
                let ink = DesignColor(node.textColor)
                body += "<text clip-path=\"url(#c\(node.id))\" fill=\"\(color(ink))\" fill-opacity=\"\(n(ink.alpha))\" font-family=\"-apple-system,Arial,sans-serif\" font-size=\"\(n(node.fontSize))\" font-weight=\"\(node.resolvedWeight == .bold ? 700 : node.resolvedWeight == .semibold ? 600 : node.resolvedWeight == .medium ? 500 : 400)\" text-anchor=\"\(anchor)\">"
                for (index, line) in lines.enumerated() { body += "<tspan x=\"\(n(x))\" y=\"\(n(top + font.ascender + Double(index) * lineHeight))\">\(escape(line))</tspan>" }
                body += "</text>"
            }
            if let component = node.component {
                body += "<g transform=\"translate(\(n(node.x + 14)) \(n(node.center.y - 12)))\" fill=\"none\" stroke=\"\(color(DesignColor(node.componentColor)))\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\(icon(component))</g>"
            }
            let filter = node.shadow == nil ? "" : "filter=\"url(#s\(node.id))\""
            return "<g opacity=\"\(n(node.opacity))\" transform=\"rotate(\(n(node.rotation ?? 0)) \(n(node.center.x)) \(n(node.center.y)))\" \(filter)><title>\(escape(node.name))</title>\(body)</g>"
        }
        shapes += plan.nodes.filter { $0.kind == .frame }.map(shape)
        for edge in plan.connections {
            guard let route = edge.route(in: plan.nodes) else { continue }
            let dash = edge.flow.dash.isEmpty ? "" : "stroke-dasharray=\"\(edge.flow.dash.map(n).joined(separator: " "))\""
            shapes.append("<polyline points=\"\(points(route))\" fill=\"none\" stroke=\"\(color(edge.flow.color))\" stroke-width=\"2\" \(dash) marker-end=\"url(#arrow-\(edge.flow.rawValue))\"/>")
        }
        shapes += plan.nodes.filter { $0.kind != .frame }.map(shape)
        for edge in plan.connections where !edge.label.isEmpty {
            guard let point = edge.labelPoint(in: plan.nodes) else { continue }
            let width = ceil((edge.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 10
            shapes.append("<g><rect x=\"\(n(point.x - width / 2))\" y=\"\(n(point.y - 9))\" width=\"\(n(width))\" height=\"18\" rx=\"4\" fill=\"white\"/><text x=\"\(n(point.x))\" y=\"\(n(point.y + 4))\" font-family=\"Arial,sans-serif\" font-size=\"11\" text-anchor=\"middle\">\(escape(edge.label))</text></g>")
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(n(plan.bounds.minX)) \(n(plan.bounds.minY)) \(n(plan.bounds.width)) \(n(plan.bounds.height))\" width=\"\(n(plan.bounds.width))\" height=\"\(n(plan.bounds.height))\"><title>\(escape(document.title ?? "Design"))</title><defs>\(defs)</defs>\(shapes.joined())</svg>"
    }
    private static func icon(_ type: DesignComponent) -> String {
        switch type {
        case .client: "<rect x=\"3\" y=\"3\" width=\"18\" height=\"14\" rx=\"1\"/><path d=\"M0 20H24M3 17L0 20M21 17L24 20\"/>"
        case .database: "<ellipse cx=\"12\" cy=\"5\" rx=\"9\" ry=\"4\"/><path d=\"M3 5V19C3 24 21 24 21 19V5M3 12C3 17 21 17 21 12\"/>"
        case .api: "<path d=\"M8 2H5V8L2 12L5 16V22H8M16 2H19V8L22 12L19 16V22H16\"/>"
        case .cache: "<path d=\"M14 1L4 14H11L9 23L21 9H13Z\"/>"
        case .queue: "<rect x=\"2\" y=\"2\" width=\"20\" height=\"8\" rx=\"2\"/><rect x=\"2\" y=\"14\" width=\"20\" height=\"8\" rx=\"2\"/><path d=\"M6 6H18M6 18H18\"/>"
        case .gateway: "<path d=\"M12 23V12L3 3M12 12L21 3M0 3H6V9M18 3H24V9\"/>"
        case .external: "<path d=\"M5 20C-1 20-1 11 5 11C3 1 18 0 19 10C26 9 28 20 20 20Z\"/>"
        case .storage: "<path d=\"M2 15L6 3H18L22 15Z\"/><rect x=\"2\" y=\"15\" width=\"20\" height=\"7\" rx=\"2\"/><path d=\"M16 18H18\"/>"
        case .worker: "<circle cx=\"12\" cy=\"12\" r=\"7\"/><circle cx=\"12\" cy=\"12\" r=\"2\"/><path d=\"M12 1V5M12 19V23M1 12H5M19 12H23M4 4L7 7M17 17L20 20M4 20L7 17M17 7L20 4\"/>"
        case .service: "<rect x=\"2\" y=\"1\" width=\"20\" height=\"6\" rx=\"1\"/><rect x=\"2\" y=\"9\" width=\"20\" height=\"6\" rx=\"1\"/><rect x=\"2\" y=\"17\" width=\"20\" height=\"6\" rx=\"1\"/><path d=\"M5 4H6M5 12H6M5 20H6\"/>"
        }
    }
}
