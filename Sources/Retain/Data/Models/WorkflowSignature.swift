import Foundation
import GRDB

/// Deterministic workflow signature derived from a conversation
struct WorkflowSignature: Identifiable, Codable, FetchableRecord, PersistableRecord {
    var id: UUID
    var conversationId: UUID
    var signature: String
    var action: String
    var artifact: String
    var domains: String
    var snippet: String
    var version: Int
    var createdAt: Date
    var updatedAt: Date

    // CLI LLM Integration - idempotency tracking
    var sourceQueueId: String?  // Links to analysis_queue for CLI-extracted workflows
    var confidence: Double?     // LLM confidence score

    // Provenance
    var source: String?         // deterministic | gemini | cli
    var detectorVersion: String? // e.g., workflow-det-v2
    var isPriming: Bool         // True for context-priming signatures

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        signature: String,
        action: String,
        artifact: String,
        domains: String,
        snippet: String,
        version: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceQueueId: String? = nil,
        confidence: Double? = nil,
        source: String? = nil,
        detectorVersion: String? = nil,
        isPriming: Bool = false
    ) {
        self.id = id
        self.conversationId = conversationId
        self.signature = signature
        self.action = action
        self.artifact = artifact
        self.domains = domains
        self.snippet = snippet
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceQueueId = sourceQueueId
        self.confidence = confidence
        self.source = source
        self.detectorVersion = detectorVersion
        self.isPriming = isPriming
    }

    static let databaseTableName = "workflow_signatures"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let conversationId = Column(CodingKeys.conversationId)
        static let signature = Column(CodingKeys.signature)
        static let action = Column(CodingKeys.action)
        static let artifact = Column(CodingKeys.artifact)
        static let domains = Column(CodingKeys.domains)
        static let snippet = Column(CodingKeys.snippet)
        static let version = Column(CodingKeys.version)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let sourceQueueId = Column(CodingKeys.sourceQueueId)
        static let confidence = Column(CodingKeys.confidence)
        static let source = Column(CodingKeys.source)
        static let detectorVersion = Column(CodingKeys.detectorVersion)
        static let isPriming = Column(CodingKeys.isPriming)
    }

    var domainList: [String] {
        domains.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
    }
}

// MARK: - Aggregates

struct WorkflowCluster: Identifiable, Hashable {
    var id: String { signature }
    let signature: String
    let action: String
    let artifact: String
    let domains: [String]
    let count: Int
    let distinctProjects: Int
    let samples: [WorkflowClusterSample]
}

struct WorkflowClusterSample: Identifiable, Hashable {
    let id = UUID()
    let sourceType: String
    let projectPath: String?
    let snippet: String
}

// MARK: - Display Helpers

extension WorkflowCluster {
    var displayTitle: String {
        WorkflowDisplayFormatter.title(action: action, artifact: artifact, domains: domains)
    }

    var displaySignature: String {
        let parts = signature.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cleaned = parts.filter { !$0.isEmpty }
        if cleaned.isEmpty {
            return signature
        }
        return cleaned.joined(separator: " | ")
    }

    var automationIdea: String {
        if action == "prime" {
            return "Setup prompt only (context priming, excluded)."
        }
        return "Reusable prompt to \(displayTitle.lowercased())."
    }
}

private enum WorkflowDisplayFormatter {
    static func title(action: String, artifact: String, domains: [String]) -> String {
        let normalizedAction = normalizeToken(action)
        if normalizedAction == "prime" {
            return "Context priming"
        }

        let verb = verbPhrase(normalizedAction)
        let artifactLabel = artifactText(artifact)
        let domainLabel = domains.first.map { domainText($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let object = buildObject(action: normalizedAction, artifact: artifactLabel, domain: domainLabel)

        if object.isEmpty {
            return verb
        }
        return "\(verb) \(object)"
    }

    private static func buildObject(action: String, artifact: String?, domain: String?) -> String {
        var artifact = artifact
        if let current = artifact, isMorphologicalDuplicate(action: action, artifact: current) {
            artifact = nil
        }

        if var artifact {
            if let domain, !domain.isEmpty, !artifact.lowercased().contains(domain.lowercased()) {
                artifact = "\(domain) \(artifact)"
            }
            return artifact
        }

        if let domain, !domain.isEmpty {
            if action == "translate" {
                return "\(domain) text"
            }
            if domain == "meeting" {
                return "meeting discussion"
            }
            if action == "analyze" {
                return domain
            }
            return "\(domain) requests"
        }

        return defaultObject(for: action)
    }

    private static func verbPhrase(_ action: String) -> String {
        switch action {
        case "summarize": return "Summarize"
        case "translate": return "Translate"
        case "research": return "Research"
        case "write": return "Write"
        case "review": return "Review"
        case "fix": return "Fix"
        case "debug": return "Debug"
        case "plan": return "Plan"
        case "design": return "Design"
        case "analyze": return "Analyze"
        case "extract": return "Extract"
        case "organize": return "Organize"
        case "prepare": return "Prepare"
        default: return titleCase(action)
        }
    }

    private static func defaultObject(for action: String) -> String {
        switch action {
        case "translate": return "text"
        case "debug", "fix": return "issue"
        case "review": return "work"
        case "summarize": return "content"
        case "analyze": return "topic"
        case "research": return "topic"
        case "write": return "draft"
        case "plan": return "plan"
        case "design": return "design"
        case "prepare": return "materials"
        case "extract": return "data"
        case "organize": return "info"
        default: return "requests"
        }
    }

    private static func artifactText(_ value: String) -> String? {
        let normalized = normalizeToken(value)
        if normalized.isEmpty || normalized == "none" {
            return nil
        }

        if normalized.hasPrefix("workflow_") {
            let topic = normalized.replacingOccurrences(of: "workflow_", with: "")
            if !topic.isEmpty {
                return "\(topic) workflow"
            }
        }

        if normalized.hasPrefix("plan_") {
            let topic = normalized.replacingOccurrences(of: "plan_", with: "")
            if !topic.isEmpty {
                return "\(topic) plan"
            }
        }

        switch normalized {
        case "deck": return "slide deck"
        case "documentation": return "docs"
        case "landing_page": return "landing page"
        default: return normalized.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func isMorphologicalDuplicate(action: String, artifact: String) -> Bool {
        let normalizedAction = normalizeToken(action)
        let normalizedArtifact = normalizeToken(artifact)
        if normalizedAction == normalizedArtifact {
            return true
        }

        let duplicates: [String: Set<String>] = [
            "analyze": ["analysis"],
            "summarize": ["summary"],
            "translate": ["translation"],
            "extract": ["extraction"],
            "prepare": ["preparation"],
            "organize": ["organization"],
            "review": ["review"],
            "plan": ["plan"],
            "design": ["design"]
        ]

        if let values = duplicates[normalizedAction], values.contains(normalizedArtifact) {
            return true
        }

        return false
    }

    private static func domainText(_ value: String) -> String {
        let normalized = normalizeToken(value)
        if normalized == "none" {
            return ""
        }

        switch normalized {
        case "product_management": return "product"
        case "customer_support": return "support"
        default: return normalized.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func normalizeToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func titleCase(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Workflow"
        }
        return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
