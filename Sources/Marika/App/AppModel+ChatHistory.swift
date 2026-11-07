import Foundation
import MarikaCore

struct ChatHistoryFocus: Equatable {
    let requestID = UUID()
    let sessionID: UUID
    let itemID: String
}

private struct ChatHistoryNavigationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension AppModel {
    func searchChatHistory(_ query: String, projectID: UUID?) async throws -> ChatHistoryResults {
        try await store.searchChatHistory(in: workspace, query: query, projectID: projectID,
                                         liveTranscripts: controllers.mapValues(\.items))
    }

    func revealChatHistoryMatch(_ match: ChatHistoryMatch) async throws {
        guard let meta = workspace.sessions.first(where: { $0.id == match.sessionID }), project(for: meta) != nil else {
            throw ChatHistoryNavigationError(message: "This conversation is no longer in your workspace. Search again to refresh the results.")
        }
        await open(meta.id)
        guard controllers[meta.id]?.items.contains(where: { $0.id == match.itemID }) == true else {
            throw ChatHistoryNavigationError(message: "This message could not be opened. Search again, or check Saved Data if its conversation is unreadable.")
        }
        openAgentChat(meta.id)
        chatHistoryFocus = ChatHistoryFocus(sessionID: meta.id, itemID: match.itemID)
    }
}
