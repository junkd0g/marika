import MarikaCore
import SwiftUI

extension ContainerCondition {
    var color: Color { switch self { case .ready, .complete: .green; case .pending: .orange; case .failed: .red; case .stopped, .suspended: .secondary; case .configured: .blue } }
}

struct ContainerTopologyView: View {
    let workspace: ContainerWorkspace
    @State private var viewport: CGFloat = 950
    @State private var viewportHeight: CGFloat = 500
    private var graph: ContainerTopology { workspace.topology }
    var body: some View {
        let graph = graph
        let columns = workspace.settings.provider == .docker ? ["Compose stacks", "Containers", "Images"] : ["Services", "Workloads", "Pods"]
        let cardWidth = max(190, (viewport - 144) / 3)
        let stride = cardWidth + 48
        let positions = Dictionary(uniqueKeysWithValues: (0..<3).flatMap { column in
            graph.nodes.filter { $0.column == column }.enumerated().map { index, node in
                (node.id, CGPoint(x: 24 + CGFloat(column) * stride, y: CGFloat(80 + index * 110)))
            }
        })
        let rows = (0..<3).map { column in graph.nodes.filter { $0.column == column }.count }.max() ?? 1
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in graph.edges {
                        guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
                        let start = CGPoint(x: from.x + cardWidth, y: from.y + 37), end = CGPoint(x: to.x, y: to.y + 37)
                        var path = Path(); path.move(to: start)
                        if edge.isRouting {
                            path.addLine(to: CGPoint(x: start.x + 15, y: start.y))
                            path.addLine(to: CGPoint(x: start.x + 15, y: 54))
                            path.addLine(to: CGPoint(x: end.x - 18, y: 54))
                            path.addLine(to: CGPoint(x: end.x - 18, y: end.y))
                            path.addLine(to: end)
                        } else {
                            path.addCurve(to: end, control1: CGPoint(x: (start.x + end.x) / 2, y: start.y), control2: CGPoint(x: (start.x + end.x) / 2, y: end.y))
                        }
                        context.stroke(path, with: .color(edge.isRouting ? Color.blue.opacity(0.4) : Color.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: edge.isRouting ? [5, 4] : []))
                        var arrow = Path(); arrow.move(to: CGPoint(x: end.x - 6, y: end.y - 4)); arrow.addLine(to: end); arrow.addLine(to: CGPoint(x: end.x - 6, y: end.y + 4))
                        context.stroke(arrow, with: .color(Color.secondary.opacity(0.65)), lineWidth: 1.5)
                    }
                }
                ForEach(Array(columns.enumerated()), id: \.offset) { index, title in
                    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).offset(x: 24 + CGFloat(index) * stride, y: 20)
                }
                ForEach(graph.nodes) { node in
                    Button { if let id = node.resourceID { workspace.selectedID = id } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: node.symbol).font(.system(size: 17)).foregroundStyle(node.condition.color).frame(width: 24)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(node.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                                Text(node.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Circle().fill(node.condition.color).frame(width: 7, height: 7).padding(.top, 4)
                        }.padding(12).frame(width: cardWidth, height: 80, alignment: .topLeading)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(workspace.selectedID == node.resourceID && node.resourceID != nil ? Theme.action : Theme.hairline, lineWidth: workspace.selectedID == node.resourceID && node.resourceID != nil ? 2 : 1) }
                    }.buttonStyle(.plain).offset(x: positions[node.id]?.x ?? 0, y: positions[node.id]?.y ?? 0)
                    .accessibilityLabel(node.title + ", " + node.subtitle)
                    #if DEBUG
                    .background(DebugViewMarker(name: "container-node-" + node.id).offset(x: positions[node.id]?.x ?? 0, y: positions[node.id]?.y ?? 0))
                    #endif
                }
            }.frame(width: max(viewport, cardWidth * 3 + 144), height: max(viewportHeight - 30, CGFloat(max(1, rows) * 110 + 80)), alignment: .topLeading)
            if workspace.settings.provider == .kubernetes {
                Text("Dashed: service routing · Solid: workload ownership").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
            }
            if graph.truncated { Text("Showing the first 90 resources. Filter to focus the map.").font(.caption).foregroundStyle(.secondary).padding() }
        }.background(Theme.designCanvas)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0.width; viewportHeight = $0.height }
    }
}
