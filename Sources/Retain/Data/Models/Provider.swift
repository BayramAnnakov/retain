import Foundation
import SwiftUI

/// AI provider/platform that conversations originate from
enum Provider: String, Codable, CaseIterable {
    case claudeCode = "claude_code"
    case claudeWeb = "claude_web"
    case chatgptWeb = "chatgpt_web"
    case codex = "codex"
    case gemini = "gemini"
    case opencode = "opencode"
    case geminiCLI = "gemini_cli"
    case cursor = "cursor"

    /// Get the configuration for this provider from the registry
    var configuration: ProviderConfiguration? {
        ProviderRegistry.config(for: self)
    }

    var displayName: String {
        configuration?.displayName ?? rawValue
    }

    var iconName: String {
        configuration?.iconName ?? "questionmark"
    }

    var color: Color {
        configuration?.brandColor ?? .gray
    }

    /// Whether this provider is currently supported
    var isSupported: Bool {
        configuration?.isSupported ?? false
    }

    /// Whether this provider is a web source
    var isWebProvider: Bool {
        configuration?.isWebProvider ?? false
    }

    /// Data path for CLI providers
    var dataPath: URL? {
        configuration?.dataPath
    }

    /// AppStorage key for enabled toggle
    var enabledKey: String {
        configuration?.enabledKey ?? "\(rawValue)Enabled"
    }
}

/// How the conversation was captured
enum SourceType: String, Codable {
    case cli = "cli"           // Local CLI tool (Claude Code, Codex)
    case web = "web"           // Web API via WebView sync
    case importFile = "import" // Manual import from export file
}

/// Message author role
enum Role: String, Codable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
    case tool = "tool"
}

/// Learning type detected from conversations
enum LearningType: String, Codable {
    case correction = "correction"  // "No, use X instead"
    case positive = "positive"      // "Perfect!", "Exactly"
    case implicit = "implicit"      // Inferred from patterns
}

/// Learning status in review queue
enum LearningStatus: String, Codable {
    case pending = "pending"
    case approved = "approved"
    case rejected = "rejected"
}

/// Learning scope for export
enum LearningScope: String, Codable, CaseIterable, Hashable {
    case global = "global"   // Goes to ~/.claude/CLAUDE.md
    case project = "project" // Goes to ./CLAUDE.md

    var displayName: String {
        switch self {
        case .global: return "Global"
        case .project: return "Project"
        }
    }

    var iconName: String {
        switch self {
        case .global: return "globe"
        case .project: return "folder"
        }
    }

    var description: String {
        switch self {
        case .global: return "Applies to all projects (~/.claude/CLAUDE.md)"
        case .project: return "Applies only to this project (./CLAUDE.md)"
        }
    }
}

/// Learning extraction mode
enum LearningExtractionMode: String, Codable, CaseIterable {
    case deterministic = "deterministic"
    case semantic = "semantic"
    case hybrid = "hybrid"

    var displayName: String {
        switch self {
        case .deterministic: return "Pattern Matching"
        case .semantic: return "AI Analysis"
        case .hybrid: return "Hybrid"
        }
    }

    var description: String {
        switch self {
        case .deterministic:
            return "Local regex patterns (no cloud)"
        case .semantic:
            return "Cloud AI analysis via Gemini (recommended)"
        case .hybrid:
            return "AI analysis + local patterns"
        }
    }
}
