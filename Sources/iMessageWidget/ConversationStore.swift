import Foundation
import Combine

/// The single source of truth for the widget's UI state.
/// Updated by the Daemon; observed by SwiftUI views.
@MainActor
class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published var conversations: [Conversation] = []
    @Published var isOnboarded: Bool = false
    @Published var permissionsGranted: PermissionState = .unknown

    struct PermissionState {
        var fullDiskAccess: Bool = false
        var contacts: Bool = false
        var automation: Bool = false

        static let unknown = PermissionState()
    }

    private init() {}

    func update(conversations: [Conversation]) {
        self.conversations = conversations
    }

    /// Ordered queue: High tier by descending score, then Low tier by descending score.
    var orderedConversations: [Conversation] {
        let high = conversations.filter { $0.tier == .high && !$0.isSnoozed }
            .sorted { $0.effectiveScore > $1.effectiveScore }
        let low  = conversations.filter { $0.tier == .low && !$0.isSnoozed }
            .sorted { $0.effectiveScore > $1.effectiveScore }
        return high + low
    }

    /// Chronological: oldest message first, newest at the bottom.
    var chronologicalConversations: [Conversation] {
        conversations.filter { !$0.isSnoozed }
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    /// The highest effective score among conversations beyond index 4 (below the fold).
    var belowFoldScore: Double? {
        let all = orderedConversations
        guard all.count > 5 else { return nil }
        return all[5...].map(\.effectiveScore).max()
    }
}
