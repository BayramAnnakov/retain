import SwiftUI
import Sparkle

/// App delegate to handle window management
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app appears in the Dock (not just menu bar)
        NSApplication.shared.setActivationPolicy(.regular)

        // Set the Dock icon using SF Symbol
        setDockIcon()

        // Ensure the app is activated and main window is shown
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Make sure a window is visible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = NSApplication.shared.windows.first(where: { !$0.title.isEmpty || $0.contentView != nil }) {
                window.makeKeyAndOrderFront(nil)
            }
        }

        // Register App Shortcuts with the system
        RetainShortcuts.updateShortcuts()
    }

    private func setDockIcon() {
        // Create a nice app icon using SF Symbol
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high

            // Background gradient (blue to purple)
            let gradient = NSGradient(colors: [
                NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1.0),
                NSColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1.0)
            ])
            let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 20, dy: 20), xRadius: 100, yRadius: 100)
            gradient?.draw(in: bgPath, angle: -45)

            // Draw the brain symbol in white
            if let symbol = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 240, weight: .regular)
                    .applying(.init(paletteColors: [.white]))
                let configuredSymbol = symbol.withSymbolConfiguration(config) ?? symbol

                let symbolSize = NSSize(width: 300, height: 300)
                let symbolRect = NSRect(
                    x: (rect.width - symbolSize.width) / 2,
                    y: (rect.height - symbolSize.height) / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
                configuredSymbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }

        NSApplication.shared.applicationIconImage = image
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // If no windows are visible, create a new one
            for window in sender.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    return true
                }
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // All Swift Tasks are automatically cancelled when the process terminates,
        // but we log this for clarity. No explicit cleanup needed since:
        // 1. SyncService tasks use cooperative cancellation (check Task.isCancelled)
        // 2. FileWatcher uses FSEvents which are cleaned up by the OS
        // 3. WebSyncEngine tasks are process-bound
        // The OS kills all threads when the process exits.
    }

    // MARK: - URL Scheme Handling (prevents multiple windows)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleRetainURL(url)
        }
    }

    private func handleRetainURL(_ url: URL) {
        guard let route = URLSchemeHandler.parse(url) else {
            #if DEBUG
            print("Invalid URL scheme: \(url)")
            #endif
            return
        }

        // Activate and focus existing window
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }

        // Handle the route
        Task { @MainActor in
            guard let appState = AppState.shared else { return }

            switch route {
            case .conversation(let id):
                appState.navigateToConversation(id: id)

            case .search(let query):
                appState.activeView = .conversationList
                appState.sidebarSelection = nil
                appState.clearFilter()
                appState.searchQuery = query
                appState.focusSearch()

            case .learnings:
                appState.navigateToLearnings()

            case .sync:
                appState.triggerSync()
            }
        }
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        // Sync Now
        let syncItem = NSMenuItem(
            title: "Sync Now",
            action: #selector(syncNow),
            keyEquivalent: ""
        )
        syncItem.target = self
        menu.addItem(syncItem)

        // Review Learnings
        let pendingCount = MainActor.assumeIsolated { AppState.shared?.pendingLearningsCount ?? 0 }
        let learningsTitle = pendingCount > 0 ? "Review Learnings (\(pendingCount))" : "Review Learnings"
        let learningsItem = NSMenuItem(
            title: learningsTitle,
            action: #selector(openLearnings),
            keyEquivalent: ""
        )
        learningsItem.target = self
        menu.addItem(learningsItem)

        menu.addItem(NSMenuItem.separator())

        // Recent conversations submenu
        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()

        let recentConversations = MainActor.assumeIsolated {
            AppState.shared?.conversations.prefix(5) ?? []
        }

        for conversation in recentConversations {
            let item = NSMenuItem(
                title: conversation.displayTitle,
                action: #selector(openConversation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = conversation.id
            recentMenu.addItem(item)
        }

        if recentMenu.items.isEmpty {
            let emptyItem = NSMenuItem(title: "No recent conversations", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
        }

        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        return menu
    }

    @objc private func syncNow() {
        Task { @MainActor in
            AppState.shared?.triggerSync()
        }
    }

    @objc private func openLearnings() {
        Task { @MainActor in
            AppState.shared?.navigateToLearnings()
            // Bring app to front
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func openConversation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Task { @MainActor in
            AppState.shared?.navigateToConversation(id: id)
            // Bring app to front
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

@main
struct RetainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    init() {
        if CLIFullScanRunner.runIfRequested() {
            exit(0)
        }
        if LLMShadowAuditRunner.runIfRequested() {
            exit(0)
        }
        if ExtractionAuditRunner.runIfRequested() {
            exit(0)
        }

        // Initialize AppState and set shared instance for AppDelegate access
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        AppState.shared = state
    }

    var body: some Scene {
        // Single window app - URL handling is done in AppDelegate
        Window("Retain", id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Sync Now") {
                    Task {
                        await appState.syncAll()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Force Full Sync") {
                    Task {
                        await appState.forceFullSync()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }

            // Check for Updates in the App menu
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: UpdateController.shared.updater)
            }

            CommandMenu("Search") {
                Button("Search Conversations") {
                    appState.focusSearch()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Search Messages") {
                    appState.focusSearch(messagesOnly: true)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        // Menu bar extra
        MenuBarExtra("Retain", systemImage: "brain.head.profile", isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
