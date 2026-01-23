import Foundation
import Sparkle
import SwiftUI

/// Controller for managing app updates via Sparkle
@MainActor
final class UpdateController: ObservableObject {
    /// Shared instance
    static let shared = UpdateController()

    /// The Sparkle updater controller
    private let updaterController: SPUStandardUpdaterController

    /// Expose the updater for SwiftUI integration
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// Whether automatic update checks are enabled
    var automaticUpdateChecksEnabled: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Whether automatic downloads are enabled
    var automaticDownloadsEnabled: Bool {
        get { updaterController.updater.automaticallyDownloadsUpdates }
        set { updaterController.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Update check interval in seconds (default: 1 day)
    var updateCheckInterval: TimeInterval {
        get { updaterController.updater.updateCheckInterval }
        set { updaterController.updater.updateCheckInterval = newValue }
    }

    private init() {
        // Initialize the updater controller
        // startingUpdater: true means it will start checking for updates automatically
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Check for updates manually (user-initiated)
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Check if the updater can check for updates
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
}

// MARK: - SwiftUI View for Check for Updates Menu Item

/// A view that displays a "Check for Updates..." menu item
/// This properly observes Sparkle's canCheckForUpdates state
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates...") {
            checkForUpdatesViewModel.checkForUpdates()
        }
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

/// View model that observes Sparkle's canCheckForUpdates property
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updater: SPUUpdater
    private var cancellable: Any?

    init(updater: SPUUpdater) {
        self.updater = updater

        // Observe canCheckForUpdates using KVO
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
