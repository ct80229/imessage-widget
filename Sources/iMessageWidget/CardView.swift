import SwiftUI

struct CardView: View {
    let conversation: Conversation

    @State private var isExpanded      = false
    @State private var showSettings    = false
    @State private var composeText     = ""
    @State private var isSending       = false
    @State private var sendFailed      = false
    @State private var automationDenied = false

    private let daemon = Daemon.shared

    // MARK: - Urgency color (white → orange → red)

    private var urgencyColor: Color {
        let t = min(max(conversation.effectiveScore / 100.0, 0), 1)
        guard t > 0.05 else { return Color.white.opacity(0.12) }
        let green = t < 0.5 ? lerp(1.0, 160/255.0, t * 2) : lerp(160/255.0, 80/255.0, (t - 0.5) * 2)
        let blue  = t < 0.5 ? lerp(1.0,  60/255.0, t * 2) : lerp( 60/255.0, 50/255.0, (t - 0.5) * 2)
        return Color(red: 1.0, green: green, blue: blue)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Left urgency bar
                urgencyColor
                    .frame(width: 2)
                    .padding(.vertical, 1)

                VStack(alignment: .leading, spacing: 0) {
                    rowHeader
                    if isExpanded {
                        expandedContent
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            // Row separator
            Color.white.opacity(0.06).frame(height: 1)
        }
        .popover(isPresented: $showSettings, arrowEdge: .leading) {
            ContactSettingsView(conversation: conversation, onDismiss: { showSettings = false })
        }
    }

    // MARK: - Row header

    private var rowHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Button { showSettings.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(conversation.displayName)
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                            .foregroundColor(.white)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .medium))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text(timeAgo(conversation.receivedAt))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
            }

            HStack(alignment: .top, spacing: 4) {
                Text("›")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white.opacity(0.18))

                Text(conversation.previewText)
                    .font(.system(.caption, design: .monospaced).weight(.light))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(isExpanded ? nil : 1)
                    .truncationMode(.tail)

                if conversation.unreadCount > 1 {
                    Text("+\(conversation.unreadCount - 1)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.07).cornerRadius(2))
                }
            }
        }
    }

    // MARK: - Expanded reply area

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Prompt + text editor
            HStack(alignment: .top, spacing: 6) {
                Text("$")
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundColor(urgencyColor.opacity(0.75))
                    .padding(.top, 3)

                ZStack(alignment: .topLeading) {
                    if composeText.isEmpty {
                        Text("type reply…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white.opacity(0.18))
                            .padding(.top, 3)
                    }
                    TextEditor(text: $composeText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 44, maxHeight: 100)
                        .onTapGesture {}
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .cornerRadius(3)
            .padding(.top, 8)

            if sendFailed {
                Text(automationDenied
                     ? "// automation denied — grant access in Settings"
                     : "// send failed — try again")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(Color(red: 1, green: 0.4, blue: 0.4))
            }

            HStack(spacing: 0) {
                Spacer()
                if automationDenied {
                    Button("open messages") { openInMessages() }
                        .buttonStyle(TerminalSecondaryButtonStyle())
                } else {
                    Button("cancel") {
                        withAnimation { isExpanded = false }
                        composeText = ""
                        sendFailed  = false
                    }
                    .buttonStyle(TerminalSecondaryButtonStyle())

                    Button(isSending ? "sending…" : "send ↵") {
                        Task { await send() }
                    }
                    .buttonStyle(TerminalPrimaryButtonStyle())
                    .disabled(composeText.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                }
            }
        }
    }

    // MARK: - Send

    private func send() async {
        let text = composeText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSending   = true
        sendFailed  = false

        let result: Result<Void, MessageSender.SendError>
        if conversation.isGroupChat {
            result = await MessageSender.shared.sendToGroup(text: text, chatGuid: conversation.chatId)
        } else {
            result = await MessageSender.shared.send(text: text, to: conversation.contactOrGroupId)
        }
        isSending = false

        switch result {
        case .success:
            daemon.dismiss(conversation: conversation)
            composeText = ""
            isExpanded  = false
        case .failure(let err):
            sendFailed = true
            if case .automationDenied = err { automationDenied = true }
        }
    }

    private func openInMessages() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(composeText, forType: .string)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Messages.app"),
                                           configuration: .init(),
                                           completionHandler: nil)
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 3600      { return "\(Int(s / 60))m" }
        if s < 86400     { return "\(Int(s / 3600))h" }
        if s < 86400 * 7 { return "\(Int(s / 86400))d" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// MARK: - Button styles

struct TerminalPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(configuration.isPressed ? 0.6 : 0.85).cornerRadius(2))
    }
}

struct TerminalSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.white.opacity(configuration.isPressed ? 0.2 : 0.35))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}
