import Foundation
import GRDB

// MARK: - Analysis Type

/// Type of analysis to perform on conversations
enum AnalysisType: String, Codable, CaseIterable {
    case workflow   // Detect automation workflow candidates
    case learning   // Extract learning patterns and corrections
    case summary    // Generate conversation titles and summaries
    case dedupe     // Identify duplicate or similar learnings to merge
}

// MARK: - Analysis Queue Item

/// Represents a queued analysis task for CLI LLM processing
struct AnalysisQueueItem: Identifiable, Codable, FetchableRecord, PersistableRecord {
    var id: String
    var conversationId: UUID
    var analysisType: String
    var status: String  // 'pending', 'claimed', 'completed', 'failed'
    var priority: Int

    // Concurrency & claiming
    var claimedBy: String?
    var claimedAt: Date?
    var attemptCount: Int
    var maxAttempts: Int

    // Versioning
    var schemaVersion: Int
    var analysisVersion: String?
    var backend: String?  // 'claude_code', 'codex', 'gemini'
    var model: String?

    // Timestamps
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    // Results
    var resultJson: String?
    var errorMessage: String?

    // Result application tracking
    var resultsAppliedAt: Date?

    init(
        id: String = UUID().uuidString,
        conversationId: UUID,
        analysisType: String,
        status: String = "pending",
        priority: Int = 0,
        claimedBy: String? = nil,
        claimedAt: Date? = nil,
        attemptCount: Int = 0,
        maxAttempts: Int = 3,
        schemaVersion: Int = 1,
        analysisVersion: String? = nil,
        backend: String? = nil,
        model: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        resultJson: String? = nil,
        errorMessage: String? = nil,
        resultsAppliedAt: Date? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.analysisType = analysisType
        self.status = status
        self.priority = priority
        self.claimedBy = claimedBy
        self.claimedAt = claimedAt
        self.attemptCount = attemptCount
        self.maxAttempts = maxAttempts
        self.schemaVersion = schemaVersion
        self.analysisVersion = analysisVersion
        self.backend = backend
        self.model = model
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.resultJson = resultJson
        self.errorMessage = errorMessage
        self.resultsAppliedAt = resultsAppliedAt
    }

    static let databaseTableName = "analysis_queue"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let conversationId = Column(CodingKeys.conversationId)
        static let analysisType = Column(CodingKeys.analysisType)
        static let status = Column(CodingKeys.status)
        static let priority = Column(CodingKeys.priority)
        static let claimedBy = Column(CodingKeys.claimedBy)
        static let claimedAt = Column(CodingKeys.claimedAt)
        static let attemptCount = Column(CodingKeys.attemptCount)
        static let maxAttempts = Column(CodingKeys.maxAttempts)
        static let schemaVersion = Column(CodingKeys.schemaVersion)
        static let analysisVersion = Column(CodingKeys.analysisVersion)
        static let backend = Column(CodingKeys.backend)
        static let model = Column(CodingKeys.model)
        static let createdAt = Column(CodingKeys.createdAt)
        static let startedAt = Column(CodingKeys.startedAt)
        static let completedAt = Column(CodingKeys.completedAt)
        static let resultJson = Column(CodingKeys.resultJson)
        static let errorMessage = Column(CodingKeys.errorMessage)
        static let resultsAppliedAt = Column(CodingKeys.resultsAppliedAt)
    }

    // Associations
    static let conversation = belongsTo(Conversation.self)
}

// MARK: - Convenience

extension AnalysisQueueItem {
    /// Check if this item is pending
    var isPending: Bool { status == "pending" }

    /// Check if this item is claimed
    var isClaimed: Bool { status == "claimed" }

    /// Check if this item is completed
    var isCompleted: Bool { status == "completed" }

    /// Check if this item has failed
    var isFailed: Bool { status == "failed" }

    /// Check if results have been applied
    var resultsApplied: Bool { resultsAppliedAt != nil }

    /// Get the analysis type enum
    var type: AnalysisType? {
        AnalysisType(rawValue: analysisType)
    }
}

// MARK: - Analysis Suggestion

/// Represents a suggestion from LLM analysis (for dedupe/summary)
struct AnalysisSuggestion: Identifiable, Codable, FetchableRecord, PersistableRecord {
    var id: String
    var queueId: String
    var suggestionType: String  // 'title', 'summary', 'merge_learnings', 'dedupe'
    var targetId: String?       // conversation_id or learning_id being modified

    // Suggestion content
    var suggestedValue: String?
    var originalValue: String?
    var confidence: Double?
    var reasoning: String?

    // User review
    var status: String  // 'pending', 'approved', 'rejected'
    var reviewedAt: Date?
    var rejectReason: String?

    // For merge suggestions
    var mergeSourceIds: String?  // JSON array of learning IDs to merge

    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        queueId: String,
        suggestionType: String,
        targetId: String? = nil,
        suggestedValue: String? = nil,
        originalValue: String? = nil,
        confidence: Double? = nil,
        reasoning: String? = nil,
        status: String = "pending",
        reviewedAt: Date? = nil,
        rejectReason: String? = nil,
        mergeSourceIds: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.queueId = queueId
        self.suggestionType = suggestionType
        self.targetId = targetId
        self.suggestedValue = suggestedValue
        self.originalValue = originalValue
        self.confidence = confidence
        self.reasoning = reasoning
        self.status = status
        self.reviewedAt = reviewedAt
        self.rejectReason = rejectReason
        self.mergeSourceIds = mergeSourceIds
        self.createdAt = createdAt
    }

    static let databaseTableName = "analysis_suggestions"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let queueId = Column(CodingKeys.queueId)
        static let suggestionType = Column(CodingKeys.suggestionType)
        static let targetId = Column(CodingKeys.targetId)
        static let suggestedValue = Column(CodingKeys.suggestedValue)
        static let originalValue = Column(CodingKeys.originalValue)
        static let confidence = Column(CodingKeys.confidence)
        static let reasoning = Column(CodingKeys.reasoning)
        static let status = Column(CodingKeys.status)
        static let reviewedAt = Column(CodingKeys.reviewedAt)
        static let rejectReason = Column(CodingKeys.rejectReason)
        static let mergeSourceIds = Column(CodingKeys.mergeSourceIds)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    // Associations
    static let queueItem = belongsTo(AnalysisQueueItem.self, using: ForeignKey(["queueId"], to: ["id"]))
}

// MARK: - Convenience

extension AnalysisSuggestion {
    /// Check if this suggestion is pending
    var isPending: Bool { status == "pending" }

    /// Check if this suggestion is approved
    var isApproved: Bool { status == "approved" }

    /// Check if this suggestion is rejected
    var isRejected: Bool { status == "rejected" }

    /// Get merge source IDs as array
    var mergeSourceIdList: [String]? {
        guard let json = mergeSourceIds,
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return ids
    }
}

// MARK: - Analysis Result Types (for JSON parsing)

/// Result from workflow analysis
struct WorkflowAnalysisResult: Codable {
    let action: String
    let artifact: String?
    let domains: [String]?
    let confidence: Float
    let reasoning: String?
}

/// Result from learning analysis
struct LearningAnalysisResult: Codable {
    let learnings: [ExtractedLearning]

    struct ExtractedLearning: Codable {
        let type: String
        let rule: String
        let confidence: Float
        let pattern: String?
        let messageId: String?
        let context: String?
        let evidence: String?
    }
}

/// Result from summary analysis
struct SummaryAnalysisResult: Codable {
    let suggestedTitle: String
    let suggestedSummary: String?
    let confidence: Float

    enum CodingKeys: String, CodingKey {
        case suggestedTitle = "suggested_title"
        case suggestedSummary = "suggested_summary"
        case confidence
    }
}

/// Result from dedupe analysis
struct DedupeAnalysisResult: Codable {
    let mergeSuggestions: [MergeSuggestion]

    enum CodingKeys: String, CodingKey {
        case mergeSuggestions = "merge_suggestions"
    }
}

/// Suggestion to merge multiple learnings
struct MergeSuggestion: Codable {
    let sourceIds: [String]
    let mergedRule: String
    let confidence: Float
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case sourceIds = "source_ids"
        case mergedRule = "merged_rule"
        case confidence
        case reasoning
    }
}

// MARK: - Batch Result Types (Per-Item Output with queue_id)

/// Batch result wrapper for workflow analysis - one per queue item
struct WorkflowBatchResult: Codable {
    let queueId: String
    let action: String
    let artifact: String?
    let domains: [String]?
    let confidence: Float
    let reasoning: String?

    enum CodingKeys: String, CodingKey {
        case queueId = "queue_id"
        case action, artifact, domains, confidence, reasoning
    }

    /// Convert to standard result format for storage
    func toResultJSON() throws -> String {
        let result = WorkflowAnalysisResult(
            action: action,
            artifact: artifact,
            domains: domains,
            confidence: confidence,
            reasoning: reasoning
        )
        let data = try JSONEncoder().encode(result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Batch result wrapper for learning analysis - one per queue item
struct LearningBatchResult: Codable {
    let queueId: String
    let learnings: [LearningAnalysisResult.ExtractedLearning]

    enum CodingKeys: String, CodingKey {
        case queueId = "queue_id"
        case learnings
    }

    /// Convert to standard result format for storage
    func toResultJSON() throws -> String {
        let result = LearningAnalysisResult(learnings: learnings)
        let data = try JSONEncoder().encode(result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Batch result wrapper for summary analysis - one per queue item
struct SummaryBatchResult: Codable {
    let queueId: String
    let suggestedTitle: String
    let suggestedSummary: String?
    let confidence: Float

    enum CodingKeys: String, CodingKey {
        case queueId = "queue_id"
        case suggestedTitle = "suggested_title"
        case suggestedSummary = "suggested_summary"
        case confidence
    }

    /// Convert to standard result format for storage
    func toResultJSON() throws -> String {
        let result = SummaryAnalysisResult(
            suggestedTitle: suggestedTitle,
            suggestedSummary: suggestedSummary,
            confidence: confidence
        )
        let data = try JSONEncoder().encode(result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Batch result wrapper for dedupe analysis - one per queue item
struct DedupeBatchResult: Codable {
    let queueId: String
    let mergeSuggestions: [MergeSuggestion]

    enum CodingKeys: String, CodingKey {
        case queueId = "queue_id"
        case mergeSuggestions = "merge_suggestions"
    }

    /// Convert to standard result format for storage
    func toResultJSON() throws -> String {
        let result = DedupeAnalysisResult(mergeSuggestions: mergeSuggestions)
        let data = try JSONEncoder().encode(result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - JSON Schemas for LLM Output

extension AnalysisType {
    /// JSON schema string for per-item batch output
    /// Each schema returns an array with queue_id for mapping results to queue items
    var jsonSchemaString: String {
        switch self {
        case .workflow:
            return """
            {"type":"array","items":{"type":"object","properties":{"queue_id":{"type":"string"},"action":{"type":"string"},"artifact":{"type":"string"},"domains":{"type":"array","items":{"type":"string"}},"confidence":{"type":"number"},"reasoning":{"type":"string"}},"required":["queue_id","action","confidence"]}}
            """
        case .learning:
            return """
            {"type":"array","items":{"type":"object","properties":{"queue_id":{"type":"string"},"learnings":{"type":"array","items":{"type":"object","properties":{"type":{"type":"string"},"rule":{"type":"string"},"confidence":{"type":"number"},"pattern":{"type":"string"},"messageId":{"type":"string"},"context":{"type":"string"}},"required":["type","rule","confidence"]}}},"required":["queue_id","learnings"]}}
            """
        case .summary:
            return """
            {"type":"array","items":{"type":"object","properties":{"queue_id":{"type":"string"},"suggested_title":{"type":"string"},"suggested_summary":{"type":"string"},"confidence":{"type":"number"}},"required":["queue_id","suggested_title","confidence"]}}
            """
        case .dedupe:
            return """
            {"type":"array","items":{"type":"object","properties":{"queue_id":{"type":"string"},"merge_suggestions":{"type":"array","items":{"type":"object","properties":{"source_ids":{"type":"array","items":{"type":"string"}},"merged_rule":{"type":"string"},"confidence":{"type":"number"},"reasoning":{"type":"string"}},"required":["source_ids","merged_rule","confidence"]}}},"required":["queue_id","merge_suggestions"]}}
            """
        }
    }
}
