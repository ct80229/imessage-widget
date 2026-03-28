import Foundation

// MARK: - Contact

struct Contact: Codable, Identifiable {
    var id: String { handleId }
    var handleId: String
    var displayName: String?
    var isInAddressBook: Bool
    var tier: Tier
    var priority: Int  // 1–5
    var sentMessageCount: Int
    var createdAt: Date
    var updatedAt: Date

    enum Tier: String, Codable, CaseIterable {
        case high = "high"
        case low  = "low"
    }

    var priorityAddend: Double { (Double(priority) / 5.0) * 25.0 }

    static func defaultContact(handleId: String, displayName: String? = nil) -> Contact {
        Contact(
            handleId: handleId,
            displayName: displayName,
            isInAddressBook: displayName != nil,
            tier: .low,
            priority: 1,
            sentMessageCount: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

// MARK: - GroupChat

struct GroupChat: Codable, Identifiable {
    var id: String { groupId }
    var groupId: String          // chat.guid from chat.db
    var displayName: String?
    var memberHandleIds: [String]
    var tier: Contact.Tier
    var priority: Int            // 1–5
    var priorityIsManual: Bool
    var sentMessageCount: Int
    var createdAt: Date
    var updatedAt: Date

    var priorityAddend: Double { (Double(priority) / 5.0) * 25.0 }
}

// MARK: - AppMessage (stored in app DB)

struct AppMessage: Codable, Identifiable {
    var id: String { messageId }
    var messageId: String        // message.guid from chat.db
    var handleId: String         // sender handle
    var chatId: String           // chat.guid
    var receivedAt: Date
    var bodyText: String
    var isGroupMessage: Bool

    // Content signals (computed once on ingest)
    var contentScore: Double
    var momentumScore: Double
    var isQuestion: Bool
    var isTimeSensitive: Bool
    var isEmotional: Bool
    var isConversationalCloser: Bool
    var isLongMessage: Bool

    // Scores (updated each cycle)
    var timeScore: Double
    var dynamicScore: Double
    var effectiveScore: Double
    var scoreLastCalculatedAt: Date

    var createdAt: Date
}

// MARK: - Conversation (derived at render time, never stored)

struct Conversation: Identifiable {
    var id: String { contactOrGroupId }

    /// For 1-on-1: the sender handleId. For group chats: the chat GUID.
    var contactOrGroupId: String
    var displayName: String
    var tier: Contact.Tier
    var effectiveScore: Double
    var previewText: String
    var unreadCount: Int
    var isSnoozed: Bool
    var snoozeExpiresAt: Date?
    var isGroupChat: Bool
    var receivedAt: Date          // most recent message time
    var drivingMessageId: String  // message with highest effectiveScore
    var chatId: String

    enum HeatLevel { case cool, amber, red }

    var heatLevel: HeatLevel {
        switch effectiveScore {
        case ..<31:  return .cool
        case ..<61:  return .amber
        default:     return .red
        }
    }
}

// MARK: - SnoozeState

struct SnoozeState: Codable {
    var snoozeId: Int64
    var handleId: String   // contactOrGroupId
    var snoozedAt: Date
    var expiresAt: Date
}

// MARK: - NoReplyLog

struct NoReplyLog: Codable {
    var logId: Int64
    var handleId: String
    var messageId: String
    var dismissedAt: Date
    var expiresAt: Date
}

// MARK: - ContentSignals (ephemeral, used during ingest)

struct ContentSignals {
    var isQuestion: Bool            = false
    var isTimeSensitive: Bool       = false
    var isEmotional: Bool           = false
    var isConversationalCloser: Bool = false
    var isLongMessage: Bool         = false
    var contentScore: Double        = 0
}
