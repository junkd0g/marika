import Foundation

public struct DesignColorToken: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var color: DesignColor
    public init(name: String, color: DesignColor) { self.name = name; self.color = color.clamped }
}
public struct DesignTypeToken: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var size: Double
    public var weight: DesignFontWeight?
    public init(name: String, size: Double, weight: DesignFontWeight? = nil) { self.name = name; self.size = size; self.weight = weight }
}
public struct DesignSpacingToken: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var value: Double
    public init(name: String, value: Double) { self.name = name; self.value = value }
}
public struct DesignAutoLayout: Codable, Hashable, Sendable {
    public enum Axis: String, Codable, CaseIterable, Sendable { case row, column }
    public var axis: Axis
    public var gap: Double
    public var padding: Double
    public var spacingTokenID: UUID?
    public init(axis: Axis, gap: Double = 16, padding: Double = 16, spacingTokenID: UUID? = nil) {
        self.axis = axis; self.gap = gap; self.padding = padding; self.spacingTokenID = spacingTokenID
    }
}
public struct DesignReusableVariant: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var clip: DesignReusableClip
}
public struct DesignReusableClip: Codable, Hashable, Sendable {
    public var nodes: [DesignNode]
    public var connections: [DesignConnection]
}
public struct DesignReusableComponent: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var variants: [DesignReusableVariant]
}
public struct DesignReusableInstance: Codable, Hashable, Sendable {
    public var componentID: UUID
    public var variantID: UUID
}
public struct DesignSystem: Codable, Hashable, Sendable {
    public var colors: [DesignColorToken] = []
    public var typography: [DesignTypeToken] = []
    public var spacing: [DesignSpacingToken] = []
    public var components: [DesignReusableComponent] = []
    public init() {}
}

extension DesignDocument {
    public mutating func bindColor(_ tokenID: UUID?, to ids: Set<UUID>) {
        let token = designSystem?.colors.first { $0.id == tokenID }
        for index in nodes.indices where ids.contains(nodes[index].id) && !nodes[index].isLocked {
            nodes[index].colorTokenID = token?.id
            if let token { nodes[index].fill = token.color }
        }
    }
    public mutating func bindTypography(_ tokenID: UUID?, to ids: Set<UUID>) {
        let token = designSystem?.typography.first { $0.id == tokenID }
        for index in nodes.indices where ids.contains(nodes[index].id) && !nodes[index].isLocked {
            nodes[index].typeTokenID = token?.id
            if let token { nodes[index].fontSize = token.size; nodes[index].fontWeight = token.weight }
        }
    }
    public mutating func updateColorToken(_ token: DesignColorToken) {
        if designSystem == nil { designSystem = DesignSystem() }
        if let index = designSystem?.colors.firstIndex(where: { $0.id == token.id }) { designSystem?.colors[index] = token }
        else { designSystem?.colors.append(token) }
        bindColor(token.id, to: Set(nodes.filter { $0.colorTokenID == token.id }.map(\.id)))
    }
    public mutating func updateTypeToken(_ token: DesignTypeToken) {
        if designSystem == nil { designSystem = DesignSystem() }
        if let index = designSystem?.typography.firstIndex(where: { $0.id == token.id }) { designSystem?.typography[index] = token }
        else { designSystem?.typography.append(token) }
        bindTypography(token.id, to: Set(nodes.filter { $0.typeTokenID == token.id }.map(\.id)))
    }
    public mutating func configureLayout(_ id: UUID, configuration: DesignAutoLayout?) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id && $0.kind == .frame && !$0.isLocked }) else { throw DesignToolError("Select an unlocked frame.") }
        let children = nodes.filter { parents[$0.id] == id }
        guard children.allSatisfy({ !$0.isLocked && $0.rotation == nil }) else { throw DesignToolError("Unlock and straighten the frame's children before arranging them.") }
        nodes[index].autoLayout = configuration
        for index in nodes.indices where children.contains(where: { $0.id == nodes[index].id }) {
            nodes[index].layoutParentID = configuration == nil ? nil : id
        }
        normalizeDesignSystem()
    }
    mutating func normalizeDesignSystem() {
        let ids = Set(nodes.map(\.id))
        for index in nodes.indices {
            if let instance = nodes[index].reusableInstance,
               designSystem?.components.contains(where: { $0.id == instance.componentID }) != true { nodes[index].reusableInstance = nil }
            if let parent = nodes[index].layoutParentID, !ids.contains(parent) { nodes[index].layoutParentID = nil }
            if let token = nodes[index].colorTokenID, designSystem?.colors.contains(where: { $0.id == token }) != true { nodes[index].colorTokenID = nil }
            if let token = nodes[index].typeTokenID, designSystem?.typography.contains(where: { $0.id == token }) != true { nodes[index].typeTokenID = nil }
        }
        for id in nodes.reversed().filter({ $0.autoLayout != nil && !$0.isLocked }).map(\.id) { reflow(id) }
    }
    private mutating func reflow(_ id: UUID) {
        guard let frameIndex = nodes.firstIndex(where: { $0.id == id }), let config = nodes[frameIndex].autoLayout else { return }
        let children = nodes.filter { $0.layoutParentID == id && !$0.isHidden }
        guard !children.isEmpty, children.allSatisfy({ !$0.isLocked && $0.rotation == nil }) else { return }
        let padding = min(512, max(0, config.padding.isFinite ? config.padding : 16))
        let token = designSystem?.spacing.first { $0.id == config.spacingTokenID }?.value ?? config.gap
        let gap = min(512, max(0, token.isFinite ? token : 16))
        let frame = nodes[frameIndex]
        var cursor = padding, cross = 0.0
        for child in children {
            let target = CGPoint(x: frame.x + (config.axis == .row ? cursor : padding), y: frame.y + (config.axis == .column ? cursor : padding))
            let carried = carried(by: [child.id])
            let dx = target.x - child.x, dy = target.y - child.y
            for index in nodes.indices where carried.contains(nodes[index].id) { nodes[index].x += dx; nodes[index].y += dy }
            cursor += (config.axis == .row ? child.width : child.height) + gap
            cross = max(cross, config.axis == .row ? child.height : child.width)
        }
        nodes[frameIndex].width = min(20_000, max(8, config.axis == .row ? cursor - gap + padding : cross + padding * 2))
        nodes[frameIndex].height = min(20_000, max(8, config.axis == .column ? cursor - gap + padding : cross + padding * 2))
    }
}

extension DesignDocument {
    @discardableResult public mutating func saveReusableComponent(name: String, variant: String, selection: Set<UUID>, componentID: UUID? = nil) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), variant = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = clip(carried(by: selection))
        guard !name.isEmpty, name.count <= 80, !variant.isEmpty, variant.count <= 60, !clip.nodes.isEmpty, clip.nodes.count <= 100 else {
            throw DesignToolError("Name the component and variant, and select between 1 and 100 layers.")
        }
        if designSystem == nil { designSystem = DesignSystem() }
        let entry = DesignReusableVariant(name: variant, clip: DesignReusableClip(nodes: clip.nodes.map { var node = $0; node.reusableInstance = nil; node.importOrigin = nil; return node }, connections: clip.connections))
        if let componentID, let index = designSystem?.components.firstIndex(where: { $0.id == componentID }) {
            guard (designSystem?.components[index].variants.count ?? 0) < 20 else { throw DesignToolError("Keep up to 20 variants per component.") }
            designSystem?.components[index].variants.append(entry)
            return componentID
        }
        guard (designSystem?.components.count ?? 0) < 50 else { throw DesignToolError("Keep up to 50 components in this design system.") }
        let component = DesignReusableComponent(name: name, variants: [entry])
        designSystem?.components.append(component)
        return component.id
    }
    @discardableResult public mutating func insertReusableComponent(_ componentID: UUID, variantID: UUID, at point: CGPoint) throws -> UUID {
        guard let component = designSystem?.components.first(where: { $0.id == componentID }),
              let variant = component.variants.first(where: { $0.id == variantID }),
              let bounds = variant.clip.nodes.map(\.bounds).reduce(nil as CGRect?, { partial, box in partial.map { $0.union(box) } ?? box }),
              nodes.count + variant.clip.nodes.count + 1 <= 500 else { throw DesignToolError("This component is unavailable or the canvas is full.") }
        let wrapper = add(.frame, in: CGRect(x: point.x, y: point.y, width: bounds.width, height: bounds.height))
        update([wrapper]) { $0.name = component.name + " · " + variant.name; $0.text = ""; $0.fill = DesignColor(1, 1, 1, 0); $0.reusableInstance = DesignReusableInstance(componentID: componentID, variantID: variantID) }
        appendComponent(variant.clip, wrapper: wrapper, delta: CGSize(width: point.x - bounds.minX, height: point.y - bounds.minY))
        return wrapper
    }
    public mutating func switchComponentVariant(_ wrapper: UUID, variantID: UUID) throws {
        guard let old = node(wrapper), let instance = old.reusableInstance, !old.isLocked else { throw DesignToolError("Select an unlocked component instance.") }
        let held = carried(by: [wrapper])
        guard nodes.filter({ held.contains($0.id) }).allSatisfy({ !$0.isLocked }) else { throw DesignToolError("Unlock this instance's contents before replacing its variant.") }
        guard let component = designSystem?.components.first(where: { $0.id == instance.componentID }),
              let variant = component.variants.first(where: { $0.id == variantID }),
              let bounds = variant.clip.nodes.map(\.bounds).reduce(nil as CGRect?, { partial, box in partial.map { $0.union(box) } ?? box }),
              nodes.count - held.count + variant.clip.nodes.count + 1 <= 500 else { throw DesignToolError("This variant is unavailable or the canvas is full.") }
        var draft = self
        draft.remove(held.subtracting([wrapper]))
        draft.update([wrapper]) { $0.name = component.name + " · " + variant.name; $0.width = bounds.width; $0.height = bounds.height; $0.reusableInstance?.variantID = variantID }
        draft.appendComponent(variant.clip, wrapper: wrapper, delta: CGSize(width: old.x - bounds.minX, height: old.y - bounds.minY))
        self = draft
    }
    public mutating func replaceReusableVariant(componentID: UUID, variantID: UUID, selection: Set<UUID>) throws {
        guard let index = designSystem?.components.firstIndex(where: { $0.id == componentID }),
              let variant = designSystem?.components[index].variants.firstIndex(where: { $0.id == variantID }) else { throw DesignToolError("Component variant unavailable.") }
        let source = clip(carried(by: selection))
        guard !source.nodes.isEmpty, source.nodes.count <= 100 else { throw DesignToolError("Select 1–100 layers for this variant.") }
        designSystem?.components[index].variants[variant].clip = DesignReusableClip(nodes: source.nodes.map { var node = $0; node.reusableInstance = nil; node.importOrigin = nil; return node }, connections: source.connections)
    }
    @discardableResult public mutating func refreshReusableInstances(componentID: UUID, variantID: UUID) throws -> Int {
        let instances = nodes.filter { $0.reusableInstance == DesignReusableInstance(componentID: componentID, variantID: variantID) }
        var updated = 0
        for instance in instances where !instance.isLocked {
            let held = carried(by: [instance.id])
            guard nodes.filter({ held.contains($0.id) }).allSatisfy({ !$0.isLocked }) else { continue }
            try switchComponentVariant(instance.id, variantID: variantID); updated += 1
        }
        return updated
    }
    private mutating func appendComponent(_ clip: DesignReusableClip, wrapper: UUID, delta: CGSize) {
        let ids = Dictionary(uniqueKeysWithValues: clip.nodes.map { ($0.id, UUID()) })
        var source = DesignDocument(); source.nodes = clip.nodes
        let parents = source.parents
        nodes += clip.nodes.map { node in
            var copy = node; copy.id = ids[node.id]!; copy.x += delta.width; copy.y += delta.height; copy.isLocked = false
            copy.layoutParentID = parents[node.id].flatMap { ids[$0] } ?? wrapper
            return copy
        }
        let edges = clip.connections.compactMap { edge -> DesignConnection? in
            guard let from = ids[edge.from], let to = ids[edge.to] else { return nil }
            var copy = edge; copy.id = UUID(); copy.from = from; copy.to = to; return copy
        }
        if !edges.isEmpty { connections = (connections ?? []) + edges }
    }
}
