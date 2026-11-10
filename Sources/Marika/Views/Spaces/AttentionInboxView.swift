import MarikaCore
import SwiftUI

struct AttentionInboxView: View {
    @Environment(AppModel.self) private var model
    private var allSpaces: Bool {
        get { model.attentionScopeAllSpaces }
        nonmutating set { model.attentionScopeAllSpaces = newValue }
    }
    private var filter: String {
        get { model.attentionFilter }
        nonmutating set { model.attentionFilter = newValue }
    }
    @State private var query = ""
    private var scoped: [AttentionItem] {
        model.attentionItems.filter { allSpaces || model.project(id: $0.projectID)?.spaceID == model.selectedSpace.id }
    }
    private var visible: [AttentionItem] {
        scoped.filter {
            (filter == "All updates" || (filter == "Approvals" && ($0.kind == .approval || $0.kind == .input)) ||
             (filter == "Blockers" && ($0.kind == .blocked || $0.kind == .checks)) || (filter == "Review" && $0.kind == .review)) &&
            (query.isEmpty || [$0.title, $0.detail, model.project(id: $0.projectID)?.name ?? ""].joined(separator: " ").localizedStandardContains(query))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            SpaceContentHeader(title: "Needs attention", space: model.selectedSpace) {
                Text("\(scoped.count) \(scoped.count == 1 ? "update" : "updates")").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { scope; kind; Spacer(minLength: 0); search }
                VStack(spacing: 10) { HStack { scope; kind; Spacer(minLength: 0) }; search }
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            if scoped.isEmpty {
                ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle", description:
                    Text(allSpaces ? "No approvals, blockers or results need your attention." : "No approvals, blockers or results need attention in this space. Check All spaces for other work."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SpaceContentMarker(name: "attention-empty"))
            } else if visible.isEmpty {
                ContentUnavailableView("No matching updates", systemImage: "line.3.horizontal.decrease", description: Text("Try another filter or search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) { ForEach(visible) { item in row(item) } }
                        .frame(maxWidth: 880).frame(maxWidth: .infinity).padding(24)
                }
            }
        }.background(Theme.canvas)
            .background(SpaceContentMarker(name: "attention-inbox"))
            .onChange(of: model.selectedSpace.id) { query = "" }
    }
    private var scope: some View {
        WorkspaceSelect(title: "Inbox scope", selection: Binding(get: { allSpaces }, set: { allSpaces = $0 }), options: [false, true],
            label: { $0 ? "All spaces" : "This space" }, symbol: "square.stack.3d.up", height: 36).frame(width: 152)
            .background(SpaceContentMarker(name: "attention-scope"))
    }
    private var kind: some View {
        WorkspaceSelect(title: "Update type", selection: Binding(get: { filter }, set: { filter = $0 }), options: ["All updates", "Approvals", "Blockers", "Review"],
            label: { $0 }, symbol: "line.3.horizontal.decrease", height: 36).frame(width: 158)
            .background(SpaceContentMarker(name: "attention-filter"))
    }
    private var search: some View {
        WorkspaceSearchField(placeholder: "Search updates", text: $query).frame(minWidth: 140, maxWidth: 280)
            .accessibilityLabel("Search attention updates")
    }
    private func row(_ item: AttentionItem) -> some View {
        let urgent = item.kind != .review
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(item.kind)).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(urgent ? Theme.attention : Theme.action).frame(width: 36, height: 36)
                    .background((urgent ? Theme.attention : Theme.action).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.kind.rawValue).font(.system(size: 10, weight: .semibold)).foregroundStyle(urgent ? Theme.attention : Theme.action)
                    Text(item.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                    if let project = model.project(id: item.projectID) {
                        Text([allSpaces ? model.workspace.spaces.first(where: { $0.id == project.spaceID })?.name : nil, project.name].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text(item.date, style: .relative).font(.system(size: 10)).foregroundStyle(.tertiary).help(item.date.formatted())
            }
            Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            HStack(spacing: 8) {
                Button(actionTitle(item), systemImage: "arrow.up.right") { model.openAttentionItem(item) }
                    .buttonStyle(WorkspaceButtonStyle(kind: .primary, compact: true))
                    .background(SpaceContentMarker(name: "attention-open-" + item.id.uuidString))
                if item.canDismiss {
                    Button("Dismiss") { model.dismissAttentionItem(item) }.buttonStyle(WorkspaceButtonStyle(kind: .quiet, compact: true))
                        .help("Hide this update until the state changes. The ticket and agent are kept.")
                        .background(SpaceContentMarker(name: "attention-dismiss-" + item.id.uuidString))
                }
                Spacer()
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline) }
            .background(SpaceContentMarker(name: "attention-item-" + item.id.uuidString))
    }
    private func actionTitle(_ item: AttentionItem) -> String {
        switch item.kind {
        case .approval: "Review approval"
        case .input: "Respond in chat"
        case .blocked: item.ticketID == nil ? "Open agent" : "Open ticket"
        case .checks: item.ticketID == nil ? "Review checks" : "Open ticket"
        case .review: item.ticketID == nil ? "Review result" : "Review ticket"
        }
    }
    private func symbol(_ kind: AttentionItem.Kind) -> String {
        switch kind {
        case .approval: "hand.raised"
        case .input: "questionmark.bubble"
        case .blocked: "exclamationmark.circle"
        case .checks: "checklist"
        case .review: "doc.text.magnifyingglass"
        }
    }
}
