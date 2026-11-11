import AppKit
import MarikaCore
import SwiftUI

struct DesignComponentLibrary: View {
    let insert: (DesignComponent) -> Void
    @State private var search = ""

    private var components: [DesignComponent] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return DesignComponent.allCases.filter {
            query.isEmpty || ($0.title + " " + $0.summary + " " + $0.group).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Engineering components").font(.headline)
                Text("Click to add, or drag onto the canvas.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Find a component", text: $search)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Find a component")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(["Compute", "Data", "Clients & network"], id: \.self) { group in
                        let items = components.filter { $0.group == group }
                        if !items.isEmpty {
                            Text(group.uppercased()).font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary).padding(.top, 6)
                            ForEach(items, id: \.self) { component in
                                Button { insert(component) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: component.symbol).font(.system(size: 19))
                                            .foregroundStyle(component.accent.color).frame(width: 32, height: 36)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(component.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                                            Text(component.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onDrag { NSItemProvider(object: (Self.dragPrefix + component.rawValue) as NSString) }
                                .help("Add \(component.title), or drag it onto the canvas")
                                #if DEBUG
                                .background(DebugViewMarker(name: "design-component-" + component.rawValue))
                                #endif
                            }
                        }
                    }
                    if components.isEmpty {
                        Text("No matching components").foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                }
            }
        }
        .padding(16).frame(width: 370, height: 460)
        #if DEBUG
        .background(DebugViewMarker(name: "design-component-library"))
        #endif
    }

    static let dragPrefix = "marika-design-component:"
}
