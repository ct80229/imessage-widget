import Foundation

/// Background daemon: polls chat.db, scores messages, manages snooze expiry, builds Conversations.
/// Runs within the main app process using Swift concurrency.
@MainActor
class Daemon {
    static let shared = Daemon()

    private let db      = AppDatabase.shared
    private let reader  = ChatDBReader.shared
    private let store   = ConversationStore.shared
    private let detector = ContentSignalDetector()

    private var pollTask:    Task<Void, Never>?
    private var scoringTask: Task<Void, Never>?
    private var snoozeTask:  Task<Void, Never>?
    private var dbWatcher:   DispatchSourceFileSystemObject?

    // Track which chat GUIDs we've dismissed messages for (to avoid re-ingesting)
    private var knownMessageIds: Set<String> = []

    func start() {
        startPolling()
        startFileWatcher()
        startScoring()
        startSnoozeWatcher()
        // Rebuild conversations immediately
        Task { await self.rebuildConversations() }
    }

    func stop() {
        pollTask?.cancel()
        scoringTask?.cancel()
        snoozeTask?.cancel()
        dbWatcher?.cancel()
        dbWatcher = nil
    }

    // MARK: - File watcher (instant notification on chat.db changes)

    private func startFileWatcher() {
        let fd = open(ChatDBReader.chatDBPath, O_EVTONLY)
        guard fd != -1 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: DispatchQueue.global(qos: .userInteractive)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in await self?.pollChatDB() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dbWatcher = source
    }

    // MARK: - Polling Loop (fallback, every 10 seconds)

    private func startPolling() {
        pollTask = Task {
            // Initialize known IDs from existing DB messages
            let existing = db.fetchAllMessages()
            knownMessageIds = Set(existing.map(\.messageId))

            while !Task.isCancelled {
                await pollChatDB()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func pollChatDB() async {
        guard reader.isChatDBAccessible else { return }

        // 1. Fetch all currently unread messages from chat.db
        let rawMessages = reader.fetchUnreadMessages()
        let chatDBGuids = Set(rawMessages.map(\.guid))

        // 2. Find new messages not yet in our DB
        let newMessages = rawMessages.filter { !knownMessageIds.contains($0.guid) }

        for raw in newMessages {
            await ingestMessage(raw)
            knownMessageIds.insert(raw.guid)
        }

        // 3. Find messages we're tracking that are now read (or replied to from another device)
        let trackedIds = Array(knownMessageIds)
        if !trackedIds.isEmpty {
            let readGuids = Set(reader.findReadMessages(guids: trackedIds))
            // Also check chat GUIDs where outgoing messages have been sent
            let repliedChats = Set(reader.findRepliedChatsSince(
                db.lastChatDBPollDate() ?? Date().addingTimeInterval(-30)
            ))

            var toRemove: [String] = []
            for msg in db.fetchAllMessages() {
                if readGuids.contains(msg.messageId) {
                    toRemove.append(msg.messageId)
                } else if repliedChats.contains(msg.chatId) {
                    toRemove.append(msg.messageId)
                } else if !chatDBGuids.contains(msg.messageId) {
                    // Message no longer in chat.db's unread set → was read
                    toRemove.append(msg.messageId)
                }
            }

            for id in toRemove {
                db.deleteMessage(id)
                knownMessageIds.remove(id)
            }
        }

        db.updateLastChatDBPoll(Date())
        await rebuildConversations()
    }

    private func ingestMessage(_ raw: ChatDBReader.RawMessage) async {
        // Skip if dismissed (no-reply-needed)
        if db.isMessageDismissed(raw.guid) { return }

        // Resolve/create contact or group chat
        let priorityAddend: Double
        let isGroup = raw.isGroupMessage

        if isGroup {
            priorityAddend = await ensureGroupChat(raw).priorityAddend
        } else {
            priorityAddend = await ensureContact(raw.handleId).priorityAddend
        }

        // Compute content signals
        let median = reader.medianSentMessageLength(handleId: raw.handleId)
        let signals = detector.detect(text: raw.text, medianContactMessageLength: median)

        // Compute momentum
        let momentum = ScoreEngine.momentumScore(handleId: raw.handleId)

        // Compute initial scores
        let timeScore  = ScoreEngine.timeScore(receivedAt: raw.receivedAt)
        let dynScore   = ScoreEngine.dynamicScore(timeScore: timeScore,
                                                  contentScore: signals.contentScore,
                                                  momentumScore: momentum)
        let effScore   = ScoreEngine.effectiveScore(dynamicScore: dynScore, priorityAddend: priorityAddend)

        let appMessage = AppMessage(
            messageId: raw.guid,
            handleId:  raw.handleId,
            chatId:    raw.chatGuid,
            receivedAt: raw.receivedAt,
            bodyText:   raw.text,
            isGroupMessage: isGroup,
            contentScore: signals.contentScore,
            momentumScore: momentum,
            isQuestion: signals.isQuestion,
            isTimeSensitive: signals.isTimeSensitive,
            isEmotional: signals.isEmotional,
            isConversationalCloser: signals.isConversationalCloser,
            isLongMessage: signals.isLongMessage,
            timeScore: timeScore,
            dynamicScore: dynScore,
            effectiveScore: effScore,
            scoreLastCalculatedAt: Date(),
            createdAt: Date()
        )
        db.insertMessage(appMessage)
    }

    @discardableResult
    private func ensureContact(_ handleId: String) async -> Contact {
        if let existing = db.fetchContact(handleId: handleId) { return existing }
        let displayName = ContactsService.shared.displayName(for: handleId)
        let contact = Contact.defaultContact(handleId: handleId, displayName: displayName)
        db.upsertContact(contact)
        return contact
    }

    @discardableResult
    private func ensureGroupChat(_ raw: ChatDBReader.RawMessage) async -> GroupChat {
        let existing = db.fetchGroupChat(groupId: raw.chatGuid)

        // Ensure each participant contact exists; collect names for fallback display name
        var memberPriorities: [Int] = []
        var memberNames: [String] = []
        for handle in raw.participantHandles {
            let contact = await ensureContact(handle)
            memberPriorities.append(contact.priority)
            memberNames.append(contact.displayName ?? handle)
        }

        // Use iMessage's display_name if set; otherwise derive from member names ("A & B & C")
        let displayName: String? = {
            if let name = raw.groupChatName, !name.isEmpty { return name }
            return memberNames.isEmpty ? nil : memberNames.joined(separator: " & ")
        }()

        // If already stored but missing a name, patch it now and return
        if var gc = existing {
            if gc.displayName == nil || gc.displayName!.isEmpty {
                gc.displayName = displayName
                db.upsertGroupChat(gc)
            }
            return gc
        }

        let maxPriority = memberPriorities.max() ?? 1
        let gc = GroupChat(
            groupId: raw.chatGuid,
            displayName: displayName,
            memberHandleIds: raw.participantHandles,
            tier: .low,
            priority: maxPriority,
            priorityIsManual: false,
            sentMessageCount: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        db.upsertGroupChat(gc)
        return gc
    }

    // MARK: - Scoring Cycle (every 60 seconds)

    private func startScoring() {
        scoringTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await runScoringCycle()
            }
        }
    }

    private func runScoringCycle() async {
        let messages = db.fetchAllMessages()
        for msg in messages {
            let contact = db.fetchContact(handleId: msg.handleId)
            let groupChat = msg.isGroupMessage ? db.fetchGroupChat(groupId: msg.chatId) : nil

            let priorityAddend: Double
            if let gc = groupChat {
                priorityAddend = gc.priorityAddend
            } else if let c = contact {
                priorityAddend = c.priorityAddend
            } else {
                priorityAddend = 5.0 // default priority 1 addend
            }

            let result = ScoreEngine.recalculate(message: msg, priorityAddend: priorityAddend)
            db.updateMessageScores(msg.messageId,
                                   timeScore: result.timeScore,
                                   dynamicScore: result.dynamicScore,
                                   effectiveScore: result.effectiveScore)
        }
        await rebuildConversations()
    }

    // MARK: - Snooze Watcher (every 30 seconds)

    private func startSnoozeWatcher() {
        snoozeTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                db.deleteExpiredSnoozeStates()
                db.purgeExpiredNoReplyLogs()
                await rebuildConversations()
            }
        }
    }

    // MARK: - Build Conversations for UI

    func rebuildConversations() async {
        let messages  = db.fetchAllMessages()
        let snoozes   = db.fetchAllSnoozeStates()
        let snoozeMap = Dictionary(grouping: snoozes, by: \.handleId).mapValues { $0.first }

        // Group by chatId — each unique chat thread is its own card, regardless of sender
        var grouped: [String: [AppMessage]] = [:]
        for msg in messages {
            grouped[msg.chatId, default: []].append(msg)
        }

        var conversations: [Conversation] = []
        for (chatId, msgs) in grouped {
            guard let driving = msgs.max(by: { $0.effectiveScore < $1.effectiveScore }),
                  let mostRecent = msgs.max(by: { $0.receivedAt < $1.receivedAt })
            else { continue }

            let isGroup = driving.isGroupMessage
            // contactOrGroupId keeps its original semantics: handleId for 1-on-1, chatId for groups
            let contactOrGroupId = isGroup ? chatId : driving.handleId
            let snoozeState = snoozeMap[contactOrGroupId] ?? nil
            let isSnoozed   = snoozeState.map { $0.expiresAt > Date() } ?? false
            let snoozeExp   = snoozeState?.expiresAt

            // Resolve display name and tier
            let displayName: String
            let tier: Contact.Tier

            if isGroup, let gc = db.fetchGroupChat(groupId: chatId) {
                displayName = gc.displayName ?? "Group Chat"
                tier        = gc.tier
            } else if let contact = db.fetchContact(handleId: driving.handleId) {
                displayName = contact.displayName ?? driving.handleId
                tier        = contact.tier
            } else {
                displayName = driving.handleId
                tier        = .low
            }

            let conv = Conversation(
                contactOrGroupId: contactOrGroupId,
                displayName:      displayName,
                tier:             tier,
                effectiveScore:   driving.effectiveScore,
                previewText:      mostRecent.bodyText,
                unreadCount:      msgs.count,
                isSnoozed:        isSnoozed,
                snoozeExpiresAt:  snoozeExp,
                isGroupChat:      isGroup,
                receivedAt:       mostRecent.receivedAt,
                drivingMessageId: driving.messageId,
                chatId:           chatId
            )
            conversations.append(conv)
        }

        store.update(conversations: conversations)
    }

    // MARK: - Actions (called from UI)

    func dismiss(conversation: Conversation) {
        let messages = db.fetchMessages(for: conversation.contactOrGroupId)
        for msg in messages {
            db.deleteMessage(msg.messageId)
            knownMessageIds.remove(msg.messageId)
        }
        Task { await rebuildConversations() }
    }

    func snooze(conversation: Conversation) {
        db.snoozeConversation(conversation.contactOrGroupId)
        Task { await rebuildConversations() }
    }

    func markNoReplyNeeded(conversation: Conversation) {
        if let driving = db.fetchMessages(for: conversation.contactOrGroupId)
            .max(by: { $0.effectiveScore < $1.effectiveScore }) {
            db.markNoReplyNeeded(handleId: conversation.contactOrGroupId, messageId: driving.messageId)
            knownMessageIds.remove(driving.messageId)
        }
        Task { await rebuildConversations() }
    }

    func removeFromWidget(conversation: Conversation) {
        if conversation.isGroupChat {
            db.deleteGroupChat(conversation.contactOrGroupId)
        } else {
            db.deleteContact(conversation.contactOrGroupId)
        }
        for msg in db.fetchMessages(for: conversation.contactOrGroupId) {
            knownMessageIds.remove(msg.messageId)
        }
        Task { await rebuildConversations() }
    }

    func updateTier(_ tier: Contact.Tier, for conversation: Conversation) {
        if conversation.isGroupChat {
            db.updateGroupChatTier(conversation.contactOrGroupId, tier: tier)
        } else {
            db.updateContactTier(conversation.contactOrGroupId, tier: tier)
        }
        Task { await rebuildConversations() }
    }

    func updatePriority(_ priority: Int, for conversation: Conversation) {
        if conversation.isGroupChat {
            db.updateGroupChatPriority(conversation.contactOrGroupId, priority: priority)
        } else {
            db.updateContactPriority(conversation.contactOrGroupId, priority: priority)
        }
        Task {
            await self.runScoringCycle()
        }
    }
}
