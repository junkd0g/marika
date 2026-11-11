import AppKit
import CoreText
import MarikaCore
import SwiftUI

extension DesignColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}

extension DesignNode {
    /// Text layers read as body copy; labels inside shapes are a little heavier and centered.
    var resolvedWeight: DesignFontWeight { fontWeight ?? (kind == .text ? .regular : component == nil ? .medium : .semibold) }
    var resolvedAlign: DesignTextAlign { textAlign ?? (kind == .text || component != nil ? .left : .center) }

    var componentColor: Color {
        let brightness = fill.red * 0.299 + fill.green * 0.587 + fill.blue * 0.114
        return brightness < 0.55 && fill.alpha > 0.4 ? .white : component?.accent.color ?? textColor
    }

    var textColor: Color {
        guard kind != .text else { return fill.color }
        let brightness = fill.red * 0.299 + fill.green * 0.587 + fill.blue * 0.114
        return brightness < 0.55 && fill.alpha > 0.4 ? Color.white : Color.black.opacity(0.85)
    }

    var strokeStyling: StrokeStyle {
        let width = isLinear ? max(1, strokeWidth) : strokeWidth
        switch strokeStyle {
        case .dashed: return StrokeStyle(lineWidth: width, lineCap: isLinear ? .round : .butt, lineJoin: .round, dash: [max(3, width * 4), max(3, width * 3)])
        case .dotted: return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: [0.01, max(2, width * 2)])
        case .solid, nil: return StrokeStyle(lineWidth: width, lineCap: isLinear ? .round : .butt, lineJoin: isLinear ? .round : .miter)
        }
    }
}

extension DesignFontWeight {
    var font: Font.Weight {
        switch self { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold }
    }
    var native: NSFont.Weight {
        switch self { case .regular: .regular; case .medium: .medium; case .semibold: .semibold; case .bold: .bold }
    }
}

extension DesignTextAlign {
    var text: TextAlignment {
        switch self { case .left: .leading; case .center: .center; case .right: .trailing }
    }
    var horizontal: HorizontalAlignment {
        switch self { case .left: .leading; case .center: .center; case .right: .trailing }
    }
}

enum DesignText {
    /// The space a layer's text needs, wrapped at `width` when given.
    static func size(of text: String, in node: DesignNode, width: Double?) -> CGSize {
        let font = NSFont.systemFont(ofSize: node.fontSize, weight: node.resolvedWeight.native)
        return NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).size
    }
}

struct DesignPolygon: Shape {
    let kind: DesignNode.Kind
    let sides: Int?
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines(DesignNode.outline(kind, sides: sides, in: rect))
        path.closeSubpath()
        return path
    }
}

/// Artwork is drawn into the viewport in one pass. Positioned SwiftUI subviews have layout
/// bounds unrelated to their document coordinates and can be culled on selection/layout updates.
/// Keeping artwork in a Canvas also bounds the backing surface when the document is very large.
struct DesignScene: View {
    let nodes: [DesignNode]
    var connections: [DesignConnection] = []
    var editing: UUID?
    var zoom = 1.0
    var offset = CGSize.zero
    var exporting = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let visible = nodes.filter { !$0.isHidden }
        let routes = connections.compactMap { connection in connection.route(in: nodes).map { (connection, $0) } }
        let background = exporting ? Color.white : Theme.designCanvas
        // Observe appearance outside the drawing closure, just as we do with the document.
        let appearance = colorScheme
        Canvas { context, _ in
            _ = appearance
            context.translateBy(x: offset.width, y: offset.height)
            context.scaleBy(x: zoom, y: zoom)
            // Frames are backgrounds. Connections must sit above them, but below other shapes.
            for node in visible where node.kind == .frame { draw(node, in: context) }
            for (edge, points) in routes {
                context.stroke(DesignConnectionPath.path(points), with: .color(edge.flow.color.color),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: edge.flow.dash.map { CGFloat($0) }))
            }
            for node in visible where node.kind != .frame { draw(node, in: context) }
            if exporting {
                for node in visible where node.kind == .frame {
                    context.draw(Text(node.name).font(.system(size: 11, weight: .medium)).foregroundStyle(node.textColor),
                                 at: CGPoint(x: node.x + 12, y: node.y + 12), anchor: .topLeading)
                }
            }
            // Paint labels last so another connection cannot strike through them.
            for (edge, points) in routes where !edge.label.isEmpty {
                let middle = DesignConnection.point(on: points, fraction: edge.labelFraction)
                let frame = visible.last { $0.kind == .frame && $0.bounds.contains(middle) }
                let fill = frame?.fill.color ?? background
                let ink = frame?.textColor ?? (exporting ? Color.black : Color.primary)
                let text = context.resolve(Text(edge.label).font(.system(size: 11)).foregroundStyle(ink))
                let size = text.measure(in: CGSize(width: 2_000, height: 200))
                let rect = CGRect(x: middle.x - size.width / 2 - 5, y: middle.y - size.height / 2 - 3,
                                  width: size.width + 10, height: size.height + 6)
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(fill))
                context.draw(text, at: middle)
            }
        }
    }

    private func draw(_ node: DesignNode, in context: GraphicsContext) {
        var transformed = context
        transformed.translateBy(x: node.center.x, y: node.center.y)
        transformed.rotate(by: .degrees(node.rotation ?? 0))
        transformed.translateBy(x: -node.width / 2, y: -node.height / 2)
        transformed.opacity *= node.opacity
        if let shadow = node.shadow {
            transformed.addFilter(.shadow(color: shadow.color.color, radius: shadow.blur / 2, x: shadow.x, y: shadow.y))
        }
        transformed.drawLayer { layer in
            let rect = CGRect(x: 0, y: 0, width: node.width, height: node.height)
            if node.isLinear {
                var path = Path()
                let middle = node.height / 2, head = max(10, node.strokeWidth * 4)
                path.move(to: CGPoint(x: 0, y: middle)); path.addLine(to: CGPoint(x: node.width, y: middle))
                if node.kind == .arrow {
                    path.move(to: CGPoint(x: node.width - head * cos(.pi / 6), y: middle - head * sin(.pi / 6)))
                    path.addLine(to: CGPoint(x: node.width, y: middle))
                    path.addLine(to: CGPoint(x: node.width - head * cos(.pi / 6), y: middle + head * sin(.pi / 6)))
                }
                layer.stroke(path, with: .color((node.stroke ?? .black).color), style: node.strokeStyling)
                return
            }
            if node.kind != .text {
                let path = shape(node, in: rect)
                layer.fill(path, with: .color(node.fill.color))
                if let stroke = node.stroke {
                    let inset = node.kind == .rectangle || node.kind == .frame || node.kind == .ellipse ? node.strokeWidth / 2 : 0
                    layer.stroke(shape(node, in: rect.insetBy(dx: inset, dy: inset)), with: .color(stroke.color), style: node.strokeStyling)
                }
            }
            if node.id != editing { drawLabel(node, in: layer) }
            if let component = node.component {
                var icon = layer.resolve(Image(systemName: component.symbol))
                icon.shading = .color(node.componentColor)
                let scale = min(24 / max(1, icon.size.width), min(26, node.height * 0.5) / max(1, icon.size.height))
                let size = CGSize(width: icon.size.width * scale, height: icon.size.height * scale)
                layer.draw(icon, in: CGRect(x: 26 - size.width / 2, y: node.height / 2 - size.height / 2,
                                           width: size.width, height: size.height))
            }
        }
    }

    /// Draw text directly into the artwork, avoiding retained symbol views whose cached
    /// contents can be clipped when a popover opens or the window changes appearance.
    private func drawLabel(_ node: DesignNode, in layer: GraphicsContext) {
        guard !node.text.isEmpty else { return }
        let leading = node.kind == .text ? 0.0 : node.component == nil ? 12.0 : 50.0
        let trailing = node.kind == .text ? 0.0 : 12.0
        let vertical = node.kind == .text ? 0.0 : 12.0
        let area = CGRect(x: leading, y: vertical, width: node.width - leading - trailing, height: node.height - 2 * vertical)
        guard area.width > 0, area.height > 0 else { return }
        let native = NSFont.systemFont(ofSize: node.fontSize, weight: node.resolvedWeight.native)
        let font = CTFontCreateWithName(native.fontName as CFString, node.fontSize, nil)
        var alignment: CTTextAlignment = switch node.resolvedAlign {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        let paragraph = withUnsafePointer(to: &alignment) { value in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: value)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor(node.textColor).cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        let text = NSAttributedString(string: node.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
            CGSize(width: area.width, height: .greatestFiniteMagnitude), nil)
        let height = min(area.height, ceil(measured.height) + 1)
        let y = node.kind == .text ? area.minY : area.midY - height / 2
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(),
            CGPath(rect: CGRect(x: 0, y: 0, width: area.width, height: height), transform: nil), nil)
        layer.withCGContext { context in
            context.saveGState()
            let matrix = context.textMatrix
            defer { context.textMatrix = matrix; context.restoreGState() }
            context.clip(to: area)
            context.translateBy(x: area.minX, y: y + height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
        }
    }

    private func shape(_ node: DesignNode, in rect: CGRect) -> Path {
        switch node.kind {
        case .ellipse: Path(ellipseIn: rect)
        case .polygon, .star: DesignPolygon(kind: node.kind, sides: node.sides).path(in: rect)
        default: Path(roundedRect: rect, cornerRadius: min(node.cornerRadius, min(rect.width, rect.height) / 2))
        }
    }
}

/// Shared by artwork and the selected-connection overlay, including the arrowhead.
enum DesignConnectionPath {
    static func path(_ points: [CGPoint]) -> Path {
        Path { path in
            path.addLines(points)
            if let end = points.last, let before = points.dropLast().last(where: { $0 != end }) {
                let angle = atan2(end.y - before.y, end.x - before.x)
                path.move(to: CGPoint(x: end.x - 10 * cos(angle - .pi / 6), y: end.y - 10 * sin(angle - .pi / 6)))
                path.addLine(to: end)
                path.addLine(to: CGPoint(x: end.x - 10 * cos(angle + .pi / 6), y: end.y - 10 * sin(angle + .pi / 6)))
            }
        }
    }
}

@MainActor
enum DesignRenderer {
    static func png(document: DesignDocument, selection: Set<UUID> = []) throws -> Data {
        let plan = try DesignExportPlan(document: document, selection: selection)
        let scene = DesignScene(nodes: plan.nodes, connections: plan.connections,
                                offset: CGSize(width: -plan.bounds.minX, height: -plan.bounds.minY), exporting: true)
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
