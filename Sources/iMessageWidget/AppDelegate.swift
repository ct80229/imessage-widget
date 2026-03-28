import AppKit
import SwiftUI

// AppDelegate is called on the main thread by macOS, but is not formally @MainActor
// because main.swift is a synchronous non-isolated context. We use Task { @MainActor in }
// wherever we need to call @MainActor-isolated code (Daemon, ConversationStore).
class AppDelegate: NSObject, NSApplicationDelegate {

    private var widgetPanel: WidgetPanel?
    private var onboardingWindow: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Kill any other running instance of this app so only one copy is ever alive.
        let myPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.local.iMessageWidget")
            .filter { $0.processIdentifier != myPID }
            .forEach { $0.terminate() }

        NSApp.setActivationPolicy(.regular)
        setupMainMenu()

        if AppDatabase.shared.isOnboarded() {
            Task { @MainActor in self.launchWidget() }
        } else {
            showOnboarding()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Widget launch

    @MainActor
    private func launchWidget() {
        Daemon.shared.start()
        setupMenuBar()
        showWidget()
    }

    @MainActor
    func showWidget() {
        if let panel = widgetPanel {
            panel.show()   // re-show if already exists but was hidden
        } else {
            let panel = WidgetPanel(store: ConversationStore.shared)
            panel.show()
            widgetPanel = panel
        }
    }

    @MainActor
    func hideWidget() {
        widgetPanel?.orderOut(nil)
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let contentView = OnboardingView {
            Task { @MainActor in
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                self.launchWidget()
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        window.title = "iMessageWidget Setup"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    // MARK: - Main menu (Edit menu enables ⌘C / ⌘V / ⌘X / ⌘A)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (required first item)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit iMessageWidget",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo",       action: Selector(("undo:")),      keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo",       action: Selector(("redo:")),       keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right",
                                accessibilityDescription: "iMessageWidget")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Widget", action: #selector(handleShowWidget), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit iMessageWidget", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func handleShowWidget() {
        Task { @MainActor in self.showWidget() }
    }
}
