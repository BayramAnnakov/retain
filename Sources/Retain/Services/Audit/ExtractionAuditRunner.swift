import Foundation
import GRDB

/// Command-line runner to rebuild learnings + workflows on a specified database.
enum ExtractionAuditRunner {
    private static let auditFlag = "--audit-extract"
    private static let dbFlag = "--db"
    private static let resetFlag = "--reset"

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains(auditFlag) else { return false }

        let dbURL = resolveDatabaseURL(from: arguments)
        let shouldReset = arguments.contains(resetFlag)

        do {
            try runExtraction(dbURL: dbURL, resetBeforeExtract: shouldReset)
            return true
        } catch {
            fputs("Audit extraction failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func resolveDatabaseURL(from arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: dbFlag), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1])
        }

        let fileManager = FileManager.default
        let appSupportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let directoryURL = appSupportURL?.appendingPathComponent("Retain", isDirectory: true)
        return directoryURL?.appendingPathComponent("retain.sqlite")
            ?? URL(fileURLWithPath: "retain.sqlite")
    }

    private static func runExtraction(dbURL: URL, resetBeforeExtract: Bool) throws {
        let database = try AppDatabase.open(path: dbURL)

        if resetBeforeExtract {
            try database.write { db in
                try db.execute(sql: "DELETE FROM learnings")
                try db.execute(sql: "DELETE FROM workflow_signatures")
            }
        }

        let repository = ConversationRepository(database: database)
        let detector = CorrectionDetector(
            configuration: .init(minConfidence: 0.8, enablePositiveFeedback: false)
        )
        let workflowExtractor = WorkflowSignatureExtractor()

        let conversations = try repository.fetchAll()
        for conversation in conversations {
            let messages = try repository.fetchMessages(conversationId: conversation.id)
            if ConversationContentFilter.isMeta(conversation: conversation, messages: messages) {
                continue
            }
            let detections = detector.analyzeConversation(conversation, messages: messages)
            for detection in detections {
                try upsertLearning(
                    detection: detection,
                    database: database,
                    source: "deterministic",
                    detectorVersion: "deterministic-v2"
                )
            }

            if let candidate = workflowExtractor.extractSignature(conversation: conversation, messages: messages) {
                try upsertWorkflowSignature(
                    candidate: candidate,
                    conversation: conversation,
                    database: database
                )
            }
        }
    }

    private static func upsertLearning(
        detection: CorrectionDetector.DetectionResult,
        database: AppDatabase,
        source: String,
        detectorVersion: String
    ) throws {
        if !LearningRuleNormalizer.shouldStoreLearning(
            rule: detection.extractedRule,
            type: detection.type,
            confidence: detection.confidence
        ) {
            return
        }

        let normalizedRule = LearningRuleNormalizer.normalize(detection.extractedRule)
        let isTaskSpecific = LearningRuleNormalizer.isTaskSpecific(detection.extractedRule)
        let scope = isTaskSpecific ? .project : resolveScope(
            database: database,
            conversationId: detection.conversationId,
            normalizedRule: normalizedRule,
            extractedRule: detection.extractedRule,
            type: detection.type
        )

        try database.write { db in
            let existing = try Learning
                .filter(Learning.Columns.normalizedRule == normalizedRule
                    || Learning.Columns.extractedRule == detection.extractedRule)
                .filter(Learning.Columns.type == detection.type.rawValue)
                .fetchOne(db)

            if var existing {
                if let lastDetectedAt = existing.lastDetectedAt,
                   lastDetectedAt >= detection.messageTimestamp {
                    return
                }

                existing.confidence = max(existing.confidence, detection.confidence)
                existing.evidenceCount += 1
                existing.lastDetectedAt = detection.messageTimestamp
                existing.context = detection.context
                existing.messageId = detection.messageId
                existing.conversationId = detection.conversationId
                existing.normalizedRule = normalizedRule
                if isTaskSpecific {
                    existing.scope = .project
                } else if existing.scope == .project, scope == .global {
                    existing.scope = .global
                }
                if existing.source == nil {
                    existing.source = source
                }
                if existing.detectorVersion == nil {
                    existing.detectorVersion = detectorVersion
                }
                try existing.update(db)
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
                scope: scope,
                createdAt: Date(),
                lastDetectedAt: detection.messageTimestamp,
                source: source,
                detectorVersion: detectorVersion
            )

            try learning.insert(db)
        }
    }

    private static func resolveScope(
        database: AppDatabase,
        conversationId: UUID,
        normalizedRule: String,
        extractedRule: String,
        type: LearningType
    ) -> LearningScope {
        do {
            return try database.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT projectPath, provider
                    FROM conversations
                    WHERE id = ?
                    """, arguments: [conversationId.uuidString]) else {
                    return .project
                }

                let projectPath: String? = row["projectPath"]
                let provider: String? = row["provider"]

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
        } catch {
            return .project
        }
    }

    private static func upsertWorkflowSignature(
        candidate: WorkflowSignatureCandidate,
        conversation: Conversation,
        database: AppDatabase
    ) throws {
        try database.write { db in
            if var existing = try WorkflowSignature
                .filter(WorkflowSignature.Columns.conversationId == conversation.id)
                .fetchOne(db) {
                existing.signature = candidate.signature
                existing.action = candidate.action
                existing.artifact = candidate.artifact
                existing.domains = candidate.domains.sorted().joined(separator: ",")
                existing.snippet = candidate.snippet
                existing.version = candidate.version
                existing.updatedAt = Date()
                existing.source = candidate.source
                existing.detectorVersion = candidate.detectorVersion
                existing.confidence = candidate.confidence
                existing.isPriming = candidate.isPriming
                try existing.update(db)
            } else {
                let signature = WorkflowSignature(
                    conversationId: conversation.id,
                    signature: candidate.signature,
                    action: candidate.action,
                    artifact: candidate.artifact,
                    domains: candidate.domains.sorted().joined(separator: ","),
                    snippet: candidate.snippet,
                    version: candidate.version,
                    createdAt: conversation.createdAt,
                    updatedAt: Date(),
                    sourceQueueId: nil,
                    confidence: candidate.confidence,
                    source: candidate.source,
                    detectorVersion: candidate.detectorVersion,
                    isPriming: candidate.isPriming
                )

                try signature.insert(db)
            }
        }
    }
}
