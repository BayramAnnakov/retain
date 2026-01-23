import Foundation
import SwiftUI

/// Protocol defining a provider's configuration for the registry
/// This centralizes all provider-specific information in one place
protocol ProviderConfiguration {
    /// The provider enum case
    var provider: Provider { get }

    /// Display name shown in UI
    var displayName: String { get }

    /// SF Symbol icon name
    var iconName: String { get }

    /// Brand color for UI elements
    var brandColor: Color { get }

    /// Whether this provider is currently supported
    var isSupported: Bool { get }

    /// Whether this is a web-based provider (vs CLI)
    var isWebProvider: Bool { get }

    /// Data directory path for CLI providers (nil for web providers)
    var dataPath: URL? { get }

    /// File pattern to watch (e.g., "*.jsonl")
    var filePattern: String? { get }

    /// AppStorage key for enabled toggle
    var enabledKey: String { get }

    /// Short description of the data source
    var sourceDescription: String { get }

    /// Check if this CLI tool is installed
    func detectInstallation() -> ProviderInstallStatus
}

/// Status of a provider's installation
enum ProviderInstallStatus {
    case installed(version: String?)
    case notInstalled
    case unknown

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

// MARK: - Default Implementations

extension ProviderConfiguration {
    /// Default implementation for web providers
    var dataPath: URL? { nil }

    /// Default implementation for web providers
    var filePattern: String? { nil }

    /// Default detection for providers without CLI
    func detectInstallation() -> ProviderInstallStatus {
        if isWebProvider {
            return .unknown
        }
        guard let path = dataPath else { return .notInstalled }
        return FileManager.default.fileExists(atPath: path.path) ? .installed(version: nil) : .notInstalled
    }
}
