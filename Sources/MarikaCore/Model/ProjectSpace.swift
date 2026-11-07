import Foundation

public enum ProjectSpaceColor: String, CaseIterable, Codable, Sendable {
    case blue, violet, teal, amber, rose, graphite

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .blue
    }
}

public struct ProjectSpace: Codable, Equatable, Sendable, Identifiable {
    public static let personalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let symbols = ["square.grid.2x2.fill", "briefcase.fill", "house.fill", "hammer.fill", "sparkles", "leaf.fill", "book.fill", "globe"]
    public static var personal: Self { Self(id: personalID, name: "Personal", color: .blue) }

    public var id: UUID
    public var name: String
    public var color: ProjectSpaceColor
    public var symbol: String
    public var lastProjectID: UUID?

    public init(id: UUID = UUID(), name: String, color: ProjectSpaceColor = .blue,
                symbol: String = "square.grid.2x2.fill", lastProjectID: UUID? = nil) {
        self.id = id
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        self.name = trimmed.isEmpty ? "Untitled space" : trimmed
        self.color = color
        self.symbol = Self.symbols.contains(symbol) ? symbol : Self.symbols[0]
        self.lastProjectID = lastProjectID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? "Untitled space",
                  color: try values.decodeIfPresent(ProjectSpaceColor.self, forKey: .color) ?? .blue,
                  symbol: try values.decodeIfPresent(String.self, forKey: .symbol) ?? Self.symbols[0],
                  lastProjectID: try values.decodeIfPresent(UUID.self, forKey: .lastProjectID))
    }
}

extension Workspace {
    public var selectedSpace: ProjectSpace { spaces.first { $0.id == selectedSpaceID } ?? spaces.first ?? .personal }

    public func projects(in spaceID: UUID) -> [Project] { projects.filter { $0.spaceID == spaceID } }

    public func preferredProject(in spaceID: UUID) -> Project? {
        let available = projects(in: spaceID)
        if let id = spaces.first(where: { $0.id == spaceID })?.lastProjectID,
           let saved = available.first(where: { $0.id == id }) { return saved }
        if let saved = available.first(where: { $0.id == selectedProjectID }) { return saved }
        let ids = Set(available.map(\.id))
        if let recent = sessions.filter({ ids.contains($0.projectID) }).max(by: { $0.updatedAt < $1.updatedAt }),
           let project = available.first(where: { $0.id == recent.projectID }) { return project }
        return available.first
    }

    /// Migration also repairs stale membership without dropping projects or conversations.
    public mutating func normalizeSpaces() {
        var seen = Set<UUID>()
        spaces = spaces.filter { seen.insert($0.id).inserted }
        if spaces.isEmpty { spaces = [.personal] }
        let ids = Set(spaces.map(\.id)), fallback = spaces[0].id
        for index in projects.indices where projects[index].spaceID.map({ !ids.contains($0) }) ?? true {
            projects[index].spaceID = fallback
        }
        for index in spaces.indices {
            if let last = spaces[index].lastProjectID,
               !projects.contains(where: { $0.id == last && $0.spaceID == spaces[index].id }) {
                spaces[index].lastProjectID = nil
            }
        }
        if selectedSpaceID.map({ !ids.contains($0) }) ?? true {
            selectedSpaceID = projects.first(where: { $0.id == selectedProjectID })?.spaceID ?? fallback
        }
        if let selectedProjectID, !projects.contains(where: { $0.id == selectedProjectID && $0.spaceID == selectedSpaceID }) {
            self.selectedProjectID = nil
        }
    }

    public mutating func rememberProject(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id }),
              let index = spaces.firstIndex(where: { $0.id == project.spaceID }) else { return }
        selectedSpaceID = spaces[index].id
        selectedProjectID = id
        spaces[index].lastProjectID = id
    }

    @discardableResult
    public mutating func activateSpace(_ id: UUID) -> Bool {
        guard spaces.contains(where: { $0.id == id }) else { return false }
        let project = preferredProject(in: id)
        selectedSpaceID = id
        selectedProjectID = project?.id
        return true
    }

    @discardableResult
    public mutating func createSpace(name: String, color: ProjectSpaceColor, symbol: String) -> ProjectSpace? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { return nil }
        let space = ProjectSpace(name: name, color: color, symbol: symbol)
        spaces.append(space)
        return space
    }

    @discardableResult
    public mutating func editSpace(_ id: UUID, name: String, color: ProjectSpaceColor, symbol: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, let index = spaces.firstIndex(where: { $0.id == id }) else { return false }
        spaces[index] = ProjectSpace(id: id, name: name, color: color, symbol: symbol, lastProjectID: spaces[index].lastProjectID)
        return true
    }

    @discardableResult
    public mutating func moveProject(_ id: UUID, to spaceID: UUID) -> Bool {
        guard spaces.contains(where: { $0.id == spaceID }),
              let index = projects.firstIndex(where: { $0.id == id }), projects[index].spaceID != spaceID else { return false }
        let old = projects[index].spaceID
        projects[index].spaceID = spaceID
        if let source = spaces.firstIndex(where: { $0.id == old }), spaces[source].lastProjectID == id {
            spaces[source].lastProjectID = projects(in: spaces[source].id).first?.id
        }
        if let destination = spaces.firstIndex(where: { $0.id == spaceID }), spaces[destination].lastProjectID == nil {
            spaces[destination].lastProjectID = id
        }
        if selectedProjectID == id { selectedProjectID = preferredProject(in: selectedSpace.id)?.id }
        return true
    }

    @discardableResult
    public mutating func deleteSpace(_ id: UUID, movingProjectsTo destinationID: UUID) -> Bool {
        guard id != destinationID, spaces.count > 1, spaces.contains(where: { $0.id == id }),
              spaces.contains(where: { $0.id == destinationID }) else { return false }
        let selected = selectedProjectID
        for index in projects.indices where projects[index].spaceID == id { projects[index].spaceID = destinationID }
        spaces.removeAll { $0.id == id }
        if selectedSpaceID == id {
            selectedSpaceID = destinationID
            if let selected { rememberProject(selected) }
            else { selectedProjectID = preferredProject(in: destinationID)?.id }
        }
        return true
    }

    @discardableResult
    public mutating func reorderSpace(_ id: UUID, offset: Int) -> Bool {
        guard let index = spaces.firstIndex(where: { $0.id == id }), spaces.indices.contains(index + offset) else { return false }
        let space = spaces.remove(at: index)
        spaces.insert(space, at: index + offset)
        return true
    }
}
