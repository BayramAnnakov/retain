import SwiftUI

/// Compact badge showing provider with brand color
struct ProviderBadge: View {
    let provider: Provider
    var size: Size = .medium

    enum Size {
        case small, medium, large

        var iconSize: CGFloat {
            switch self {
            case .small: return 12   // +2pt for better visibility
            case .medium: return 14  // +2pt
            case .large: return 16   // +2pt
            }
        }

        var fontSize: Font {
            switch self {
            case .small: return .system(size: 10, weight: .medium)   // +1pt
            case .medium: return .system(size: 11, weight: .medium)  // +1pt
            case .large: return .system(size: 12, weight: .medium)   // +1pt
            }
        }

        var paddingH: CGFloat {
            switch self {
            case .small: return 7    // +1pt
            case .medium: return 9   // +1pt
            case .large: return 11   // +1pt
            }
        }

        var paddingV: CGFloat {
            switch self {
            case .small: return 3    // +1pt
            case .medium: return 4   // +1pt
            case .large: return 5    // +1pt
            }
        }
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: provider.iconName)
                .font(.system(size: size.iconSize))

            Text(provider.shortName)
                .font(size.fontSize)
        }
        .padding(.horizontal, size.paddingH)
        .padding(.vertical, size.paddingV)
        .background(provider.brandColor.opacity(0.15))
        .foregroundStyle(provider.brandColor)
        .clipShape(Capsule())
        .shadow(color: provider.brandColor.opacity(0.15), radius: 2, y: 1)
    }
}

/// Provider icon only (for compact spaces)
struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = IconSize.md

    var body: some View {
        Image(systemName: provider.iconName)
            .font(.system(size: size))
            .foregroundColor(provider.brandColor)
    }
}

/// Provider row for sidebar
struct ProviderSidebarRow: View {
    let provider: Provider
    let count: Int
    let isSelected: Bool
    var syncStatus: SyncStatus = .idle
    var connectionStatus: ConnectionStatus? = nil
    @FocusState private var isFocused: Bool

    enum SyncStatus {
        case idle, syncing, error
    }

    enum ConnectionStatus {
        case connected
        case verifying
        case saved
        case disconnected
        case error
    }

    private var connectionLabel: String? {
        guard let connectionStatus else { return nil }
        switch connectionStatus {
        case .connected:
            return "Live"
        case .verifying:
            return "Verifying..."
        case .saved:
            return "Needs verify"
        case .disconnected:
            return "Not connected"
        case .error:
            return "Error"
        }
    }

    private var connectionColor: Color {
        switch connectionStatus {
        case .connected:
            return .green
        case .verifying:
            return .blue
        case .saved:
            return .orange
        case .disconnected:
            return AppColors.secondaryText
        case .error:
            return .red
        case .none:
            return AppColors.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: provider.iconName)
                .font(.system(size: IconSize.lg))
                .foregroundColor(provider.isSupported ? provider.brandColor : provider.brandColor.opacity(0.5))
                .frame(width: IconSize.xl)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(AppFont.body)
                    .foregroundColor(provider.isSupported ? AppColors.primaryText : AppColors.secondaryText)

                if let connectionLabel {
                    Text(connectionLabel)
                        .font(AppFont.caption2)
                        .foregroundColor(connectionColor)
                }
            }

            // Coming Soon badge for unsupported providers
            if !provider.isSupported {
                Text("Coming Soon")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }

            Spacer()

            // Sync status indicator (only for supported providers)
            if provider.isSupported {
                switch syncStatus {
                case .syncing:
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                case .idle:
                    EmptyView()
                }
            }

            // Count badge (consistent minimum width)
            if count > 0 {
                Text("\(count)")
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.primaryText)
                    .frame(minWidth: 24)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(CornerRadius.md)
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .focusRing(isFocused, cornerRadius: CornerRadius.md)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .focusable()
        .focused($isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("Sidebar_\(provider.displayName)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        if let connectionLabel {
            return "\(provider.displayName), \(connectionLabel), \(count) conversations"
        }
        return "\(provider.displayName), \(count) conversations"
    }
}

// MARK: - Previews

#Preview("Provider Badge Sizes") {
    VStack(spacing: 20) {
        HStack(spacing: 12) {
            ProviderBadge(provider: .claudeCode, size: .small)
            ProviderBadge(provider: .claudeCode, size: .medium)
            ProviderBadge(provider: .claudeCode, size: .large)
        }

        HStack(spacing: 12) {
            ProviderBadge(provider: .chatgptWeb, size: .small)
            ProviderBadge(provider: .chatgptWeb, size: .medium)
            ProviderBadge(provider: .chatgptWeb, size: .large)
        }

        HStack(spacing: 12) {
            ProviderBadge(provider: .codex, size: .small)
            ProviderBadge(provider: .codex, size: .medium)
            ProviderBadge(provider: .codex, size: .large)
        }
    }
    .padding()
}

#Preview("Provider Sidebar Row") {
    VStack(spacing: 8) {
        ProviderSidebarRow(provider: .claudeCode, count: 42, isSelected: true)
        ProviderSidebarRow(provider: .chatgptWeb, count: 15, isSelected: false, syncStatus: .syncing)
        ProviderSidebarRow(provider: .codex, count: 8, isSelected: false)
        ProviderSidebarRow(provider: .claudeWeb, count: 0, isSelected: false, syncStatus: .error)
    }
    .padding()
    .frame(width: 250)
}
