import SwiftUI

struct ContactSettingsView: View {
    let conversation: Conversation
    let onDismiss: () -> Void

    @State private var tier: Contact.Tier
    @State private var priority: Int
    @State private var showRemoveConfirm = false

    private let daemon = Daemon.shared

    init(conversation: Conversation, onDismiss: @escaping () -> Void) {
        self.conversation = conversation
        self.onDismiss = onDismiss
        _tier     = State(initialValue: conversation.tier)
        _priority = State(initialValue: {
            if conversation.isGroupChat {
                return AppDatabase.shared.fetchGroupChat(groupId: conversation.contactOrGroupId)?.priority ?? 1
            } else {
                return AppDatabase.shared.fetchContact(handleId: conversation.contactOrGroupId)?.priority ?? 1
            }
        }())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    if conversation.isGroupChat {
                        Text("Group chat")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Tier toggle
            settingRow {
                Toggle(isOn: Binding(
                    get: { tier == .high },
                    set: { val in
                        tier = val ? .high : .low
                        daemon.updateTier(tier, for: conversation)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("High Tier")
                            .font(.system(size: 12, weight: .medium))
                        Text("Always appears at top of queue")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider().padding(.leading, 14)

            // Priority selector
            settingRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Priority")
                        .font(.system(size: 12, weight: .medium))
                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { p in
                            Button {
                                priority = p
                                daemon.updatePriority(p, for: conversation)
                            } label: {
                                Text("\(p)")
                                    .font(.system(size: 11, weight: priority == p ? .semibold : .regular))
                                    .frame(width: 28, height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(priority == p
                                                  ? Color.accentColor.opacity(0.8)
                                                  : Color.secondary.opacity(0.12))
                                    )
                                    .foregroundColor(priority == p ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()

            // Snooze
            actionButton(label: "Remind me in 2 hours", icon: "clock") {
                daemon.snooze(conversation: conversation)
                onDismiss()
            }

            Divider().padding(.leading, 14)

            // No reply needed
            actionButton(label: "No reply needed", icon: "checkmark") {
                daemon.markNoReplyNeeded(conversation: conversation)
                onDismiss()
            }

            Divider()

            // Remove
            Button {
                showRemoveConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                    Text("Remove from widget")
                        .font(.system(size: 12))
                }
                .foregroundColor(.red.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .confirmationDialog("Remove \(conversation.displayName) from widget?",
                                isPresented: $showRemoveConfirm,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    daemon.removeFromWidget(conversation: conversation)
                    onDismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .frame(width: 240)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private func actionButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
