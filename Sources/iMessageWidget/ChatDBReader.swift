import Foundation
import SQLite3

/// Reads from Apple's ~/Library/Messages/chat.db.
/// All access is read-only. Opens the database fresh on each poll to avoid locking issues.
class ChatDBReader {
    static let shared = ChatDBReader()

    static let chatDBPath = "\(NSHomeDirectory())/Library/Messages/chat.db"

    // Apple's CoreData reference epoch is Jan 1, 2001 (same as Foundation's timeIntervalSinceReferenceDate).
    // chat.db stores timestamps in nanoseconds since that epoch for macOS 10.13+.
    private static func dateFromChatDB(_ ts: Int64) -> Date {
        let seconds: Double
        if ts > 1_000_000_000_000 {
            seconds = Double(ts) / 1_000_000_000.0
        } else {
            seconds = Double(ts)
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    var isChatDBAccessible: Bool {
        FileManager.default.fileExists(atPath: Self.chatDBPath) &&
        FileManager.default.isReadableFile(atPath: Self.chatDBPath)
    }

    // MARK: - New Unread Messages

    struct RawMessage {
        var guid: String
        var text: String
        var handleId: String      // sender phone/email (raw)
        var chatGuid: String      // chat.guid
        var receivedAt: Date
        var isGroupMessage: Bool
        var participantHandles: [String]
        var groupChatName: String?
    }

    /// Returns all currently unread incoming messages (is_from_me = 0, is_read = 0).
    func fetchUnreadMessages() -> [RawMessage] {
        guard let db = openReadOnly() else { return [] }
        defer { sqlite3_close(db) }

        var results: [RawMessage] = []
        let sql = """
            SELECT
                m.guid,
                COALESCE(m.text, '') AS text,
                h.id AS handle_id,
                c.guid AS chat_guid,
                m.date,
                (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.rowid) AS participant_count,
                c.display_name AS group_name
            FROM message m
            JOIN chat_message_join cmj ON m.rowid = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.rowid
            LEFT JOIN handle h ON m.handle_id = h.rowid
            WHERE m.is_from_me = 0
              AND m.is_read = 0
              AND m.text IS NOT NULL
              AND LENGTH(m.text) > 0
            ORDER BY m.date ASC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let guid       = String(cString: sqlite3_column_text(stmt, 0))
                let text       = String(cString: sqlite3_column_text(stmt, 1))
                let handleId   = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                                 ? String(cString: sqlite3_column_text(stmt, 2)) : "unknown"
                let chatGuid   = String(cString: sqlite3_column_text(stmt, 3))
                let ts         = sqlite3_column_int64(stmt, 4)
                let partCount  = Int(sqlite3_column_int64(stmt, 5))
                let groupName: String? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                                        ? String(cString: sqlite3_column_text(stmt, 6)) : nil
                // Group chats always have `;+;` in their GUID (vs `;-;` for 1-on-1).
                // Fall back to participant count > 1 in case the GUID format differs.
                let isGroup    = chatGuid.contains(";+;") || partCount > 1

                let participants = isGroup ? fetchParticipants(db: db, chatGuid: chatGuid) : []

                results.append(RawMessage(
                    guid: guid,
                    text: text,
                    handleId: handleId,
                    chatGuid: chatGuid,
                    receivedAt: Self.dateFromChatDB(ts),
                    isGroupMessage: isGroup,
                    participantHandles: participants,
                    groupChatName: groupName
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Returns GUIDs of messages (currently in app DB) that have been read.
    func findReadMessages(guids: [String]) -> [String] {
        guard !guids.isEmpty, let db = openReadOnly() else { return [] }
        defer { sqlite3_close(db) }

        let placeholders = guids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT guid FROM message WHERE guid IN (\(placeholders)) AND is_read = 1"
        var stmt: OpaquePointer?
        var read: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (i, g) in guids.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), g, -1, Self.transient)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                read.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        return read
    }

    /// Returns chat GUIDs that have received an outgoing message (reply) since the given date.
    func findRepliedChatsSince(_ date: Date) -> [String] {
        guard let db = openReadOnly() else { return [] }
        defer { sqlite3_close(db) }

        let ts: Int64
        let ref = date.timeIntervalSinceReferenceDate
        ts = Int64(ref * 1_000_000_000)

        let sql = """
            SELECT DISTINCT c.guid
            FROM message m
            JOIN chat_message_join cmj ON m.rowid = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.rowid
            WHERE m.is_from_me = 1 AND m.date > ?
        """
        var stmt: OpaquePointer?
        var chatGuids: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, ts)
            while sqlite3_step(stmt) == SQLITE_ROW {
                chatGuids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        return chatGuids
    }

    /// Returns how many messages the user sent to a handle in the last N hours (for momentum scoring).
    func recentSentMessageCount(handleId: String, withinHours hours: Double) -> Int {
        guard let db = openReadOnly() else { return 0 }
        defer { sqlite3_close(db) }

        let cutoff = Date().addingTimeInterval(-hours * 3600)
        let tsCutoff = Int64(cutoff.timeIntervalSinceReferenceDate * 1_000_000_000)

        let sql = """
            SELECT COUNT(*) FROM message m
            JOIN handle h ON m.handle_id = h.rowid
            WHERE h.id = ? AND m.is_from_me = 1 AND m.date > ?
        """
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, handleId, -1, Self.transient)
            sqlite3_bind_int64(stmt, 2, tsCutoff)
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    /// Median sent message length (in words) for a handle (for content signal: is_long_message).
    func medianSentMessageLength(handleId: String) -> Double {
        guard let db = openReadOnly() else { return 10.0 }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT m.text FROM message m
            JOIN handle h ON m.handle_id = h.rowid
            WHERE h.id = ? AND m.is_from_me = 1 AND m.text IS NOT NULL
            ORDER BY m.date DESC LIMIT 100
        """
        var stmt: OpaquePointer?
        var lengths: [Int] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, handleId, -1, Self.transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = String(cString: sqlite3_column_text(stmt, 0))
                lengths.append(text.split(separator: " ").count)
            }
        }
        sqlite3_finalize(stmt)
        guard !lengths.isEmpty else { return 10.0 }
        let sorted = lengths.sorted()
        return Double(sorted[sorted.count / 2])
    }

    // MARK: - Private helpers

    private func fetchParticipants(db: OpaquePointer, chatGuid: String) -> [String] {
        let sql = """
            SELECT h.id FROM handle h
            JOIN chat_handle_join chj ON h.rowid = chj.handle_id
            JOIN chat c ON chj.chat_id = c.rowid
            WHERE c.guid = ?
        """
        var stmt: OpaquePointer?
        var handles: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, chatGuid, -1, Self.transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                handles.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        return handles
    }

    private func openReadOnly() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(Self.chatDBPath, &db, flags, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)
        return db
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
