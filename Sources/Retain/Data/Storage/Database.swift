import Foundation
import GRDB

/// Central database manager for Retain
final class AppDatabase {
    /// Shared database instance
    static let shared = makeShared()

    /// The database connection
    let dbWriter: any DatabaseWriter

    /// Creates an in-memory database for testing
    static func makeInMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        let database = try AppDatabase(dbQueue)
        return database
    }

    /// Opens a database at an explicit path (used for audits or migrations)
    static func open(path: URL) throws -> AppDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let dbPool = try DatabasePool(path: path.path, configuration: config)
        return try AppDatabase(dbPool)
    }

    /// Creates the shared database
    private static func makeShared() -> AppDatabase {
        do {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directoryURL = appSupportURL.appendingPathComponent("Retain", isDirectory: true)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let databaseURL = directoryURL.appendingPathComponent("retain.sqlite")

            // Configure database for concurrent access (WAL mode, busy timeout)
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA busy_timeout = 5000")  // 5 second timeout
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }

            let dbPool = try DatabasePool(path: databaseURL.path, configuration: config)

            // Set restrictive permissions on database directory and file
            // 0o700 for directory = owner read/write/execute only
            // 0o600 for file = owner read/write only
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            if fileManager.fileExists(atPath: databaseURL.path) {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: databaseURL.path
                )
            }

            return try AppDatabase(dbPool)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    private init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    /// Database migrator with all schema versions
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Erase database on schema change during development
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        // Version 1: Initial schema
        migrator.registerMigration("v1_initial") { db in
            // Conversations table
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull()
                t.column("sourceType", .text).notNull()
                t.column("externalId", .text)
                t.column("title", .text)
                t.column("summary", .text)
                t.column("projectPath", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("messageCount", .integer).notNull().defaults(to: 0)
                t.column("embedding", .blob)
            }

            // Index for deduplication by external ID
            try db.create(
                index: "conversations_externalId",
                on: "conversations",
                columns: ["provider", "externalId"],
                unique: true,
                ifNotExists: true
            )

            // Messages table
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("externalId", .text)
                t.column("parentId", .text)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("model", .text)
                t.column("metadata", .blob)
            }

            // Index for fetching messages by conversation
            try db.create(
                index: "messages_conversationId",
                on: "messages",
                columns: ["conversationId"]
            )

            // Learnings table
            try db.create(table: "learnings") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("messageId", .text)
                    .notNull()
                    .references("messages", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("pattern", .text).notNull()
                t.column("extractedRule", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 0.8)
                t.column("context", .text)
                t.column("status", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("reviewedAt", .datetime)
            }

            // Index for pending learnings
            try db.create(
                index: "learnings_status",
                on: "learnings",
                columns: ["status"]
            )

            // Full-Text Search virtual table for messages
            try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
                t.synchronize(withTable: "messages")
                t.tokenizer = .porter() // Stemming for better search
                t.column("content")
            }

            // Full-Text Search virtual table for conversations
            try db.create(virtualTable: "conversations_fts", using: FTS5()) { t in
                t.synchronize(withTable: "conversations")
                t.tokenizer = .porter()
                t.column("title")
                t.column("summary")
            }
        }

        // Version 2: Fix FK cascade behavior and add performance indexes
        migrator.registerMigration("v2_fk_and_indexes") { db in
            // Add missing indexes for performance at scale
            try db.create(
                index: "messages_timestamp",
                on: "messages",
                columns: ["timestamp"],
                ifNotExists: true
            )

            try db.create(
                index: "conversations_updatedAt",
                on: "conversations",
                columns: ["updatedAt"],
                ifNotExists: true
            )

            try db.create(
                index: "conversations_provider",
                on: "conversations",
                columns: ["provider"],
                ifNotExists: true
            )

            // Rebuild learnings table to change messageId FK from CASCADE to SET NULL
            // This ensures learnings survive when messages are deleted
            // SQLite doesn't support ALTER CONSTRAINT, so we need a table rebuild

            // 1. Create new table with SET NULL FK
            try db.create(table: "learnings_new") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("messageId", .text)
                    .references("messages", onDelete: .setNull)  // Changed from CASCADE to SET NULL
                t.column("type", .text).notNull()
                t.column("pattern", .text).notNull()
                t.column("extractedRule", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 0.8)
                t.column("context", .text)
                t.column("status", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("reviewedAt", .datetime)
            }

            // 2. Copy existing data
            try db.execute(sql: """
                INSERT INTO learnings_new
                SELECT * FROM learnings
                """)

            // 3. Drop old table and rename new
            try db.drop(table: "learnings")
            try db.rename(table: "learnings_new", to: "learnings")

            // 4. Recreate index
            try db.create(
                index: "learnings_status",
                on: "learnings",
                columns: ["status"]
            )

            // 5. Add index for messageId lookups
            try db.create(
                index: "learnings_messageId",
                on: "learnings",
                columns: ["messageId"],
                ifNotExists: true
            )
        }

        // Version 3: Add embedding provider tracking
        migrator.registerMigration("v3_embedding_provider") { db in
            // Track which provider generated the embedding (for dimension compatibility)
            try db.alter(table: "conversations") { t in
                t.add(column: "embeddingProvider", .text)
            }
        }

        // Version 4: Learning dedupe support
        migrator.registerMigration("v4_learning_dedupe") { db in
            try db.alter(table: "learnings") { t in
                t.add(column: "normalizedRule", .text)
                t.add(column: "evidenceCount", .integer).notNull().defaults(to: 1)
                t.add(column: "lastDetectedAt", .datetime)
            }

            try db.execute(sql: """
                UPDATE learnings
                SET normalizedRule = lower(trim(extractedRule))
                WHERE normalizedRule IS NULL
                """)

            try db.execute(sql: """
                UPDATE learnings
                SET evidenceCount = 1
                WHERE evidenceCount IS NULL
                """)

            try db.execute(sql: """
                UPDATE learnings
                SET lastDetectedAt = createdAt
                WHERE lastDetectedAt IS NULL
                """)

            try db.create(
                index: "learnings_normalizedRule",
                on: "learnings",
                columns: ["normalizedRule", "type"],
                ifNotExists: true
            )

            func idValue(from row: Row, column: String) -> (any DatabaseValueConvertible)? {
                if let data: Data = row[column] {
                    return data
                }
                if let string: String = row[column] {
                    return string
                }
                if let uuid: UUID = row[column] {
                    return uuid
                }
                return nil
            }

            // Collapse duplicate pending learnings by normalized rule + type.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, normalizedRule, type, status, confidence, createdAt, lastDetectedAt, context, messageId, conversationId
                FROM learnings
                WHERE normalizedRule IS NOT NULL
                ORDER BY lastDetectedAt DESC, createdAt DESC
                """)

            var groups: [String: [Row]] = [:]
            for row in rows {
                guard let rule: String = row["normalizedRule"],
                      let type: String = row["type"],
                      let status: String = row["status"] else {
                    continue
                }
                let key = "\(rule)|\(type)|\(status)"
                groups[key, default: []].append(row)
            }

            for group in groups.values where group.count > 1 {
                guard let primary = group.first,
                      let primaryId = idValue(from: primary, column: "id") else {
                    continue
                }

                let confidences = group.compactMap { $0["confidence"] as? Double }
                let maxConfidence = confidences.max() ?? 0.8

                let createdDates = group.compactMap { $0["createdAt"] as? Date }
                let earliestCreated = createdDates.min() ?? Date()

                let lastDetectedDates = group.compactMap { $0["lastDetectedAt"] as? Date }
                let latestDetected = lastDetectedDates.max() ?? earliestCreated

                let evidenceCount = group.count
                let context: String? = primary["context"]
                let messageId = idValue(from: primary, column: "messageId")
                let conversationId = idValue(from: primary, column: "conversationId")

                try db.execute(sql: """
                    UPDATE learnings
                    SET evidenceCount = ?,
                        confidence = ?,
                        createdAt = ?,
                        lastDetectedAt = ?,
                        context = ?,
                        messageId = ?,
                        conversationId = ?
                    WHERE id = ?
                    """, arguments: StatementArguments([
                        evidenceCount,
                        maxConfidence,
                        earliestCreated,
                        latestDetected,
                        context,
                        messageId,
                        conversationId,
                        primaryId
                    ]))

                let duplicateIds = group.dropFirst().compactMap { idValue(from: $0, column: "id") }
                if !duplicateIds.isEmpty {
                    let placeholders = duplicateIds.map { _ in "?" }.joined(separator: ",")
                    try db.execute(sql: "DELETE FROM learnings WHERE id IN (\(placeholders))", arguments: StatementArguments(duplicateIds))
                }
            }
        }

        // Version 5: Repair learnings schema if dedupe columns are missing
        migrator.registerMigration("v5_learning_schema_repair") { db in
            let columnRows = try Row.fetchAll(db, sql: "PRAGMA table_info(learnings)")
            let existingColumns = Set(columnRows.compactMap { $0["name"] as? String })
            let requiredColumns: Set<String> = ["normalizedRule", "evidenceCount", "lastDetectedAt"]

            let didRebuild = !requiredColumns.isSubset(of: existingColumns)

            if didRebuild {
                try db.create(table: "learnings_new") { t in
                    t.column("id", .text).primaryKey()
                    t.column("conversationId", .text)
                        .notNull()
                        .references("conversations", onDelete: .cascade)
                    t.column("messageId", .text)
                        .references("messages", onDelete: .setNull)
                    t.column("type", .text).notNull()
                    t.column("pattern", .text).notNull()
                    t.column("extractedRule", .text).notNull()
                    t.column("normalizedRule", .text)
                    t.column("confidence", .double).notNull().defaults(to: 0.8)
                    t.column("context", .text)
                    t.column("evidenceCount", .integer).notNull().defaults(to: 1)
                    t.column("status", .text).notNull()
                    t.column("scope", .text).notNull()
                    t.column("createdAt", .datetime).notNull()
                    t.column("lastDetectedAt", .datetime)
                    t.column("reviewedAt", .datetime)
                }

                let normalizedRuleSelect = existingColumns.contains("normalizedRule")
                    ? "COALESCE(normalizedRule, lower(trim(extractedRule)))"
                    : "lower(trim(extractedRule))"
                let evidenceCountSelect = existingColumns.contains("evidenceCount")
                    ? "COALESCE(evidenceCount, 1)"
                    : "1"
                let lastDetectedSelect = existingColumns.contains("lastDetectedAt")
                    ? "COALESCE(lastDetectedAt, createdAt)"
                    : "createdAt"

                try db.execute(sql: """
                    INSERT INTO learnings_new (
                        id,
                        conversationId,
                        messageId,
                        type,
                        pattern,
                        extractedRule,
                        normalizedRule,
                        confidence,
                        context,
                        evidenceCount,
                        status,
                        scope,
                        createdAt,
                        lastDetectedAt,
                        reviewedAt
                    )
                    SELECT
                        id,
                        conversationId,
                        messageId,
                        type,
                        pattern,
                        extractedRule,
                        \(normalizedRuleSelect),
                        confidence,
                        context,
                        \(evidenceCountSelect),
                        status,
                        scope,
                        createdAt,
                        \(lastDetectedSelect),
                        reviewedAt
                    FROM learnings
                    """)

                try db.drop(table: "learnings")
                try db.rename(table: "learnings_new", to: "learnings")
            }

            if didRebuild || existingColumns.contains("normalizedRule") {
                try db.create(
                    index: "learnings_normalizedRule",
                    on: "learnings",
                    columns: ["normalizedRule", "type"],
                    ifNotExists: true
                )
            }

            try db.create(
                index: "learnings_status",
                on: "learnings",
                columns: ["status"],
                ifNotExists: true
            )

            try db.create(
                index: "learnings_messageId",
                on: "learnings",
                columns: ["messageId"],
                ifNotExists: true
            )
        }

        // Version 5: Raw payload storage for structured rendering
        migrator.registerMigration("v5_raw_payloads") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "rawPayload", .blob)
            }

            try db.alter(table: "messages") { t in
                t.add(column: "rawPayload", .blob)
            }
        }

        // Version 6: Conversation preview text for list display
        migrator.registerMigration("v6_preview_text") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "previewText", .text)
            }
        }

        // Version 7: Workflow signature storage
        migrator.registerMigration("v7_workflow_signatures") { db in
            try db.create(table: "workflow_signatures") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("signature", .text).notNull()
                t.column("action", .text).notNull()
                t.column("artifact", .text).notNull()
                t.column("domains", .text).notNull()
                t.column("snippet", .text).notNull()
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(
                index: "workflow_signatures_conversationId",
                on: "workflow_signatures",
                columns: ["conversationId"],
                unique: true,
                ifNotExists: true
            )

            try db.create(
                index: "workflow_signatures_signature",
                on: "workflow_signatures",
                columns: ["signature"],
                ifNotExists: true
            )
        }

        // Version 8: CLI LLM Integration - Analysis Queue
        migrator.registerMigration("v8_analysis_queue") { db in
            // Analysis Queue table for coordinating LLM analysis
            try db.create(table: "analysis_queue") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("analysisType", .text).notNull()  // 'workflow', 'learning', 'summary', 'dedupe'
                t.column("status", .text).notNull().defaults(to: "pending")  // 'pending', 'claimed', 'completed', 'failed'
                t.column("priority", .integer).notNull().defaults(to: 0)

                // Concurrency & claiming
                t.column("claimedBy", .text)
                t.column("claimedAt", .datetime)
                t.column("attemptCount", .integer).notNull().defaults(to: 0)
                t.column("maxAttempts", .integer).notNull().defaults(to: 3)

                // Versioning for schema compatibility
                t.column("schemaVersion", .integer).notNull().defaults(to: 1)
                t.column("analysisVersion", .text)
                t.column("backend", .text)  // 'claude_code', 'codex', 'gemini'
                t.column("model", .text)

                // Timestamps
                t.column("createdAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("completedAt", .datetime)

                // Results (JSON only - app validates and persists to final tables)
                t.column("resultJson", .text)
                t.column("errorMessage", .text)

                // Result application tracking (prevents re-processing)
                t.column("resultsAppliedAt", .datetime)
            }

            // Indexes for efficient claiming and queries
            try db.create(
                index: "analysis_queue_status_priority",
                on: "analysis_queue",
                columns: ["status", "priority"]
            )

            try db.create(
                index: "analysis_queue_conversation",
                on: "analysis_queue",
                columns: ["conversationId"]
            )

            // Analysis Suggestions table (for dedupe/summary - don't overwrite source data)
            try db.create(table: "analysis_suggestions") { t in
                t.column("id", .text).primaryKey()
                t.column("queueId", .text)
                    .notNull()
                    .references("analysis_queue", onDelete: .cascade)
                t.column("suggestionType", .text).notNull()  // 'title', 'summary', 'merge_learnings', 'dedupe'
                t.column("targetId", .text)  // conversation_id or learning_id being modified

                // Suggestion content
                t.column("suggestedValue", .text)
                t.column("originalValue", .text)
                t.column("confidence", .double)
                t.column("reasoning", .text)

                // User review
                t.column("status", .text).notNull().defaults(to: "pending")  // 'pending', 'approved', 'rejected'
                t.column("reviewedAt", .datetime)
                t.column("rejectReason", .text)

                // For merge suggestions
                t.column("mergeSourceIds", .text)  // JSON array of learning IDs to merge

                t.column("createdAt", .datetime).notNull()
            }

            try db.create(
                index: "analysis_suggestions_status",
                on: "analysis_suggestions",
                columns: ["status", "createdAt"]
            )

            try db.create(
                index: "analysis_suggestions_target",
                on: "analysis_suggestions",
                columns: ["targetId"]
            )

            // Add source_queue_id to learnings for idempotency tracking
            try db.alter(table: "learnings") { t in
                t.add(column: "sourceQueueId", .text)
                    .references("analysis_queue", onDelete: .setNull)
                t.add(column: "ruleHash", .integer)
            }

            try db.create(
                index: "learnings_sourceQueueId",
                on: "learnings",
                columns: ["sourceQueueId"],
                ifNotExists: true
            )

            // Add source_queue_id to workflow_signatures for idempotency tracking
            try db.alter(table: "workflow_signatures") { t in
                t.add(column: "sourceQueueId", .text)
                    .references("analysis_queue", onDelete: .setNull)
                t.add(column: "confidence", .double)
            }

            try db.create(
                index: "workflow_signatures_sourceQueueId",
                on: "workflow_signatures",
                columns: ["sourceQueueId"],
                ifNotExists: true
            )
        }

        // Version 9: Add partial unique index to prevent duplicate active queue items
        migrator.registerMigration("v9_queue_unique_active") { db in
            // Partial unique index: only one ACTIVE item per conversation+type
            // Active = pending OR claimed (not completed/failed)
            // This prevents duplicate analysis requests for the same conversation+type
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_queue_active_unique
                ON analysis_queue(conversationId, analysisType)
                WHERE status IN ('pending', 'claimed')
                """)
        }

        // Version 10: Provenance fields for learnings + workflow signatures
        migrator.registerMigration("v10_provenance_fields") { db in
            try db.alter(table: "learnings") { t in
                t.add(column: "source", .text)
                t.add(column: "detectorVersion", .text)
            }

            try db.alter(table: "workflow_signatures") { t in
                t.add(column: "source", .text)
                t.add(column: "detectorVersion", .text)
                t.add(column: "isPriming", .boolean).notNull().defaults(to: false)
            }
        }

        // Version 11: Evidence snippets for learnings
        migrator.registerMigration("v11_learning_evidence") { db in
            try db.alter(table: "learnings") { t in
                t.add(column: "evidence", .text)
            }
        }

        // Version 12: Source file path for CLI conversations
        migrator.registerMigration("v12_source_file_path") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "sourceFilePath", .text)
            }
        }

        return migrator
    }
}

// MARK: - Database Access

extension AppDatabase {
    /// Reader for database reads
    var reader: any DatabaseReader {
        dbWriter
    }

    /// Writer for database writes
    var writer: any DatabaseWriter {
        dbWriter
    }

    /// Read from the database
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    /// Write to the database
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }

    /// Clear all persisted app data (conversations, messages, learnings, workflows).
    func resetAllData() throws {
        try write { db in
            try db.execute(sql: "DELETE FROM workflow_signatures")
            try db.execute(sql: "DELETE FROM learnings")
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM conversations")
            try db.execute(sql: "DELETE FROM messages_fts")
            try db.execute(sql: "DELETE FROM conversations_fts")
        }
    }

    /// Observe database changes
    func observe<T: FetchableRecord>(
        _ request: some FetchRequest<T>,
        onChange: @escaping ([T]) -> Void
    ) -> DatabaseCancellable {
        ValueObservation
            .tracking(request.fetchAll)
            .start(in: dbWriter, onError: { error in
                print("Database observation error: \(error)")
            }, onChange: onChange)
    }
}
