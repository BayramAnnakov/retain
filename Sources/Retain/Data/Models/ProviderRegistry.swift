import Foundation
import SwiftUI

/// Central registry for all provider configurations
/// Adding a new provider only requires creating a config struct and registering it here
enum ProviderRegistry {
    /// All registered provider configurations
    static let all: [ProviderConfiguration] = [
        ClaudeCodeProviderConfig(),
        CodexProviderConfig(),
        OpenCodeProviderConfig(),
        GeminiCLIProviderConfig(),
        CursorProviderConfig(),
        ClaudeWebProviderConfig(),
        ChatGPTWebProviderConfig(),
        GeminiProviderConfig(),
    ]

    /// Only supported providers
    static var supported: [ProviderConfiguration] {
        all.filter { $0.isSupported }
    }

    /// CLI-based providers only (local data sources)
    static var cliProviders: [ProviderConfiguration] {
        supported.filter { !$0.isWebProvider }
    }

    /// Web-based providers only
    static var webProviders: [ProviderConfiguration] {
        supported.filter { $0.isWebProvider }
    }

    /// Get configuration for a specific provider
    static func config(for provider: Provider) -> ProviderConfiguration? {
        all.first { $0.provider == provider }
    }

    /// All enabled keys for @AppStorage bindings
    static var allEnabledKeys: [String] {
        all.map { $0.enabledKey }
    }
}

// MARK: - Claude Code Configuration

struct ClaudeCodeProviderConfig: ProviderConfiguration {
    let provider = Provider.claudeCode
    let displayName = "Claude Code"
    let iconName = "terminal"
    let brandColor = Color.orange
    let isSupported = true
    let isWebProvider = false
    let enabledKey = "claudeCodeEnabled"
    let sourceDescription = "~/.claude/projects/"

    var dataPath: URL? {
        ClaudeCodeParser.projectsDirectory
    }

    var filePattern: String? { "*.jsonl" }

    func detectInstallation() -> ProviderInstallStatus {
        let claudePath = "/usr/local/bin/claude"
        let homebrewPath = "\(NSHomeDirectory())/.local/bin/claude"

        if FileManager.default.fileExists(atPath: claudePath) ||
           FileManager.default.fileExists(atPath: homebrewPath) {
            return .installed(version: nil)
        }

        // Check if data directory exists (might be installed but not in PATH)
        if let path = dataPath, FileManager.default.fileExists(atPath: path.path) {
            return .installed(version: nil)
        }

        return .notInstalled
    }
}

// MARK: - Codex Configuration

struct CodexProviderConfig: ProviderConfiguration {
    let provider = Provider.codex
    let displayName = "Codex"
    let iconName = "command"
    let brandColor = Color.blue
    let isSupported = true
    let isWebProvider = false
    let enabledKey = "codexEnabled"
    let sourceDescription = "~/.codex/sessions/"

    var dataPath: URL? {
        CodexParser.codexDirectory
    }

    var filePattern: String? { "*.jsonl" }

    func detectInstallation() -> ProviderInstallStatus {
        let codexPath = "/usr/local/bin/codex"

        if FileManager.default.fileExists(atPath: codexPath) {
            return .installed(version: nil)
        }

        // Check if data directory exists
        if let path = dataPath, FileManager.default.fileExists(atPath: path.path) {
            return .installed(version: nil)
        }

        return .notInstalled
    }
}

// MARK: - Claude Web Configuration

struct ClaudeWebProviderConfig: ProviderConfiguration {
    let provider = Provider.claudeWeb
    let displayName = "Claude"
    let iconName = "globe"
    let brandColor = Color.orange
    let isSupported = true
    let isWebProvider = true
    let enabledKey = "claudeWebEnabled"
    let sourceDescription = "claude.ai"
}

// MARK: - ChatGPT Web Configuration

struct ChatGPTWebProviderConfig: ProviderConfiguration {
    let provider = Provider.chatgptWeb
    let displayName = "ChatGPT"
    let iconName = "bubble.left.and.bubble.right"
    let brandColor = Color.green
    let isSupported = true
    let isWebProvider = true
    let enabledKey = "chatgptWebEnabled"
    let sourceDescription = "chatgpt.com"
}

// MARK: - Gemini Web Configuration (Not Yet Supported)

struct GeminiProviderConfig: ProviderConfiguration {
    let provider = Provider.gemini
    let displayName = "Gemini"
    let iconName = "sparkles"
    let brandColor = Color.purple
    let isSupported = false  // Not yet implemented
    let isWebProvider = true
    let enabledKey = "geminiEnabled"
    let sourceDescription = "gemini.google.com"
}

// MARK: - OpenCode Configuration

struct OpenCodeProviderConfig: ProviderConfiguration {
    let provider = Provider.opencode
    let displayName = "OpenCode"
    let iconName = "chevron.left.slash.chevron.right"
    let brandColor = Color.cyan
    let isSupported = false  // Parser not yet implemented
    let isWebProvider = false
    let enabledKey = "opencodeEnabled"
    let sourceDescription = "~/.local/share/opencode/storage/"

    var dataPath: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/storage")
    }

    var filePattern: String? { "*.json" }

    func detectInstallation() -> ProviderInstallStatus {
        guard let path = dataPath, FileManager.default.fileExists(atPath: path.path) else {
            return .notInstalled
        }
        return .installed(version: nil)
    }
}

// MARK: - Gemini CLI Configuration

struct GeminiCLIProviderConfig: ProviderConfiguration {
    let provider = Provider.geminiCLI
    let displayName = "Gemini CLI"
    let iconName = "sparkle"
    let brandColor = Color.indigo
    let isSupported = false  // Parser not yet implemented
    let isWebProvider = false
    let enabledKey = "geminiCLIEnabled"
    let sourceDescription = "~/.gemini/tmp/"

    var dataPath: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp")
    }

    var filePattern: String? { "*.json" }

    func detectInstallation() -> ProviderInstallStatus {
        guard let path = dataPath, FileManager.default.fileExists(atPath: path.path) else {
            return .notInstalled
        }
        return .installed(version: nil)
    }
}

// MARK: - Cursor Configuration

struct CursorProviderConfig: ProviderConfiguration {
    let provider = Provider.cursor
    let displayName = "Cursor"
    let iconName = "cursorarrow.rays"
    let brandColor = Color.pink
    let isSupported = false  // Parser not yet implemented, storage location unknown
    let isWebProvider = false
    let enabledKey = "cursorEnabled"
    let sourceDescription = "Cursor AI IDE"

    var dataPath: URL? {
        // Cursor storage location needs investigation
        // Possibly in ~/Library/Application Support/Cursor/
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor")
    }

    func detectInstallation() -> ProviderInstallStatus {
        guard let path = dataPath, FileManager.default.fileExists(atPath: path.path) else {
            return .notInstalled
        }
        return .installed(version: nil)
    }
}

// MARK: - Parser Adapters (TODO: implement when refactoring SyncService)
//
// The existing ClaudeCodeParser and CodexParser have different APIs.
// When we refactor SyncService to use the registry, we'll add adapters here.
// For now, the registry provides configuration only.
