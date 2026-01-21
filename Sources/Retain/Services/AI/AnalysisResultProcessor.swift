import Foundation
import GRDB
import CryptoKit

/// Validates LLM JSON output and persists to final tables
/// LLM NEVER writes directly - this is the only path to DB
/// CRITICAL: All operations are idempotent and transactional
final class AnalysisResultProcessor {
    private let database: AppDatabase
    private let learningRepository: LearningRepository
    private let workflowRepository: WorkflowSignatureRepository

    init(
        database: AppDatabase = .shared,
        learningRepository: LearningRepository = LearningRepository(),
        workflowRepository: WorkflowSignatureRepository = WorkflowSignatureRepository()
    ) {
        self.database = database
        self.learningRepository = learningRepository
        self.workflowRepository = workflowRepository
    }

    // MARK: - Main Processing

    /// Process completed analysis - validate JSON and persist in single transaction
    /// Idempotent: Uses queue_id as source-of-truth key to prevent duplicates
    func processCompletedAnalysis(_ queueItem: AnalysisQueueItem) throws {
        guard let resultJSON = queueItem.resultJson else {
            throw ProcessingError.noResultJSON
        }

        guard let analysisType = queueItem.type else {
            throw ProcessingError.unknownAnalysisType(queueItem.analysisType)
        }

        let provenance = resolveProvenance(for: queueItem)

        // Single transaction: persist results + mark applied atomically
        // If any step fails, entire transaction rolls back
        try database.write { db in
            // Check if already applied (idempotency check)
            let existing = try AnalysisQueueItem
                .filter(AnalysisQueueItem.Columns.id == queueItem.id)
                .filter(AnalysisQueueItem.Columns.resultsAppliedAt != nil)
                .fetchOne(db)

            if existing != nil {
                // Already applied - skip silently (idempotent)
                return
            }

            let isMeta = isMetaConversation(db: db, conversationId: queueItem.conversationId)
            let shouldSkip = isMeta && (analysisType == .workflow || analysisType == .learning)

            // Persist results based on type
            if !shouldSkip {
                switch analysisType {
                case .workflow:
                    let result = try validateAndDecode(WorkflowAnalysisResult.self, from: resultJSON)
                    try persistWorkflowResults(
                        db: db,
                        result: result,
                        queueId: queueItem.id,
                        conversationId: queueItem.conversationId,
                        source: provenance.source,
                        detectorVersion: provenance.detectorVersion
                    )

                case .learning:
                    let result = try validateAndDecode(LearningAnalysisResult.self, from: resultJSON)
                    try persistLearningResults(
                        db: db,
                        result: result,
                        queueId: queueItem.id,
                        conversationId: queueItem.conversationId,
                        source: provenance.source,
                        detectorVersion: provenance.detectorVersion
                    )

                case .summary:
                    let result = try validateAndDecode(SummaryAnalysisResult.self, from: resultJSON)
                    try createSuggestion(
                        db: db,
                        queueId: queueItem.id,
                        type: "title",
                        targetId: queueItem.conversationId.uuidString,
                        suggestedValue: result.suggestedTitle,
                        originalValue: nil,
                        confidence: Double(result.confidence),
                        reasoning: nil
                    )
                    if let summary = result.suggestedSummary {
                        try createSuggestion(
                            db: db,
                            queueId: queueItem.id,
                            type: "summary",
                            targetId: queueItem.conversationId.uuidString,
                            suggestedValue: summary,
                            originalValue: nil,
                            confidence: Double(result.confidence),
                            reasoning: nil
                        )
                    }

                case .dedupe:
                    let result = try validateAndDecode(DedupeAnalysisResult.self, from: resultJSON)
                    for merge in result.mergeSuggestions {
                        try createMergeSuggestion(db: db, queueId: queueItem.id, merge: merge)
                    }
                }
            }

            // Mark as applied in same transaction
            try db.execute(
                sql: "UPDATE analysis_queue SET resultsAppliedAt = ? WHERE id = ?",
                arguments: [Date(), queueItem.id]
            )
        }
    }

    /// Process all unprocessed completed items
    func processAllUnprocessed() throws -> Int {
        let repository = AnalysisQueueRepository(database: database)
        let unprocessed = try repository.fetchUnprocessedCompleted()

        var processedCount = 0
        for item in unprocessed {
            do {
                try processCompletedAnalysis(item)
                processedCount += 1
            } catch let error as ProcessingError {
                // Non-retryable errors (invalid JSON, decode failures, etc.)
                // Mark as failed to prevent infinite retry
                switch error {
                case .invalidJSON, .decodingFailed, .unknownAnalysisType, .noResultJSON:
                    try? repository.markResultApplicationFailed(
                        id: item.id,
                        error: error.localizedDescription
                    )
                    #if DEBUG
                    print("Marked analysis result \(item.id) as failed (non-retryable): \(error)")
                    #endif
                default:
                    #if DEBUG
                    print("Failed to process analysis result \(item.id): \(error)")
                    #endif
                }
            } catch {
                // Unexpected errors - log but don't mark as failed (may be transient)
                #if DEBUG
                print("Unexpected error processing analysis result \(item.id): \(error)")
                #endif
            }
        }

        return processedCount
    }

    // MARK: - Workflow Results

    /// Persist workflow results with queue_id foreign key (prevents duplicates)
    private func persistWorkflowResults(
        db: Database,
        result: WorkflowAnalysisResult,
        queueId: String,
        conversationId: UUID,
        source: String?,
        detectorVersion: String?
    ) throws {
        // Check for existing workflow from this queue item (idempotency)
        let existing = try WorkflowSignature
            .filter(WorkflowSignature.Columns.sourceQueueId == queueId)
            .fetchOne(db)

        guard existing == nil else { return }

        guard let sanitized = WorkflowTaxonomy.sanitize(
            action: result.action,
            artifact: result.artifact,
            domains: result.domains,
            confidence: result.confidence
        ) else {
            return
        }

        let contextText = workflowContextText(db: db, conversationId: conversationId)
        let refinedArtifact = WorkflowSignatureRefiner.refineArtifact(
            action: sanitized.action,
            artifact: sanitized.artifact,
            domains: sanitized.domains,
            context: contextText
        )

        // Build signature from action + artifact + domains
        let domainsString = sanitized.domains.joined(separator: ",")
        let derivedArtifact = WorkflowSignatureRefiner.deriveArtifactIfNeeded(
            action: sanitized.action,
            artifact: refinedArtifact ?? sanitized.artifact,
            domains: sanitized.domains,
            context: contextText,
            snippet: result.reasoning
        )
        guard let artifact = derivedArtifact?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artifact.isEmpty else {
            return
        }

        if WorkflowSignatureRefiner.shouldExcludeCandidate(
            action: sanitized.action,
            artifact: artifact,
            domains: sanitized.domains,
            snippet: result.reasoning,
            context: contextText
        ) {
            return
        }
        let signature = "\(sanitized.action)|\(artifact)|\(domainsString)".lowercased()
        let isPriming = sanitized.action == "prime"

        var workflow = WorkflowSignature(
            id: UUID(),
            conversationId: conversationId,
            signature: signature,
            action: sanitized.action,
            artifact: artifact,
            domains: domainsString,
            snippet: result.reasoning ?? "",
            version: 1,
            createdAt: Date(),
            updatedAt: Date(),
            sourceQueueId: queueId,
            confidence: Double(result.confidence),
            source: source,
            detectorVersion: detectorVersion,
            isPriming: isPriming
        )

        try workflow.insert(db)
    }

    private func workflowContextText(db: Database, conversationId: UUID) -> String {
        var parts: [String] = []
        if let conversation = try? Conversation.fetchOne(db, key: conversationId) {
            parts.append(contentsOf: [conversation.title, conversation.summary, conversation.previewText].compactMap { $0 })
        }

        let firstUserMessage: String? = try? String.fetchOne(
            db,
            sql: """
                SELECT content
                FROM messages
                WHERE conversationId = ? AND role = ?
                ORDER BY timestamp ASC
                LIMIT 1
                """,
            arguments: [conversationId, Role.user.rawValue]
        )
        if let firstUserMessage {
            parts.append(firstUserMessage)
        }

        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Learning Results

    /// Persist learning results with queue_id foreign key (prevents duplicates)
    private func persistLearningResults(
        db: Database,
        result: LearningAnalysisResult,
        queueId: String,
        conversationId: UUID,
        source: String?,
        detectorVersion: String?
    ) throws {
        for learning in result.learnings {
            let learningType = LearningType(rawValue: learning.type) ?? .implicit
            if !LearningRuleNormalizer.shouldStoreLearning(
                rule: learning.rule,
                type: learningType,
                confidence: learning.confidence
            ) {
                continue
            }

            guard let evidenceInfo = validateEvidence(
                db: db,
                conversationId: conversationId,
                learning: learning
            ) else {
                continue
            }

            let normalizedRule = LearningRuleNormalizer.normalize(learning.rule)
            let isTaskSpecific = LearningRuleNormalizer.isTaskSpecific(learning.rule)
            let scope = isTaskSpecific ? .project : resolveScope(
                db: db,
                conversationId: conversationId,
                normalizedRule: normalizedRule,
                extractedRule: learning.rule,
                type: learningType
            )

            // Compute deterministic rule hash for deduplication (SHA256-based)
            let ruleHash = deterministicHash(learning.rule)

            // Merge preference-like learnings across conversations (implicit/positive)
            if learningType == .implicit || learningType == .positive {
                if var existing = try Learning
                    .filter(Learning.Columns.normalizedRule == normalizedRule ||
                            Learning.Columns.extractedRule == learning.rule)
                    .filter(Learning.Columns.type == learningType.rawValue)
                    .filter(Learning.Columns.status != LearningStatus.rejected.rawValue)
                    .fetchOne(db) {
                    if existing.sourceQueueId == queueId {
                        continue
                    }
                    existing.confidence = max(existing.confidence, learning.confidence)
                    existing.evidenceCount += 1
                    existing.lastDetectedAt = Date()
                    if existing.context == nil {
                        existing.context = learning.context
                    }
                    if existing.evidence == nil {
                        existing.evidence = evidenceInfo.evidence
                    }
                    if existing.scope == .project, scope == .global {
                        existing.scope = .global
                    }
                    if existing.source == nil {
                        existing.source = source
                    }
                    if existing.detectorVersion == nil {
                        existing.detectorVersion = detectorVersion
                    }
                    try existing.update(db)
                    continue
                }
            }

            // Check for existing learning from this queue item + rule hash (idempotency)
            let existing = try Learning
                .filter(Learning.Columns.sourceQueueId == queueId)
                .filter(Learning.Columns.ruleHash == ruleHash)
                .fetchOne(db)

            guard existing == nil else { continue }
            let evidence = evidenceInfo.evidence
            let messageId = evidenceInfo.messageId

            var newLearning = Learning(
                id: UUID(),
                conversationId: conversationId,
                messageId: messageId,
                type: learningType,
                pattern: learning.pattern ?? "",
                extractedRule: learning.rule,
                normalizedRule: normalizedRule,
                confidence: learning.confidence,
                context: learning.context,
                evidence: evidence,
                evidenceCount: 1,
                status: .pending,
                scope: scope,
                createdAt: Date(),
                lastDetectedAt: Date(),
                reviewedAt: nil,
                sourceQueueId: queueId,
                ruleHash: ruleHash,
                source: source,
                detectorVersion: detectorVersion
            )

            try newLearning.insert(db)
        }
    }

    private func resolveProvenance(for queueItem: AnalysisQueueItem) -> (source: String?, detectorVersion: String?) {
        let version = queueItem.analysisVersion
        guard let backend = queueItem.backend else {
            return (nil, version)
        }

        switch backend {
        case "gemini":
            return ("gemini", version ?? "gemini-llm-v1")
        case "claude_code", "codex":
            return ("cli", version ?? "cli-llm-v1")
        default:
            return (backend, version)
        }
    }

    private func validateEvidence(
        db: Database,
        conversationId: UUID,
        learning: LearningAnalysisResult.ExtractedLearning
    ) -> (messageId: UUID?, evidence: String)? {
        guard let evidenceRaw = learning.evidence?.trimmingCharacters(in: .whitespacesAndNewlines),
              !evidenceRaw.isEmpty else {
            return nil
        }

        if evidenceRaw.count < 8 || evidenceRaw.count > 260 {
            return nil
        }

        guard let messages = try? Message
            .filter(Message.Columns.conversationId == conversationId)
            .fetchAll(db) else {
            return nil
        }

        if let msgIdString = learning.messageId,
           let msgId = UUID(uuidString: msgIdString),
           let match = messages.first(where: { $0.id == msgId }) {
            if match.content.localizedCaseInsensitiveContains(evidenceRaw) {
                return (msgId, evidenceRaw)
            }
            return nil
        }

        if let match = messages.first(where: { $0.content.localizedCaseInsensitiveContains(evidenceRaw) }) {
            return (match.id, evidenceRaw)
        }

        return nil
    }

    private func resolveScope(
        db: Database,
        conversationId: UUID,
        normalizedRule: String,
        extractedRule: String,
        type: LearningType
    ) -> LearningScope {
        guard let row = try? Row.fetchOne(db, sql: """
            SELECT projectPath, provider
            FROM conversations
            WHERE id = ?
            """, arguments: [conversationId.uuidString]) else {
            return .project
        }

        let projectPath: String? = row["projectPath"]
        let provider: String? = row["provider"]

        guard let rows = try? Row.fetchAll(db, sql: """
            SELECT c.projectPath AS projectPath, c.provider AS provider
            FROM learnings l
            JOIN conversations c ON c.id = l.conversationId
            WHERE (l.normalizedRule = ? OR l.extractedRule = ?)
              AND l.type = ?
            """, arguments: [normalizedRule, extractedRule, type.rawValue]) else {
            return .project
        }

        var projects = Set<String>()
        var providers = Set<String>()
        for row in rows {
            if let path: String = row["projectPath"], !path.isEmpty {
                projects.insert(path)
            }
            if let providerValue: String = row["provider"] {
                providers.insert(providerValue)
            }
        }
        if let projectPath, !projectPath.isEmpty {
            projects.insert(projectPath)
        }
        if let provider, !provider.isEmpty {
            providers.insert(provider)
        }

        if projects.count >= 2 || providers.count >= 2 {
            return .global
        }

        return .project
    }

    private func isMetaConversation(db: Database, conversationId: UUID) -> Bool {
        guard let conversation = try? Conversation.fetchOne(db, key: conversationId) else {
            return false
        }
        return ConversationContentFilter.isMeta(textParts: [
            conversation.title,
            conversation.summary,
            conversation.previewText
        ])
    }

    // MARK: - Suggestion Creation

    /// Create suggestion with queue_id foreign key (prevents duplicates)
    private func createSuggestion(
        db: Database,
        queueId: String,
        type: String,
        targetId: String,
        suggestedValue: String,
        originalValue: String?,
        confidence: Double?,
        reasoning: String?
    ) throws {
        // Check for existing suggestion from this queue item + type + target (idempotency)
        let existing = try AnalysisSuggestion
            .filter(AnalysisSuggestion.Columns.queueId == queueId)
            .filter(AnalysisSuggestion.Columns.suggestionType == type)
            .filter(AnalysisSuggestion.Columns.targetId == targetId)
            .fetchOne(db)

        guard existing == nil else { return }

        var suggestion = AnalysisSuggestion(
            id: UUID().uuidString,
            queueId: queueId,
            suggestionType: type,
            targetId: targetId,
            suggestedValue: suggestedValue,
            originalValue: originalValue,
            confidence: confidence,
            reasoning: reasoning,
            status: "pending",
            reviewedAt: nil,
            rejectReason: nil,
            mergeSourceIds: nil,
            createdAt: Date()
        )

        try suggestion.insert(db)
    }

    /// Create merge suggestion for deduplication
    private func createMergeSuggestion(
        db: Database,
        queueId: String,
        merge: MergeSuggestion
    ) throws {
        // Encode source IDs as JSON
        let sourceIdsJSON = try JSONEncoder().encode(merge.sourceIds)
        let sourceIdsString = String(data: sourceIdsJSON, encoding: .utf8)

        // Check for existing suggestion with same merge sources (idempotency)
        let existing = try AnalysisSuggestion
            .filter(AnalysisSuggestion.Columns.queueId == queueId)
            .filter(AnalysisSuggestion.Columns.mergeSourceIds == sourceIdsString)
            .fetchOne(db)

        guard existing == nil else { return }

        var suggestion = AnalysisSuggestion(
            id: UUID().uuidString,
            queueId: queueId,
            suggestionType: "merge_learnings",
            targetId: nil,
            suggestedValue: merge.mergedRule,
            originalValue: nil,
            confidence: Double(merge.confidence),
            reasoning: merge.reasoning,
            status: "pending",
            reviewedAt: nil,
            rejectReason: nil,
            mergeSourceIds: sourceIdsString,
            createdAt: Date()
        )

        try suggestion.insert(db)
    }

    // MARK: - JSON Validation

    private func validateAndDecode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw ProcessingError.invalidJSON("Failed to convert JSON string to data")
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let decodingError as DecodingError {
            throw ProcessingError.decodingFailed(decodingError.localizedDescription)
        }
    }

    // MARK: - Suggestion Application (Transactional)

    /// Apply and approve a suggestion in a single transaction
    /// CRITICAL: Both apply and status update happen atomically
    /// If apply fails, status stays pending (no partial state)
    func applyAndApproveSuggestion(_ suggestion: AnalysisSuggestion) throws {
        try database.write { db in
            switch suggestion.suggestionType {
            case "title":
                guard let targetId = suggestion.targetId,
                      let conversationId = UUID(uuidString: targetId),
                      let newTitle = suggestion.suggestedValue else {
                    throw ProcessingError.invalidSuggestion("Invalid title suggestion")
                }
                try db.execute(
                    sql: "UPDATE conversations SET title = ?, updatedAt = ? WHERE id = ?",
                    arguments: [newTitle, Date(), conversationId]
                )

            case "summary":
                guard let targetId = suggestion.targetId,
                      let conversationId = UUID(uuidString: targetId),
                      let newSummary = suggestion.suggestedValue else {
                    throw ProcessingError.invalidSuggestion("Invalid summary suggestion")
                }
                try db.execute(
                    sql: "UPDATE conversations SET summary = ?, updatedAt = ? WHERE id = ?",
                    arguments: [newSummary, Date(), conversationId]
                )

            case "merge_learnings":
                guard let sourceIds = suggestion.mergeSourceIdList,
                      sourceIds.count >= 2,
                      let mergedRule = suggestion.suggestedValue else {
                    throw ProcessingError.invalidSuggestion("Invalid merge suggestion")
                }

                // Get the first source learning to use as base
                guard let firstId = sourceIds.first,
                      let firstUUID = UUID(uuidString: firstId),
                      var baseLearning = try Learning.fetchOne(db, key: firstUUID) else {
                    throw ProcessingError.invalidSuggestion("Source learning not found")
                }

                // Update the base learning with merged rule
                baseLearning.extractedRule = mergedRule
                baseLearning.evidenceCount = sourceIds.count
                baseLearning.lastDetectedAt = Date()
                try baseLearning.update(db)

                // Delete the other source learnings (merge into first)
                let otherIds = sourceIds.dropFirst().compactMap { UUID(uuidString: $0) }
                for otherId in otherIds {
                    try Learning.deleteOne(db, key: otherId)
                }

            default:
                throw ProcessingError.invalidSuggestion("Unknown suggestion type: \(suggestion.suggestionType)")
            }

            // Update suggestion status in same transaction
            try db.execute(
                sql: "UPDATE analysis_suggestions SET status = ?, reviewedAt = ? WHERE id = ?",
                arguments: ["approved", Date(), suggestion.id]
            )
        }
    }

    /// Reject a suggestion (status update only)
    func rejectSuggestion(_ suggestion: AnalysisSuggestion, reason: String? = nil) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE analysis_suggestions SET status = ?, reviewedAt = ?, rejectReason = ? WHERE id = ?",
                arguments: ["rejected", Date(), reason, suggestion.id]
            )
        }
    }

    /// Fetch all pending suggestions
    func fetchPendingSuggestions() throws -> [AnalysisSuggestion] {
        try database.read { db in
            try AnalysisSuggestion
                .filter(AnalysisSuggestion.Columns.status == "pending")
                .order(AnalysisSuggestion.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    // MARK: - Legacy Suggestion Application (non-transactional, deprecated)

    /// Apply an approved title suggestion to a conversation
    /// @deprecated Use applyAndApproveSuggestion instead
    func applyTitleSuggestion(_ suggestion: AnalysisSuggestion) throws {
        guard suggestion.suggestionType == "title",
              let targetId = suggestion.targetId,
              let conversationId = UUID(uuidString: targetId),
              let newTitle = suggestion.suggestedValue else {
            throw ProcessingError.invalidSuggestion("Invalid title suggestion")
        }

        try database.write { db in
            try db.execute(
                sql: "UPDATE conversations SET title = ?, updatedAt = ? WHERE id = ?",
                arguments: [newTitle, Date(), conversationId]
            )
        }
    }

    /// Apply an approved merge suggestion (merges learnings)
    /// @deprecated Use applyAndApproveSuggestion instead
    func applyMergeSuggestion(_ suggestion: AnalysisSuggestion) throws {
        guard suggestion.suggestionType == "merge_learnings",
              let sourceIds = suggestion.mergeSourceIdList,
              sourceIds.count >= 2,
              let mergedRule = suggestion.suggestedValue else {
            throw ProcessingError.invalidSuggestion("Invalid merge suggestion")
        }

        try database.write { db in
            // Get the first source learning to use as base
            guard let firstId = sourceIds.first,
                  let firstUUID = UUID(uuidString: firstId),
                  var baseLearning = try Learning.fetchOne(db, key: firstUUID) else {
                throw ProcessingError.invalidSuggestion("Source learning not found")
            }

            // Update the base learning with merged rule
            baseLearning.extractedRule = mergedRule
            baseLearning.evidenceCount = sourceIds.count
            baseLearning.lastDetectedAt = Date()
            try baseLearning.update(db)

            // Delete the other source learnings (merge into first)
            let otherIds = sourceIds.dropFirst().compactMap { UUID(uuidString: $0) }
            for otherId in otherIds {
                try Learning.deleteOne(db, key: otherId)
            }
        }
    }

    // MARK: - Hash Helpers

    /// Compute a deterministic hash from a string using SHA256
    /// Unlike Swift's `hashValue`, this produces the same hash across app restarts
    private func deterministicHash(_ string: String) -> Int {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        // Use first 8 bytes as Int (stable across restarts)
        let bytes = Array(hash.prefix(8))
        var result: Int = 0
        for (index, byte) in bytes.enumerated() {
            result |= Int(byte) << (index * 8)
        }
        return result
    }

    // MARK: - Errors

    enum ProcessingError: LocalizedError {
        case noResultJSON
        case unknownAnalysisType(String)
        case invalidJSON(String)
        case decodingFailed(String)
        case invalidSuggestion(String)
        case alreadyApplied

        var errorDescription: String? {
            switch self {
            case .noResultJSON:
                return "No result JSON in queue item"
            case .unknownAnalysisType(let type):
                return "Unknown analysis type: \(type)"
            case .invalidJSON(let reason):
                return "Invalid JSON: \(reason)"
            case .decodingFailed(let reason):
                return "Failed to decode JSON: \(reason)"
            case .invalidSuggestion(let reason):
                return "Invalid suggestion: \(reason)"
            case .alreadyApplied:
                return "Results already applied"
            }
        }
    }
}
