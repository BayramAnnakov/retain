import Foundation
import GRDB

/// A learning extracted from conversation corrections or patterns
struct Learning: Identifiable, Equatable, Hashable {
    var id: UUID
    var conversationId: UUID
    var messageId: UUID?
    var type: LearningType
    var pattern: String          // What triggered detection (e.g., "no, use X")
    var extractedRule: String    // The learned preference
    var normalizedRule: String?  // Normalized rule for dedupe
    var confidence: Float        // Detection confidence (0.0 - 1.0)
    var context: String?         // Surrounding context for review
    var evidence: String?        // Exact quote snippet that triggered extraction
    var evidenceCount: Int       // Number of times this learning was detected
    var status: LearningStatus
    var scope: LearningScope
    var createdAt: Date
    var lastDetectedAt: Date?
    var reviewedAt: Date?

    // CLI LLM Integration - idempotency tracking
    var sourceQueueId: String?  // Links to analysis_queue for CLI-extracted learnings
    var ruleHash: Int?          // Hash of rule for duplicate detection

    // Provenance
    var source: String?         // deterministic | gemini | cli
    var detectorVersion: String? // e.g., deterministic-v2

    init(
        id: UUID = UUID(),
        conversationId: UUID,
        messageId: UUID?,
        type: LearningType,
        pattern: String,
        extractedRule: String,
        normalizedRule: String? = nil,
        confidence: Float = 0.8,
        context: String? = nil,
        evidence: String? = nil,
        evidenceCount: Int = 1,
        status: LearningStatus = .pending,
        scope: LearningScope = .global,
        createdAt: Date = Date(),
        lastDetectedAt: Date? = nil,
        reviewedAt: Date? = nil,
        sourceQueueId: String? = nil,
        ruleHash: Int? = nil,
        source: String? = nil,
        detectorVersion: String? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.messageId = messageId
        self.type = type
        self.pattern = pattern
        self.extractedRule = extractedRule
        self.normalizedRule = normalizedRule
        self.confidence = confidence
        self.context = context
        self.evidence = evidence
        self.evidenceCount = evidenceCount
        self.status = status
        self.scope = scope
        self.createdAt = createdAt
        self.lastDetectedAt = lastDetectedAt
        self.reviewedAt = reviewedAt
        self.sourceQueueId = sourceQueueId
        self.ruleHash = ruleHash
        self.source = source
        self.detectorVersion = detectorVersion
    }
}

// MARK: - GRDB Support

extension Learning: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "learnings"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let conversationId = Column(CodingKeys.conversationId)
        static let messageId = Column(CodingKeys.messageId)
        static let type = Column(CodingKeys.type)
        static let pattern = Column(CodingKeys.pattern)
        static let extractedRule = Column(CodingKeys.extractedRule)
        static let normalizedRule = Column(CodingKeys.normalizedRule)
        static let confidence = Column(CodingKeys.confidence)
        static let context = Column(CodingKeys.context)
        static let evidence = Column(CodingKeys.evidence)
        static let evidenceCount = Column(CodingKeys.evidenceCount)
        static let status = Column(CodingKeys.status)
        static let scope = Column(CodingKeys.scope)
        static let createdAt = Column(CodingKeys.createdAt)
        static let lastDetectedAt = Column(CodingKeys.lastDetectedAt)
        static let reviewedAt = Column(CodingKeys.reviewedAt)
        static let sourceQueueId = Column(CodingKeys.sourceQueueId)
        static let ruleHash = Column(CodingKeys.ruleHash)
        static let source = Column(CodingKeys.source)
        static let detectorVersion = Column(CodingKeys.detectorVersion)
    }

    // Associations
    static let conversation = belongsTo(Conversation.self)
    static let message = belongsTo(Message.self)
}

// MARK: - Convenience

extension Learning {
    /// Check if this learning is pending review
    var isPending: Bool {
        status == .pending
    }

    /// Mark as approved
    mutating func approve() {
        status = .approved
        reviewedAt = Date()
    }

    /// Mark as rejected
    mutating func reject() {
        status = .rejected
        reviewedAt = Date()
    }
}
