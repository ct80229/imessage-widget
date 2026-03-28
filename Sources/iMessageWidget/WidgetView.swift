import AppKit
import SwiftUI

// MARK: - Sort mode

enum SortMode: String, CaseIterable {
    case priority
    case recent

    var label: String {
        switch self {
        case .priority: return "priority"
        case .recent:   return "recent"
        }
    }
}

// MARK: - Root wrapper

struct WidgetRootView: View {
    @ObservedObject var store: ConversationStore
    @State private var sortMode: SortMode = .priority

    private var visibleConversations: [Conversation] {
        switch sortMode {
        case .priority: return store.orderedConversations
        case .recent:   return store.chronologicalConversations
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Background — dark, semi-transparent
            Color.black.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Title bar spacer (traffic lights live here natively)
                Color.clear.frame(height: 28)

                // Tab bar
                SortTabBar(selection: $sortMode)

                // Thin rule below tabs
                Color.white.opacity(0.07).frame(height: 1)

                if visibleConversations.isEmpty {
                    EmptyQueueView()
                } else {
                    QueueScrollView(conversations: visibleConversations,
                                    showBelowFold: sortMode == .priority,
                                    belowFoldScore: store.belowFoldScore)
                }
            }

            // Invisible drag handle — sits over the title bar area,
            // calls window?.performDrag so the window can be moved.
            DragHandle()
                .frame(height: 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Sort tab bar

struct SortTabBar: View {
    @Binding var selection: SortMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SortMode.allCases, id: \.self) { mode in
                Text(mode.label)
                    .font(.system(.caption2, design: .monospaced).weight(
                        selection == mode ? .bold : .regular
                    ))
                    .foregroundColor(
                        selection == mode
                            ? .white.opacity(0.85)
                            : .white.opacity(0.3)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        selection == mode
                            ? Color.white.opacity(0.07)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) { selection = mode }
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Drag handle (forwards mouse-down to window drag)

struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> _DragHandleNSView { _DragHandleNSView() }
    func updateNSView(_ nsView: _DragHandleNSView, context: Context) {}
}

final class _DragHandleNSView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func mouseDragged(with event: NSEvent) { window?.performDrag(with: event) }
}

// MARK: - Empty state

struct EmptyQueueView: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("// queue empty")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white.opacity(0.18))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Scrollable queue

struct QueueScrollView: View {
    let conversations: [Conversation]
    var showBelowFold: Bool = true
    var belowFoldScore: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(conversations) { conv in
                        CardView(conversation: conv)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal:   .move(edge: .trailing).combined(with: .opacity)
                            ))
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if showBelowFold, let score = belowFoldScore {
                BelowFoldIndicator(score: score)
            }
        }
    }
}

// MARK: - Below-fold fade indicator

struct BelowFoldIndicator: View {
    let score: Double

    private var color: Color {
        if score < 31 { return .clear }
        if score < 61 { return Color(red: 1.0, green: 160/255, blue: 60/255) }
        return Color(red: 1.0, green: 100/255, blue: 60/255)
    }

    var body: some View {
        LinearGradient(
            colors: [.clear, color.opacity(0.15)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 20)
        .allowsHitTesting(false)
    }
}
