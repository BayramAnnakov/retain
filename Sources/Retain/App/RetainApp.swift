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
}

@main
struct RetainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
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
    }

    var body: some Scene {
        WindowGroup(id: "main") {
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
