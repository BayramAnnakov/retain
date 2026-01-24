import AppIntents

/// Provides App Shortcuts for Retain
/// These shortcuts appear in Spotlight and can be triggered via Siri
struct RetainShortcuts: AppShortcutsProvider {
    /// Update app shortcut parameters - call this on app launch
    @MainActor
    static func updateShortcuts() {
        Task {
            try? await Self.updateAppShortcutParameters()
        }
    }

    /// The app shortcuts to expose
    /// Note: Phrases must include \(.applicationName) and can only interpolate AppEntity/AppEnum parameters
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncConversationsIntent(),
            phrases: [
                "Sync \(.applicationName)",
                "Update \(.applicationName) conversations",
                "Refresh \(.applicationName)"
            ],
            shortTitle: "Sync",
            systemImageName: "arrow.clockwise"
        )

        AppShortcut(
            intent: OpenLearningsIntent(),
            phrases: [
                "Open \(.applicationName) learnings",
                "Review \(.applicationName) learnings",
                "Show learnings in \(.applicationName)"
            ],
            shortTitle: "Learnings",
            systemImageName: "lightbulb"
        )

        AppShortcut(
            intent: GetRecentConversationsIntent(),
            phrases: [
                "Show recent \(.applicationName) conversations",
                "Get recent chats from \(.applicationName)",
                "List \(.applicationName) conversations"
            ],
            shortTitle: "Recent",
            systemImageName: "clock"
        )

        AppShortcut(
            intent: GetPendingLearningsCountIntent(),
            phrases: [
                "How many \(.applicationName) learnings",
                "Count pending learnings in \(.applicationName)",
                "Pending reviews in \(.applicationName)"
            ],
            shortTitle: "Count",
            systemImageName: "number"
        )
    }
}
