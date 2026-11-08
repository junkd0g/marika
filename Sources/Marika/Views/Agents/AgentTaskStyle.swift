import MarikaCore
import SwiftUI

extension AgentTaskState {
    var color: Color {
        switch self {
        case .failed: .red
        case .needsApproval: Theme.attention
        case .working: .accentColor
        case .completed: .green
        case .idle, .stopped, .archived: .secondary
        }
    }
}
