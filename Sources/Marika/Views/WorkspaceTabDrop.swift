import MarikaCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let marikaWorkspaceTab = UTType(exportedAs: "app.marika.workspace-tab")
}

extension WorkspaceTabDrag {
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.marikaWorkspaceTab.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

struct WorkspaceTabDrop: DropDelegate {
    let projectID: UUID
    let size: CGSize
    @Binding var edge: ProjectSplitEdge?
    var split: (WorkspaceTabDrag, ProjectSplitEdge) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.marikaWorkspaceTab])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = target(info.location)
        return DropProposal(operation: edge == nil ? .cancel : .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        let destination = target(info.location)
        edge = nil
        guard let destination, let provider = info.itemProviders(for: [.marikaWorkspaceTab]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.marikaWorkspaceTab.identifier) { data, _ in
            guard let data, let drag = try? JSONDecoder().decode(WorkspaceTabDrag.self, from: data), drag.projectID == projectID else { return }
            Task { @MainActor in split(drag, destination) }
        }
        return true
    }

    private func target(_ point: CGPoint) -> ProjectSplitEdge? {
        ProjectSplitEdge.target(x: point.x, y: point.y, width: size.width, height: size.height)
    }
}

struct WorkspaceSplitPreview: View {
    let edge: ProjectSplitEdge

    var body: some View {
        GeometryReader { geometry in
            let width = edge.stacked ? geometry.size.width : geometry.size.width / 2
            let height = edge.stacked ? geometry.size.height / 2 : geometry.size.height
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.16))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2) }
                .overlay {
                    Label("Split \(edge.rawValue)", systemImage: edge.stacked ? "rectangle.split.1x2" : "rectangle.split.2x1")
                        .font(.system(size: 14, weight: .semibold)).padding(12)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(8).frame(width: width, height: height)
                .offset(x: edge == .right ? width : 0, y: edge == .bottom ? height : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
