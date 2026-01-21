import Foundation
import GRDB

/// Manages the queue of detected learnings for user review
@MainActor
final class LearningQueue: ObservableObject {
    // MARK: - Published State

    @Published private(set) var pendingLearnings: [Learning] = []
    @Published private(set) var approvedLearnings: [Learning] = []
    @Published private(set) var isProcessing = false

    // MARK: - Dependencies

    private let detector: CorrectionDetector
    private let repository: ConversationRepository
    private let db: AppDatabase
    private var minimumConfidence: Float
    private var extractionMode: LearningExtractionMode = .semantic
    private let geminiExtractor: GeminiLearningExtractor
    private var geminiEnabled: Bool = false
    private var includeImplicitLearnings: Bool = false
    private let minEvidenceForPositive: Int = 2
    private let deterministicSource = "deterministic"
    private let deterministicDetectorVersion = "deterministic-v2"
    private let geminiSource = "gemini"
    private let geminiDetectorVersion = "gemini-v1"

    // MARK: - Init

    init(
        detector: CorrectionDetector = CorrectionDetector(),
        repository: ConversationRepository = ConversationRepository(),
        db: AppDatabase = .shared
    ) {
        self.detector = detector
        self.repository = repository
        self.db = db
        self.minimumConfidence = detector.configuration.minConfidence
        self.geminiExtractor = GeminiLearningExtractor()

        Task {
            await loadPendingLearnings()
            await loadApprovedLearnings()  // Also load approved for exports
        }
    }

    // MARK: - Queue Management

    /// Load pending learnings from database
    func loadPendingLearnings() async {
        do {
            let includeImplicit = includeImplicitLearnings
            let minEvidence = minEvidenceForPositive
            let learnings = try await db.reader.read { db in
                let typeColumn = Learning.Columns.type
                let evidenceColumn = Learning.Columns.evidenceCount
                let positive = LearningType.positive.rawValue
                let implicit = LearningType.implicit.rawValue

                var request = Learning
                    .filter(Column("status") == LearningStatus.pending.rawValue)
                if includeImplicit {
                    request = request.filter(
                        (typeColumn != positive && typeColumn != implicit)
                            || (evidenceColumn >= minEvidence)
                    )
                } else {
                    request = request.filter(typeColumn != positive && typeColumn != implicit)
                }

                return try request
                    .order(Column("lastDetectedAt").desc, Column("createdAt").desc)
                    .fetchAll(db)
            }
            pendingLearnings = learnings
        } catch {
            print("Failed to load pending learnings: \(error)")
        }
    }

    /// Load approved learnings from database
    func loadApprovedLearnings() async {
        do {
            let learnings = try await db.reader.read { db in
                try Learning
                    .filter(Column("status") == LearningStatus.approved.rawValue)
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
            }
            approvedLearnings = learnings
        } catch {
            print("Failed to load approved learnings: \(error)")
        }
    }

    func updateMinimumConfidence(_ value: Float) {
        minimumConfidence = value
        detector.updateMinimumConfidence(value)
    }

    func updateExtractionMode(_ mode: LearningExtractionMode) {
        extractionMode = mode
    }

    func updateImplicitLearningsEnabled(_ enabled: Bool) {
        includeImplicitLearnings = enabled
        detector.updatePositiveFeedbackEnabled(enabled)
        Task {
            await loadPendingLearnings()
        }
    }

    /// Configure Gemini for learning extraction
    func updateGeminiConfiguration(apiKey: String, model: String, enabled: Bool) {
        geminiEnabled = enabled
        Task {
            await geminiExtractor.updateConfiguration(
                apiKey: apiKey,
                model: model,
                minConfidence: minimumConfidence
            )
        }
    }

    // MARK: - Processing

    /// Scan all conversations for learnings
    func scanAllConversations() async {
        guard !isProcessing else { return }
        isProcessing = true

        // Fetch conversations on background thread to avoid blocking MainActor
        let conversations = await Task.detached { [repository] in
            try? repository.fetchAll()
        }.value

        for conversation in conversations ?? [] {
            await scanConversation(conversation)
        }

        await loadPendingLearnings()
        isProcessing = false
    }

    /// Scan a single conversation for learnings
    func scanConversation(_ conversation: Conversation) async {
        // Fetch messages on background thread to avoid blocking MainActor
        let conversationId = conversation.id
        guard let messages = await (Task.detached { [repository] in
            try? repository.fetchMessages(conversationId: conversationId)
        }).value else {
            return
        }

        if ConversationContentFilter.isMeta(conversation: conversation, messages: messages) {
            return
        }

        // Track whether Gemini successfully processed this conversation
        var geminiProcessed = false

        // Use Gemini for semantic/hybrid mode (if enabled and configured)
        if extractionMode == .semantic || extractionMode == .hybrid {
            let isAvailable = await geminiExtractor.isAvailable
            if geminiEnabled && isAvailable {
                let geminiLearnings = await geminiExtractor.extractLearnings(from: conversation, messages: messages)
                let filteredLearnings = geminiLearnings.filter { candidate in
                    includeImplicitLearnings || candidate.type == .correction
                }
                // Only mark as processed if we actually got usable results
                geminiProcessed = !filteredLearnings.isEmpty
                for candidate in filteredLearnings where candidate.confidence >= minimumConfidence {
                    let detection = CorrectionDetector.DetectionResult(
                        type: candidate.type,
                        pattern: candidate.pattern,
                        extractedRule: candidate.rule,
                        confidence: candidate.confidence,
                        messageId: candidate.messageId ?? UUID(),
                        conversationId: conversation.id,
                        messageTimestamp: candidate.messageTimestamp ?? Date(),
                        context: candidate.context,
                        evidence: String(candidate.context.prefix(220))
                    )
                    await upsertLearning(
                        from: detection,
                        conversation: conversation,
                        source: geminiSource,
                        detectorVersion: geminiDetectorVersion
                    )
                }
            }
        }

        // Use deterministic (regex) extraction for:
        // - .deterministic mode (always)
        // - .hybrid mode (always, in addition to Gemini)
        // - .semantic mode when Gemini is unavailable (fallback)
        let shouldUseDeterministic = extractionMode == .deterministic
            || extractionMode == .hybrid
            || (extractionMode == .semantic && !geminiProcessed)

        if shouldUseDeterministic {
            let detections = detector.analyzeConversation(conversation, messages: messages)
            for detection in detections {
                await upsertLearning(
                    from: detection,
                    conversation: conversation,
                    source: deterministicSource,
                    detectorVersion: deterministicDetectorVersion
                )
            }
        }
    }

    private func upsertLearning(
        from detection: CorrectionDetector.DetectionResult,
        conversation: Conversation,
        source: String,
        detectorVersion: String
    ) async {
        if !LearningRuleNormalizer.shouldStoreLearning(
            rule: detection.extractedRule,
            type: detection.type,
            confidence: detection.confidence
        ) {
            return
        }

        let normalizedRule = LearningRuleNormalizer.normalize(detection.extractedRule)
        let isTaskSpecific = LearningRuleNormalizer.isTaskSpecific(detection.extractedRule)
        let resolvedScope = isTaskSpecific ? .project : await resolveScope(
            conversation: conversation,
            normalizedRule: normalizedRule,
            extractedRule: detection.extractedRule,
            type: detection.type
        )

        let existing = try? await db.reader.read { db in
            try Learning
                .filter(Learning.Columns.normalizedRule == normalizedRule ||
                        Learning.Columns.extractedRule == detection.extractedRule)
                .filter(Learning.Columns.type == detection.type.rawValue)
                .fetchOne(db)
        }

        if var existing = existing {
            guard existing.status == .pending else { return }
            if let lastDetectedAt = existing.lastDetectedAt, lastDetectedAt >= detection.messageTimestamp {
                return
            }

            existing.confidence = max(existing.confidence, detection.confidence)
            existing.evidenceCount += 1
            existing.lastDetectedAt = detection.messageTimestamp
            existing.context = detection.context
            existing.messageId = detection.messageId
            existing.conversationId = detection.conversationId
            existing.normalizedRule = normalizedRule
            if existing.evidence == nil {
                existing.evidence = detection.evidence
            }
            if isTaskSpecific {
                existing.scope = .project
            } else if existing.scope == .project, resolvedScope == .global {
                existing.scope = .global
            }
            if existing.source == nil {
                existing.source = source
            }
            if existing.detectorVersion == nil {
                existing.detectorVersion = detectorVersion
            }
            let updatedLearning = existing

            do {
                try await db.writer.write { db in
                    try updatedLearning.update(db)
                }
            } catch {
                print("Failed to update learning: \(error)")
            }
            return
        }

        let learning = Learning(
            id: UUID(),
            conversationId: detection.conversationId,
            messageId: detection.messageId,
            type: detection.type,
            pattern: detection.pattern,
            extractedRule: detection.extractedRule,
            normalizedRule: normalizedRule,
            confidence: detection.confidence,
            context: detection.context,
            evidence: detection.evidence,
            evidenceCount: 1,
            status: .pending,
            scope: resolvedScope,
            createdAt: Date(),
            lastDetectedAt: detection.messageTimestamp,
            source: source,
            detectorVersion: detectorVersion
        )

        do {
            try await db.writer.write { db in
                try learning.insert(db)
            }
        } catch {
            print("Failed to save learning: \(error)")
        }
    }

    private func resolveScope(
        conversation: Conversation,
        normalizedRule: String,
        extractedRule: String,
        type: LearningType
    ) async -> LearningScope {
        let projectPath = conversation.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = conversation.provider.rawValue

        do {
            let results = try await db.reader.read { db -> (Set<String>, Set<String>) in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT c.projectPath AS projectPath, c.provider AS provider
                    FROM learnings l
                    JOIN conversations c ON c.id = l.conversationId
                    WHERE (l.normalizedRule = ? OR l.extractedRule = ?)
                      AND l.type = ?
                    """, arguments: [normalizedRule, extractedRule, type.rawValue])

                var projects = Set<String>()
                var providers = Set<String>()
                for row in rows {
                    if let path: String = row["projectPath"], !path.isEmpty {
                        projects.insert(path)
                    }
                    if let provider: String = row["provider"] {
                        providers.insert(provider)
                    }
                }
                if let projectPath, !projectPath.isEmpty {
                    projects.insert(projectPath)
                }
                if !provider.isEmpty {
                    providers.insert(provider)
                }
                return (projects, providers)
            }

            if results.0.count >= 2 || results.1.count >= 2 {
                return .global
            }
        } catch {
            return .project
        }

        return .project
    }

    // MARK: - Review Actions

    /// Approve a learning
    func approve(_ learning: Learning, scope: LearningScope = .global, editedRule: String? = nil) async {
        var updated = learning
        updated.status = .approved
        updated.scope = scope
        updated.reviewedAt = Date()  // Record when it was reviewed
        if let edited = editedRule {
            updated.extractedRule = edited
        }
        let updatedLearning = updated

        do {
            try await db.writer.write { db in
                try updatedLearning.update(db)
            }

            pendingLearnings.removeAll { $0.id == learning.id }
            approvedLearnings.insert(updatedLearning, at: 0)
        } catch {
            print("Failed to approve learning: \(error)")
        }
    }

    /// Reject a learning
    func reject(_ learning: Learning) async {
        var updated = learning
        updated.status = .rejected
        updated.reviewedAt = Date()  // Record when it was reviewed
        let updatedLearning = updated

        do {
            try await db.writer.write { db in
                try updatedLearning.update(db)
            }

            pendingLearnings.removeAll { $0.id == learning.id }
        } catch {
            print("Failed to reject learning: \(error)")
        }
    }

    /// Skip a learning (keep as pending but move to end of queue)
    func skip(_ learning: Learning) {
        if let index = pendingLearnings.firstIndex(where: { $0.id == learning.id }) {
            let skipped = pendingLearnings.remove(at: index)
            pendingLearnings.append(skipped)
        }
    }

    /// Edit a learning's extracted rule
    func edit(_ learning: Learning, newRule: String) async {
        var updated = learning
        updated.extractedRule = newRule
        let updatedLearning = updated

        do {
            try await db.writer.write { db in
                try updatedLearning.update(db)
            }

            if let index = pendingLearnings.firstIndex(where: { $0.id == learning.id }) {
                pendingLearnings[index] = updatedLearning
            }
        } catch {
            print("Failed to edit learning: \(error)")
        }
    }

    /// Delete a learning
    func delete(_ learning: Learning) async {
        do {
            _ = try await db.writer.write { db in
                try learning.delete(db)
            }

            pendingLearnings.removeAll { $0.id == learning.id }
            approvedLearnings.removeAll { $0.id == learning.id }
        } catch {
            print("Failed to delete learning: \(error)")
        }
    }

    // MARK: - Filtering

    /// Get learnings for a specific project
    func learnings(forProject projectPath: String) -> [Learning] {
        approvedLearnings.filter { learning in
            if learning.scope == .global { return true }
            // Check if learning's conversation is from this project
            if let conversation = try? repository.fetch(id: learning.conversationId) {
                return conversation.projectPath == projectPath
            }
            return false
        }
    }

    /// Get global learnings only
    func globalLearnings() -> [Learning] {
        approvedLearnings.filter { $0.scope == .global }
    }
}
