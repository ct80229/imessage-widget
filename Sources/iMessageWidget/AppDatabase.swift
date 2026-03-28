import Foundation
import SQLite3

/// App-owned SQLite database. Stores contacts, messages, snooze state, no-reply log, and app state.
/// All public methods are safe to call from any thread (serial queue internally).
class AppDatabase {
    static let shared = AppDatabase()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.local.iMessageWidget.appdb", qos: .userInitiated)

    init() {
        let dir = Self.appSupportDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("app.db").path

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            print("[AppDB] Failed to open database at \(path)")
            return
        }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA foreign_keys = ON")
        exec("PRAGMA synchronous = NORMAL")
        runMigrations()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Migrations

    private func runMigrations() {
        exec("""
            CREATE TABLE IF NOT EXISTS contacts (
                handle_id       TEXT PRIMARY KEY,
                display_name    TEXT,
                is_in_address_book INTEGER NOT NULL DEFAULT 0,
                tier            TEXT NOT NULL DEFAULT 'low',
                priority        INTEGER NOT NULL DEFAULT 1,
                sent_message_count INTEGER NOT NULL DEFAULT 0,
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS group_chats (
                group_id        TEXT PRIMARY KEY,
                display_name    TEXT,
                member_handle_ids TEXT NOT NULL DEFAULT '[]',
                tier            TEXT NOT NULL DEFAULT 'low',
                priority        INTEGER NOT NULL DEFAULT 1,
                priority_is_manual INTEGER NOT NULL DEFAULT 0,
                sent_message_count INTEGER NOT NULL DEFAULT 0,
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS messages (
                message_id      TEXT PRIMARY KEY,
                handle_id       TEXT NOT NULL,
                chat_id         TEXT NOT NULL,
                received_at     REAL NOT NULL,
                body_text       TEXT NOT NULL DEFAULT '',
                is_group_message INTEGER NOT NULL DEFAULT 0,
                content_score   REAL NOT NULL DEFAULT 0,
                momentum_score  REAL NOT NULL DEFAULT 0,
                is_question     INTEGER NOT NULL DEFAULT 0,
                is_time_sensitive INTEGER NOT NULL DEFAULT 0,
                is_emotional    INTEGER NOT NULL DEFAULT 0,
                is_conversational_closer INTEGER NOT NULL DEFAULT 0,
                is_long_message INTEGER NOT NULL DEFAULT 0,
                time_score      REAL NOT NULL DEFAULT 0,
                dynamic_score   REAL NOT NULL DEFAULT 0,
                effective_score REAL NOT NULL DEFAULT 0,
                score_last_calculated_at REAL NOT NULL,
                created_at      REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS snooze_states (
                snooze_id       INTEGER PRIMARY KEY AUTOINCREMENT,
                handle_id       TEXT NOT NULL,
                snoozed_at      REAL NOT NULL,
                expires_at      REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS no_reply_log (
                log_id          INTEGER PRIMARY KEY AUTOINCREMENT,
                handle_id       TEXT NOT NULL,
                message_id      TEXT NOT NULL,
                dismissed_at    REAL NOT NULL,
                expires_at      REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS app_state (
                id              INTEGER PRIMARY KEY DEFAULT 1,
                last_chatdb_poll_at   REAL,
                last_score_recalc_at  REAL,
                app_version           TEXT,
                is_onboarded          INTEGER NOT NULL DEFAULT 0
            )
        """)

        exec("INSERT OR IGNORE INTO app_state (id, app_version) VALUES (1, '1.0')")
    }

    // MARK: - App State

    func isOnboarded() -> Bool {
        var result = false
        queue.sync {
            result = scalar("SELECT is_onboarded FROM app_state WHERE id = 1") as? Int64 == 1
        }
        return result
    }

    func markOnboarded() {
        queue.sync { self.exec("UPDATE app_state SET is_onboarded = 1 WHERE id = 1") }
    }

    func lastChatDBPollDate() -> Date? {
        var ts: Double? = nil
        queue.sync {
            ts = scalar("SELECT last_chatdb_poll_at FROM app_state WHERE id = 1") as? Double
        }
        return ts.map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    func updateLastChatDBPoll(_ date: Date) {
        queue.sync {
            self.exec("UPDATE app_state SET last_chatdb_poll_at = \(date.timeIntervalSinceReferenceDate) WHERE id = 1")
        }
    }

    // MARK: - Contacts

    func upsertContact(_ contact: Contact) {
        queue.sync {
            let sql = """
                INSERT INTO contacts
                    (handle_id, display_name, is_in_address_book, tier, priority,
                     sent_message_count, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(handle_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    is_in_address_book = excluded.is_in_address_book,
                    tier = excluded.tier,
                    priority = excluded.priority,
                    sent_message_count = excluded.sent_message_count,
                    updated_at = excluded.updated_at
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, contact.handleId, -1, Self.transient)
                Self.bindOptionalText(stmt, 2, contact.displayName)
                sqlite3_bind_int64(stmt, 3, contact.isInAddressBook ? 1 : 0)
                sqlite3_bind_text(stmt, 4, contact.tier.rawValue, -1, Self.transient)
                sqlite3_bind_int64(stmt, 5, Int64(contact.priority))
                sqlite3_bind_int64(stmt, 6, Int64(contact.sentMessageCount))
                sqlite3_bind_double(stmt, 7, contact.createdAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 8, contact.updatedAt.timeIntervalSinceReferenceDate)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func fetchContact(handleId: String) -> Contact? {
        var result: Contact? = nil
        queue.sync {
            let sql = "SELECT * FROM contacts WHERE handle_id = ?"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, handleId, -1, Self.transient)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    result = Self.contactFromRow(stmt)
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    func fetchAllContacts() -> [Contact] {
        var results: [Contact] = []
        queue.sync {
            let sql = "SELECT * FROM contacts"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(Self.contactFromRow(stmt))
                }
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    func updateContactTier(_ handleId: String, tier: Contact.Tier) {
        queue.sync {
            self.exec("UPDATE contacts SET tier = '\(tier.rawValue)', updated_at = \(Date().timeIntervalSinceReferenceDate) WHERE handle_id = '\(handleId)'")
        }
    }

    func updateContactPriority(_ handleId: String, priority: Int) {
        queue.sync {
            self.exec("UPDATE contacts SET priority = \(priority), updated_at = \(Date().timeIntervalSinceReferenceDate) WHERE handle_id = '\(handleId)'")
        }
    }

    func deleteContact(_ handleId: String) {
        queue.sync {
            self.exec("DELETE FROM contacts WHERE handle_id = '\(handleId)'")
            self.exec("DELETE FROM messages WHERE handle_id = '\(handleId)'")
            self.exec("DELETE FROM snooze_states WHERE handle_id = '\(handleId)'")
            self.exec("DELETE FROM no_reply_log WHERE handle_id = '\(handleId)'")
        }
    }

    // MARK: - Group Chats

    func upsertGroupChat(_ gc: GroupChat) {
        queue.sync {
            let memberJson = (try? JSONEncoder().encode(gc.memberHandleIds)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let sql = """
                INSERT INTO group_chats
                    (group_id, display_name, member_handle_ids, tier, priority,
                     priority_is_manual, sent_message_count, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(group_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    member_handle_ids = excluded.member_handle_ids,
                    tier = excluded.tier,
                    priority = excluded.priority,
                    priority_is_manual = excluded.priority_is_manual,
                    sent_message_count = excluded.sent_message_count,
                    updated_at = excluded.updated_at
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, gc.groupId, -1, Self.transient)
                Self.bindOptionalText(stmt, 2, gc.displayName)
                sqlite3_bind_text(stmt, 3, memberJson, -1, Self.transient)
                sqlite3_bind_text(stmt, 4, gc.tier.rawValue, -1, Self.transient)
                sqlite3_bind_int64(stmt, 5, Int64(gc.priority))
                sqlite3_bind_int64(stmt, 6, gc.priorityIsManual ? 1 : 0)
                sqlite3_bind_int64(stmt, 7, Int64(gc.sentMessageCount))
                sqlite3_bind_double(stmt, 8, gc.createdAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 9, gc.updatedAt.timeIntervalSinceReferenceDate)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func fetchGroupChat(groupId: String) -> GroupChat? {
        var result: GroupChat? = nil
        queue.sync {
            let sql = "SELECT * FROM group_chats WHERE group_id = ?"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, groupId, -1, Self.transient)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    result = Self.groupChatFromRow(stmt)
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    func updateGroupChatTier(_ groupId: String, tier: Contact.Tier) {
        queue.sync {
            self.exec("UPDATE group_chats SET tier = '\(tier.rawValue)', updated_at = \(Date().timeIntervalSinceReferenceDate) WHERE group_id = '\(groupId)'")
        }
    }

    func updateGroupChatPriority(_ groupId: String, priority: Int) {
        queue.sync {
            self.exec("UPDATE group_chats SET priority = \(priority), priority_is_manual = 1, updated_at = \(Date().timeIntervalSinceReferenceDate) WHERE group_id = '\(groupId)'")
        }
    }

    func deleteGroupChat(_ groupId: String) {
        queue.sync {
            self.exec("DELETE FROM group_chats WHERE group_id = '\(groupId)'")
            self.exec("DELETE FROM messages WHERE chat_id = '\(groupId)'")
            self.exec("DELETE FROM snooze_states WHERE handle_id = '\(groupId)'")
        }
    }

    // MARK: - Messages

    func insertMessage(_ msg: AppMessage) {
        queue.sync {
            let sql = """
                INSERT OR IGNORE INTO messages
                    (message_id, handle_id, chat_id, received_at, body_text,
                     is_group_message, content_score, momentum_score,
                     is_question, is_time_sensitive, is_emotional,
                     is_conversational_closer, is_long_message,
                     time_score, dynamic_score, effective_score,
                     score_last_calculated_at, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt,  1, msg.messageId, -1, Self.transient)
                sqlite3_bind_text(stmt,  2, msg.handleId,  -1, Self.transient)
                sqlite3_bind_text(stmt,  3, msg.chatId,    -1, Self.transient)
                sqlite3_bind_double(stmt,4, msg.receivedAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_text(stmt,  5, msg.bodyText,  -1, Self.transient)
                sqlite3_bind_int64(stmt, 6, msg.isGroupMessage ? 1 : 0)
                sqlite3_bind_double(stmt,7, msg.contentScore)
                sqlite3_bind_double(stmt,8, msg.momentumScore)
                sqlite3_bind_int64(stmt, 9, msg.isQuestion ? 1 : 0)
                sqlite3_bind_int64(stmt,10, msg.isTimeSensitive ? 1 : 0)
                sqlite3_bind_int64(stmt,11, msg.isEmotional ? 1 : 0)
                sqlite3_bind_int64(stmt,12, msg.isConversationalCloser ? 1 : 0)
                sqlite3_bind_int64(stmt,13, msg.isLongMessage ? 1 : 0)
                sqlite3_bind_double(stmt,14, msg.timeScore)
                sqlite3_bind_double(stmt,15, msg.dynamicScore)
                sqlite3_bind_double(stmt,16, msg.effectiveScore)
                sqlite3_bind_double(stmt,17, msg.scoreLastCalculatedAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt,18, msg.createdAt.timeIntervalSinceReferenceDate)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func updateMessageScores(_ messageId: String, timeScore: Double, dynamicScore: Double, effectiveScore: Double) {
        queue.sync {
            let now = Date().timeIntervalSinceReferenceDate
            self.exec("""
                UPDATE messages SET
                    time_score = \(timeScore),
                    dynamic_score = \(dynamicScore),
                    effective_score = \(effectiveScore),
                    score_last_calculated_at = \(now)
                WHERE message_id = '\(messageId)'
            """)
        }
    }

    func deleteMessage(_ messageId: String) {
        queue.sync {
            self.exec("DELETE FROM messages WHERE message_id = '\(messageId)'")
        }
    }

    func deleteAllMessagesForHandle(_ handleId: String) {
        queue.sync {
            self.exec("DELETE FROM messages WHERE handle_id = '\(handleId)'")
        }
    }

    func fetchAllMessages() -> [AppMessage] {
        var results: [AppMessage] = []
        queue.sync {
            let sql = "SELECT * FROM messages ORDER BY received_at DESC"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(Self.messageFromRow(stmt))
                }
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    func fetchMessages(for handleId: String) -> [AppMessage] {
        var results: [AppMessage] = []
        queue.sync {
            let sql = "SELECT * FROM messages WHERE handle_id = ? OR chat_id = ? ORDER BY received_at DESC"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, handleId, -1, Self.transient)
                sqlite3_bind_text(stmt, 2, handleId, -1, Self.transient)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(Self.messageFromRow(stmt))
                }
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    func isMessageDismissed(_ messageId: String) -> Bool {
        var result = false
        queue.sync {
            let n = self.scalar("SELECT COUNT(*) FROM no_reply_log WHERE message_id = '\(messageId)'") as? Int64 ?? 0
            result = n > 0
        }
        return result
    }

    // MARK: - Snooze

    func snoozeConversation(_ handleId: String, duration: TimeInterval = 2 * 3600) {
        queue.sync {
            let now = Date()
            let exp = now.addingTimeInterval(duration)
            self.exec("DELETE FROM snooze_states WHERE handle_id = '\(handleId)'")
            self.exec("""
                INSERT INTO snooze_states (handle_id, snoozed_at, expires_at)
                VALUES ('\(handleId)', \(now.timeIntervalSinceReferenceDate), \(exp.timeIntervalSinceReferenceDate))
            """)
        }
    }

    func unsnoozeConversation(_ handleId: String) {
        queue.sync {
            self.exec("DELETE FROM snooze_states WHERE handle_id = '\(handleId)'")
        }
    }

    func fetchAllSnoozeStates() -> [SnoozeState] {
        var results: [SnoozeState] = []
        queue.sync {
            let sql = "SELECT snooze_id, handle_id, snoozed_at, expires_at FROM snooze_states"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let s = SnoozeState(
                        snoozeId: sqlite3_column_int64(stmt, 0),
                        handleId: String(cString: sqlite3_column_text(stmt, 1)),
                        snoozedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
                        expiresAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
                    )
                    results.append(s)
                }
            }
            sqlite3_finalize(stmt)
        }
        return results
    }

    func deleteExpiredSnoozeStates() {
        queue.sync {
            let now = Date().timeIntervalSinceReferenceDate
            self.exec("DELETE FROM snooze_states WHERE expires_at < \(now)")
        }
    }

    func isConversationSnoozed(_ handleId: String) -> (Bool, Date?) {
        var snoozed = false
        var exp: Date? = nil
        queue.sync {
            let now = Date().timeIntervalSinceReferenceDate
            let sql = "SELECT expires_at FROM snooze_states WHERE handle_id = ? AND expires_at > ?"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, handleId, -1, Self.transient)
                sqlite3_bind_double(stmt, 2, now)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    snoozed = true
                    exp = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
        }
        return (snoozed, exp)
    }

    // MARK: - No Reply Log

    func markNoReplyNeeded(handleId: String, messageId: String) {
        queue.sync {
            let now = Date()
            let exp = now.addingTimeInterval(30 * 24 * 3600)
            self.exec("""
                INSERT INTO no_reply_log (handle_id, message_id, dismissed_at, expires_at)
                VALUES ('\(handleId)', '\(messageId)', \(now.timeIntervalSinceReferenceDate), \(exp.timeIntervalSinceReferenceDate))
            """)
            self.exec("DELETE FROM messages WHERE message_id = '\(messageId)'")
        }
    }

    func purgeExpiredNoReplyLogs() {
        queue.sync {
            let now = Date().timeIntervalSinceReferenceDate
            self.exec("DELETE FROM no_reply_log WHERE expires_at < \(now)")
        }
    }

    // MARK: - Recent Sent Messages (for momentum scoring)

    /// Returns timestamps of the user's outgoing messages to the given handle within the last N hours.
    func recentUserMessageTimestamps(handleId: String, withinHours hours: Double) -> [Date] {
        // We look at message history in chat.db directly via ChatDBReader,
        // so this just returns empty here – momentum is computed during ingest.
        return []
    }

    // MARK: - Private helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let e = errMsg { print("[AppDB] SQL error: \(String(cString: e))") }
        }
    }

    private func scalar(_ sql: String) -> Any? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW
        else { return nil }
        let type = sqlite3_column_type(stmt, 0)
        switch type {
        case SQLITE_INTEGER: return sqlite3_column_int64(stmt, 0)
        case SQLITE_FLOAT:   return sqlite3_column_double(stmt, 0)
        case SQLITE_TEXT:    return String(cString: sqlite3_column_text(stmt, 0))
        default:             return nil
        }
    }

    private static func bindOptionalText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, idx, v, -1, transient)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private static func contactFromRow(_ stmt: OpaquePointer?) -> Contact {
        let handleId = String(cString: sqlite3_column_text(stmt, 0))
        let displayName: String? = sqlite3_column_type(stmt, 1) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 1)) : nil
        let isInAddrBook = sqlite3_column_int64(stmt, 2) == 1
        let tierStr = String(cString: sqlite3_column_text(stmt, 3))
        let priority = Int(sqlite3_column_int64(stmt, 4))
        let sentCount = Int(sqlite3_column_int64(stmt, 5))
        let createdAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6))
        let updatedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7))
        return Contact(
            handleId: handleId, displayName: displayName,
            isInAddressBook: isInAddrBook,
            tier: Contact.Tier(rawValue: tierStr) ?? .low,
            priority: priority,
            sentMessageCount: sentCount,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    private static func groupChatFromRow(_ stmt: OpaquePointer?) -> GroupChat {
        let groupId   = String(cString: sqlite3_column_text(stmt, 0))
        let displayName: String? = sqlite3_column_type(stmt, 1) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 1)) : nil
        let memberJson = String(cString: sqlite3_column_text(stmt, 2))
        let members = (try? JSONDecoder().decode([String].self, from: Data(memberJson.utf8))) ?? []
        let tierStr  = String(cString: sqlite3_column_text(stmt, 3))
        let priority = Int(sqlite3_column_int64(stmt, 4))
        let isManual = sqlite3_column_int64(stmt, 5) == 1
        let sentCount = Int(sqlite3_column_int64(stmt, 6))
        let createdAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7))
        let updatedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8))
        return GroupChat(
            groupId: groupId, displayName: displayName,
            memberHandleIds: members,
            tier: Contact.Tier(rawValue: tierStr) ?? .low,
            priority: priority, priorityIsManual: isManual,
            sentMessageCount: sentCount,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    private static func messageFromRow(_ stmt: OpaquePointer?) -> AppMessage {
        AppMessage(
            messageId:    String(cString: sqlite3_column_text(stmt, 0)),
            handleId:     String(cString: sqlite3_column_text(stmt, 1)),
            chatId:       String(cString: sqlite3_column_text(stmt, 2)),
            receivedAt:   Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
            bodyText:     String(cString: sqlite3_column_text(stmt, 4)),
            isGroupMessage: sqlite3_column_int64(stmt, 5) == 1,
            contentScore:   sqlite3_column_double(stmt, 6),
            momentumScore:  sqlite3_column_double(stmt, 7),
            isQuestion:    sqlite3_column_int64(stmt, 8) == 1,
            isTimeSensitive: sqlite3_column_int64(stmt, 9) == 1,
            isEmotional:   sqlite3_column_int64(stmt, 10) == 1,
            isConversationalCloser: sqlite3_column_int64(stmt, 11) == 1,
            isLongMessage: sqlite3_column_int64(stmt, 12) == 1,
            timeScore:     sqlite3_column_double(stmt, 13),
            dynamicScore:  sqlite3_column_double(stmt, 14),
            effectiveScore: sqlite3_column_double(stmt, 15),
            scoreLastCalculatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 16)),
            createdAt:     Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 17))
        )
    }

    private static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("iMessageWidget", isDirectory: true)
    }
}
