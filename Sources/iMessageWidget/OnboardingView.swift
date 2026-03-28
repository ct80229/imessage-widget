import SwiftUI
import AppKit

struct OnboardingView: View {
    @State private var step = 0
    @State private var isAnalyzing = false
    @State private var analysisProgress: Double = 0
    @State private var hasFullDiskAccess = false
    @State private var contactsGranted = false

    let onComplete: () -> Void

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 0) {
                stepContent
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 440, height: 340)
        .onAppear { checkFullDiskAccess() }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: fullDiskStep
        case 1: contactsStep
        case 2: analysisStep
        case 3: coachMarkStep
        default: EmptyView()
        }
    }

    // MARK: - Step 0: Full Disk Access

    private var fullDiskStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("Full Disk Access Required")
                .font(.title2.bold())
            Text("iMessageWidget reads your iMessage history to surface unanswered messages. This requires Full Disk Access in System Settings.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if hasFullDiskAccess {
                Label("Full Disk Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    )
                    startPollingForDiskAccess()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .onChange(of: hasFullDiskAccess) { granted in
            if granted { step = 1 }
        }
    }

    // MARK: - Step 1: Contacts Access

    private var contactsStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("Contacts Access")
                .font(.title2.bold())
            Text("Allow iMessageWidget to access Contacts so it can show names instead of phone numbers.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Skip") { step = 2 }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("Allow Contacts Access") {
                    Task {
                        contactsGranted = await ContactsService.shared.requestAccess()
                        step = 2
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Step 2: Initial Analysis

    private var analysisStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("Analyzing Message History")
                .font(.title2.bold())

            if isAnalyzing {
                VStack(spacing: 8) {
                    ProgressView(value: analysisProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 240)
                    Text("Reading messages…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("This reads your local iMessage history to find unanswered messages. It may take a moment.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Start Analysis") {
                    runAnalysis()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Step 3: Coach marks

    private var coachMarkStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.tap")
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
            Text("Two Things to Know")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 14) {
                coachMark(
                    icon: "slider.horizontal.3",
                    title: "Tap a contact's name",
                    body: "Opens their settings where you can set priority, snooze, or mark no reply needed."
                )
                coachMark(
                    icon: "xmark.circle",
                    title: "No reply needed",
                    body: "Found in the settings popover — permanently clears the card without replying."
                )
            }
            .padding(.horizontal, 8)

            Button("Got it") {
                AppDatabase.shared.markOnboarded()
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func coachMark(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func checkFullDiskAccess() {
        hasFullDiskAccess = ChatDBReader.shared.isChatDBAccessible
    }

    private func startPollingForDiskAccess() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            if ChatDBReader.shared.isChatDBAccessible {
                hasFullDiskAccess = true
                timer.invalidate()
            }
        }
    }

    private func runAnalysis() {
        isAnalyzing = true
        // Trigger the daemon's first poll on a background task
        Task {
            // Simulate progress while waiting
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run { analysisProgress = Double(i) / 10.0 }
            }
            await MainActor.run {
                isAnalyzing = false
                step = 3
            }
        }
    }
}
