import AppKit
import SwiftUI

// MARK: - Accessibility Announcements

/// Post a VoiceOver announcement for dynamic content changes
private func announceToVoiceOver(_ message: String) {
    NSAccessibility.post(
        element: NSApp.mainWindow as Any,
        notification: .announcementRequested,
        userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high]
    )
}

// MARK: - Sync Overlay View

/// Modal overlay displayed during sync operations
/// Follows Apple HIG for sheets and progress indicators
struct SyncOverlay: View {
    @ObservedObject var syncState: SyncState
    let onCancel: () -> Void

    @State private var showCancelConfirmation = false
    @State private var animationPhase: CGFloat = 0

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .transition(.opacity)

            // Content card
            VStack(spacing: Spacing.lg) {
                // Header with animated icon
                SyncHeaderView(animationPhase: animationPhase)

                // Status message
                Text(syncState.statusMessage)
                    .font(AppFont.headline)
                    .foregroundColor(AppColors.primaryText)
                    .animation(.easeInOut(duration: 0.2), value: syncState.statusMessage)

                // Provider progress list
                ProviderProgressList(providerProgress: syncState.providerProgress)
                    .frame(minHeight: 80)

                // Overall progress bar
                OverallProgressBar(progress: syncState.overallProgress)

                // Cancel button
                Button(role: .cancel) {
                    showCancelConfirmation = true
                } label: {
                    Text("Cancel")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(Spacing.xl)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.xl))
            .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
        .onAppear {
            startAnimation()
        }
        .confirmationDialog(
            "Cancel Sync?",
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Sync", role: .destructive) {
                onCancel()
            }
            Button("Continue", role: .cancel) {}
        } message: {
            Text("Conversations synced so far will be saved.")
        }
    }

    private func startAnimation() {
        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
            animationPhase = 1
        }
    }
}

// MARK: - Sync Header View

private struct SyncHeaderView: View {
    let animationPhase: CGFloat

    var body: some View {
        ZStack {
            // Pulsing background circle
            Circle()
                .fill(Color.accentColor.opacity(0.1))
                .frame(width: 64, height: 64)
                .scaleEffect(1 + 0.1 * sin(animationPhase * .pi * 2))

            // Rotating sync icon
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: IconSize.xxl, weight: .medium))
                .foregroundColor(.accentColor)
                .rotationEffect(.degrees(animationPhase * 360))
        }
    }
}

// MARK: - Provider Progress List

private struct ProviderProgressList: View {
    let providerProgress: [Provider: ProviderSyncProgress]

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ForEach(Array(providerProgress.keys.sorted(by: { $0.displayName < $1.displayName })), id: \.self) { provider in
                if let progress = providerProgress[provider] {
                    ProviderProgressRow(provider: provider, progress: progress)
                }
            }
        }
    }
}

// MARK: - Provider Progress Row

private struct ProviderProgressRow: View {
    let provider: Provider
    let progress: ProviderSyncProgress

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Provider icon with status indicator
            ZStack {
                Circle()
                    .fill(provider.brandColor.opacity(0.15))
                    .frame(width: 28, height: 28)

                statusIcon
                    .font(.system(size: IconSize.sm))
                    .foregroundColor(provider.brandColor)
            }

            // Provider name
            Text(provider.displayName)
                .font(AppFont.body)
                .foregroundColor(AppColors.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Status text
            Text(statusText)
                .font(AppFont.caption)
                .foregroundColor(AppColors.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch progress.phase {
        case .discovering:
            Image(systemName: "magnifyingglass")
        case .parsing:
            Image(systemName: "doc.text")
        case .saving:
            Image(systemName: "arrow.down.doc")
        case .completed:
            Image(systemName: "checkmark")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
        }
    }

    private var statusText: String {
        switch progress.phase {
        case .discovering:
            return "Discovering..."
        case .parsing(let current, let total):
            return "\(current)/\(total)"
        case .saving:
            return "Saving..."
        case .completed:
            return "Done"
        case .failed(let error):
            return error
        }
    }
}

// MARK: - Overall Progress Bar

private struct OverallProgressBar: View {
    let progress: Double

    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(spacing: Spacing.xs) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)

                    // Fill with gradient
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [.accentColor, .accentColor.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * animatedProgress, height: 4)
                }
            }
            .frame(height: 4)

            // Percentage text
            Text("\(Int(progress * 100))%")
                .font(AppFont.caption2)
                .foregroundColor(AppColors.tertiaryText)
                .monospacedDigit()
        }
        .onChange(of: progress) { oldValue, newValue in
            withAnimation(.easeOut(duration: 0.3)) {
                animatedProgress = newValue
            }
        }
        .onAppear {
            animatedProgress = progress
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sync progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Non-blocking Sync Status Bar

/// Compact status bar shown at the bottom during sync
/// Allows users to continue browsing while sync runs
struct SyncStatusBar: View {
    @ObservedObject var syncState: SyncState
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Animated sync icon
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: IconSize.lg, weight: .medium))
                .foregroundColor(.accentColor)
                .rotationEffect(.degrees(syncState.overallProgress * 360))
                .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: syncState.overallProgress)

            // Status info
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(syncState.statusMessage)
                    .font(AppFont.subheadline)
                    .foregroundColor(AppColors.primaryText)
                    .lineLimit(1)

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * syncState.overallProgress, height: 3)
                            .animation(.easeOut(duration: 0.3), value: syncState.overallProgress)
                    }
                }
                .frame(height: 3)
            }

            // Percentage
            Text("\(Int(syncState.overallProgress * 100))%")
                .font(AppFont.caption)
                .foregroundColor(AppColors.secondaryText)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)

            // Provider indicators (compact)
            HStack(spacing: Spacing.xs) {
                ForEach(Array(syncState.providerProgress.keys.sorted(by: { $0.displayName < $1.displayName })), id: \.self) { provider in
                    if let progress = syncState.providerProgress[provider] {
                        ProviderProgressDot(provider: provider, progress: progress)
                    }
                }
            }

            Divider()
                .frame(height: 24)

            // Cancel button
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: IconSize.sm, weight: .medium))
                    .foregroundColor(AppColors.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Cancel sync")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sync in progress")
        .accessibilityValue("\(syncState.statusMessage), \(Int(syncState.overallProgress * 100)) percent complete")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Provider Progress Dot

private struct ProviderProgressDot: View {
    let provider: Provider
    let progress: ProviderSyncProgress

    var body: some View {
        ZStack {
            Circle()
                .fill(provider.brandColor.opacity(0.2))
                .frame(width: 20, height: 20)

            statusIcon
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(provider.brandColor)
        }
        .help("\(provider.displayName): \(statusText)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch progress.phase {
        case .discovering:
            Image(systemName: "magnifyingglass")
        case .parsing:
            Image(systemName: "doc.text")
        case .saving:
            Image(systemName: "arrow.down.doc")
        case .completed:
            Image(systemName: "checkmark")
        case .failed:
            Image(systemName: "exclamationmark")
        }
    }

    private var statusText: String {
        switch progress.phase {
        case .discovering: return "Discovering..."
        case .parsing(let c, let t): return "\(c)/\(t) files"
        case .saving: return "Saving..."
        case .completed: return "Done"
        case .failed(let e): return e
        }
    }
}

// MARK: - Sync Complete Toast

/// Brief toast shown after sync completes
struct SyncCompleteToast: View {
    let stats: SyncStats
    let onDismiss: () -> Void

    @State private var isVisible = true

    var body: some View {
        if isVisible {
            HStack(spacing: Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: IconSize.lg))
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Sync Complete")
                        .font(AppFont.headline)
                        .foregroundColor(AppColors.primaryText)

                    Text("\(stats.conversationsUpdated) conversations updated")
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                }

                Spacer()

                Button {
                    dismissToast()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: IconSize.xs, weight: .medium))
                        .foregroundColor(AppColors.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear {
                // Announce to VoiceOver
                announceToVoiceOver("Sync complete. \(stats.conversationsUpdated) conversations updated.")

                // Auto-dismiss after 4 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    dismissToast()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync complete. \(stats.conversationsUpdated) conversations updated.")
            .accessibilityAddTraits(.isStaticText)
        }
    }

    private func dismissToast() {
        withAnimation(.easeOut(duration: 0.3)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onDismiss()
        }
    }
}

// MARK: - Sync Error Banner

/// Error banner shown when sync fails
struct SyncErrorBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: IconSize.lg))
                .foregroundColor(AppColors.error)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Sync Failed")
                    .font(AppFont.headline)
                    .foregroundColor(AppColors.primaryText)

                Text(message)
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
                    .lineLimit(2)
            }

            Spacer()

            Button("Retry") {
                onRetry()
            }
            .buttonStyle(.bordered)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: IconSize.xs, weight: .medium))
                    .foregroundColor(AppColors.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(AppColors.error.opacity(0.1), in: RoundedRectangle(cornerRadius: CornerRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .strokeBorder(AppColors.error.opacity(0.3), lineWidth: 1)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            // Announce error to VoiceOver
            announceToVoiceOver("Sync failed. \(message)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sync failed. \(message). Retry button available.")
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Undo Delete Toast

/// Toast shown after deleting a conversation, allowing undo
struct UndoDeleteToast: View {
    let conversationTitle: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "trash")
                .font(.system(size: IconSize.md))
                .foregroundColor(AppColors.secondaryText)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Conversation deleted")
                    .font(AppFont.headline)
                    .foregroundColor(AppColors.primaryText)

                Text(conversationTitle)
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button("Undo") {
                onUndo()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: IconSize.xs, weight: .medium))
                    .foregroundColor(AppColors.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.lg))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .onAppear {
            // Announce to VoiceOver
            announceToVoiceOver("Conversation deleted. Tap Undo to restore.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Conversation \(conversationTitle) deleted. Undo button available.")
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Preview

#Preview("Sync Overlay") {
    let state = SyncState()

    return ZStack {
        Color.gray.opacity(0.3)

        SyncOverlay(syncState: state, onCancel: {})
    }
    .onAppear {
        state.setStatus(.syncing)
        state.updateProviderProgress(.claudeCode, progress: ProviderSyncProgress(
            phase: .parsing(current: 45, total: 120),
            progress: 0.375,
            weight: 0.5,
            itemsProcessed: 45,
            totalItems: 120
        ))
        state.updateProviderProgress(.codex, progress: .discovering(weight: 0.3))
    }
}

#Preview("Sync Complete Toast") {
    VStack {
        SyncCompleteToast(
            stats: SyncStats(conversationsUpdated: 42, messagesUpdated: 1250),
            onDismiss: {}
        )
        .padding()

        Spacer()
    }
}

#Preview("Sync Error Banner") {
    VStack {
        SyncErrorBanner(
            message: "Network connection failed. Please check your internet connection.",
            onRetry: {},
            onDismiss: {}
        )
        .padding()

        Spacer()
    }
}
