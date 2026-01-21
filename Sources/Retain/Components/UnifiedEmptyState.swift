import SwiftUI

/// Unified empty state view for consistent empty state presentation across the app
struct UnifiedEmptyState: View {
    enum Style {
        case welcome           // First-time, onboarding
        case noSelection       // Select something to view
        case noResults         // Search/filter returned nothing
        case success           // All done, queue empty
        case noData            // No data exists yet
        case providerDisconnected  // Web provider not connected
        case providerNeedsSync     // Connected but hasn't synced
        case providerSyncing       // Sync in progress
        case providerEmpty         // Connected, synced, no conversations
    }

    let style: Style
    let title: String
    var subtitle: String? = nil
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    private var icon: String {
        switch style {
        case .welcome: return "sparkles"
        case .noSelection: return "square.stack.3d.up"
        case .noResults: return "magnifyingglass"
        case .success: return "checkmark.circle"
        case .noData: return "tray"
        case .providerDisconnected: return "link.badge.plus"
        case .providerNeedsSync: return "arrow.triangle.2.circlepath"
        case .providerSyncing: return "arrow.triangle.2.circlepath"
        case .providerEmpty: return "bubble.left.and.bubble.right"
        }
    }

    private var iconColor: Color {
        switch style {
        case .success: return .green
        case .noResults: return .secondary
        case .welcome: return .accentColor
        case .providerDisconnected: return .orange
        case .providerNeedsSync: return .blue
        case .providerSyncing: return .blue
        case .providerEmpty: return .secondary
        default: return .accentColor.opacity(0.7)
        }
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 44))  // Slightly smaller than hero for better hierarchy
                .foregroundColor(iconColor.opacity(0.85))

            VStack(spacing: Spacing.xs) {
                Text(title)
                    .font(AppFont.title3)
                    .foregroundColor(AppColors.primaryText)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(AppFont.body)
                        .foregroundColor(AppColors.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            if let actionLabel = actionLabel, let action = action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xxl)
    }
}

// MARK: - Convenience Initializers

extension UnifiedEmptyState {
    /// Welcome state for first-time users
    static func welcome(action: @escaping () -> Void) -> UnifiedEmptyState {
        UnifiedEmptyState(
            style: .welcome,
            title: "Welcome to Retain",
            subtitle: "Import your AI conversations to get started",
            actionLabel: "Sync Now",
            action: action
        )
    }

    /// No selection state
    static func noSelection(entityName: String = "Conversation") -> UnifiedEmptyState {
        UnifiedEmptyState(
            style: .noSelection,
            title: "Select a \(entityName)",
            subtitle: "Choose from the list to view details"
        )
    }

    /// No search results
    static func noResults(query: String) -> UnifiedEmptyState {
        UnifiedEmptyState(
            style: .noResults,
            title: "No results for \"\(query)\"",
            subtitle: "Try different keywords or check your spelling"
        )
    }

    /// Success/empty queue state
    static func success(title: String = "All caught up!", subtitle: String? = nil) -> UnifiedEmptyState {
        UnifiedEmptyState(
            style: .success,
            title: title,
            subtitle: subtitle
        )
    }

    /// No data state with action
    static func noData(title: String, subtitle: String? = nil, actionLabel: String? = nil, action: (() -> Void)? = nil) -> UnifiedEmptyState {
        UnifiedEmptyState(
            style: .noData,
            title: title,
            subtitle: subtitle,
            actionLabel: actionLabel,
            action: action
        )
    }

    /// Provider not connected state
    static func providerDisconnected(providerName: String, action: @escaping () -> Void) -> UnifiedEmptyState {
        UnifiedEmptyState(
            style: .providerDisconnected,
            title: "Connect \(providerName)",
            subtitle: "Sign in to import your conversations",
            actionLabel: "Connect",
            action: action
        )
    }

    /// Provider connected but needs sync
    static func providerNeedsSync(
        providerName: String,
        actionLabel: String = "Sync Now",
        action: @escaping () -> Void
    ) -> UnifiedEmptyState {
        UnifiedEmptyState(
            style: .providerNeedsSync,
            title: "Ready to Sync",
            subtitle: "Click Sync to import your \(providerName) conversations",
            actionLabel: actionLabel,
            action: action
        )
    }

    /// Provider currently syncing
    static func providerSyncing(providerName: String) -> UnifiedEmptyState {
        UnifiedEmptyState(
            style: .providerSyncing,
            title: "Syncing \(providerName)",
            subtitle: "Importing your conversations..."
        )
    }

    /// Provider connected and synced but empty
    static func providerEmpty(providerName: String) -> UnifiedEmptyState {
        UnifiedEmptyState(
            style: .providerEmpty,
            title: "No \(providerName) Conversations",
            subtitle: "Start chatting and your conversations will appear here"
        )
    }
}

// MARK: - Previews

#Preview("All Styles") {
    VStack(spacing: 0) {
        HStack(spacing: 0) {
            UnifiedEmptyState.welcome { }
                .frame(width: 300, height: 250)
                .border(Color.gray.opacity(0.3))

            UnifiedEmptyState.noSelection()
                .frame(width: 300, height: 250)
                .border(Color.gray.opacity(0.3))
        }
        HStack(spacing: 0) {
            UnifiedEmptyState.noResults(query: "test")
                .frame(width: 300, height: 250)
                .border(Color.gray.opacity(0.3))

            UnifiedEmptyState.success(subtitle: "No pending items")
                .frame(width: 300, height: 250)
                .border(Color.gray.opacity(0.3))
        }
        UnifiedEmptyState.noData(
            title: "No workflow candidates",
            subtitle: "Run a scan to detect patterns",
            actionLabel: "Scan Now"
        ) { }
        .frame(width: 300, height: 250)
        .border(Color.gray.opacity(0.3))
    }
}
