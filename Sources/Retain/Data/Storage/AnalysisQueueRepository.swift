import Foundation
import GRDB

/// Repository for analysis queue with concurrency-safe claiming
final class AnalysisQueueRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Queue Operations

    /// Insert a new queue item
    func insert(_ item: AnalysisQueueItem) throws {
        try database.write { db in
            var newItem = item
            try newItem.insert(db)
        }
    }

    /// Insert multiple queue items
    func insert(_ items: [AnalysisQueueItem]) throws {
        try database.write { db in
            for var item in items {
                try item.insert(db)
            }
        }
    }

    /// Fetch a queue item by ID
    func fetch(id: String) throws -> AnalysisQueueItem? {
        try database.read { db in
            try AnalysisQueueItem.fetchOne(db, key: id)
        }
    }

    /// Fetch all pending items
    func fetchPending() throws -> [AnalysisQueueItem] {
        try database.read { db in
            try AnalysisQueueItem
                .filter(AnalysisQueueItem.Columns.status == "pending")
                .order(AnalysisQueueItem.Columns.priority.desc, AnalysisQueueItem.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// Fetch completed items that haven't been applied yet
    func fetchUnprocessedCompleted() throws -> [AnalysisQueueItem] {
        try database.read { db in
            try AnalysisQueueItem
                .filter(AnalysisQueueItem.Columns.status == "completed")
                .filter(AnalysisQueueItem.Columns.resultsAppliedAt == nil)
                .order(AnalysisQueueItem.Columns.completedAt.asc)
                .fetchAll(db)
        }
    }

    // MARK: - Atomic Claiming

    /// Claim N pending items atomically using CTE (prevents race conditions)
    /// Uses UPDATE ... WHERE ... pattern with re-check for true atomicity
    func claimPendingItems(count: Int, claimedBy: String) throws -> [AnalysisQueueItem] {
        try database.write { db in
            let now = Date()

            // SQLite doesn't support UPDATE RETURNING in older versions,
            // so we use a two-step atomic approach within the same transaction:
            // 1. Select IDs to claim with FOR UPDATE semantics (implicit in write transaction)
            // 2. Update those specific IDs with status re-check

            // Step 1: Find candidate IDs
            let candidateIds = try String.fetchAll(db, sql: """
                SELECT id FROM analysis_queue
                WHERE status = 'pending'
                  AND attemptCount < maxAttempts
                ORDER BY priority DESC, createdAt ASC
                LIMIT ?
                """,
                arguments: [count]
            )

            guard !candidateIds.isEmpty else { return [] }

            // Step 2: Claim them atomically with status re-check
            let placeholders = candidateIds.map { _ in "?" }.joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [claimedBy, now]
            arguments.append(contentsOf: candidateIds)

            try db.execute(
                sql: """
                    UPDATE analysis_queue
                    SET status = 'claimed',
                        claimedBy = ?,
                        claimedAt = ?,
                        attemptCount = attemptCount + 1
                    WHERE id IN (\(placeholders))
                      AND status = 'pending'
                    """,
                arguments: StatementArguments(arguments)
            )

            // Step 3: Fetch the items we just claimed
            return try AnalysisQueueItem
                .filter(candidateIds.contains(AnalysisQueueItem.Columns.id))
                .filter(AnalysisQueueItem.Columns.status == "claimed")
                .filter(AnalysisQueueItem.Columns.claimedBy == claimedBy)
                .fetchAll(db)
        }
    }

    /// Mark item completed with result JSON
    func markCompleted(id: String, resultJSON: String, backend: String, model: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE analysis_queue
                    SET status = 'completed',
                        completedAt = ?,
                        resultJson = ?,
                        backend = ?,
                        model = ?
                    WHERE id = ? AND status = 'claimed'
                    """,
                arguments: [Date(), resultJSON, backend, model, id]
            )
            guard db.changesCount > 0 else {
                throw QueueError.itemNotClaimed(id)
            }
        }
    }

    /// Mark item failed with error
    func markFailed(id: String, error: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE analysis_queue
                    SET status = 'failed',
                        completedAt = ?,
                        errorMessage = ?
                    WHERE id = ? AND status = 'claimed'
                    """,
                arguments: [Date(), error, id]
            )
        }
    }

    /// Mark results as applied (idempotency tracking)
    func markResultsApplied(id: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE analysis_queue
                    SET resultsAppliedAt = ?
                    WHERE id = ?
                    """,
                arguments: [Date(), id]
            )
        }
    }

    /// Mark result application as failed (non-retryable errors like decode failures)
    /// Sets resultsAppliedAt to prevent infinite retry while preserving error info
    func markResultApplicationFailed(id: String, error: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE analysis_queue
                    SET status = 'failed',
                        errorMessage = ?,
                        resultsAppliedAt = ?
                    WHERE id = ?
                    """,
                arguments: [error, Date(), id]
            )
        }
    }

    /// Release stale claims (for crash recovery)
    /// Called periodically by StaleClaimsReaper
    func releaseStaleClaims(olderThan threshold: TimeInterval) throws -> Int {
        try database.write { db in
            let cutoff = Date().addingTimeInterval(-threshold)

            try db.execute(
                sql: """
                    UPDATE analysis_queue
                    SET status = 'pending',
                        claimedBy = NULL,
                        claimedAt = NULL
                    WHERE status = 'claimed'
                      AND claimedAt < ?
                      AND attemptCount < maxAttempts
                    """,
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

    /// Delete old completed/failed items (cleanup)
    func deleteOldItems(olderThan threshold: TimeInterval) throws -> Int {
        try database.write { db in
            let cutoff = Date().addingTimeInterval(-threshold)

            try db.execute(
                sql: """
                    DELETE FROM analysis_queue
                    WHERE status IN ('completed', 'failed')
                      AND completedAt < ?
                      AND resultsAppliedAt IS NOT NULL
                    """,
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

    // MARK: - Suggestions

    /// Insert a suggestion
    func insertSuggestion(_ suggestion: AnalysisSuggestion) throws {
        try database.write { db in
            var newSuggestion = suggestion
            try newSuggestion.insert(db)
        }
    }

    /// Fetch pending suggestions
    func fetchPendingSuggestions() throws -> [AnalysisSuggestion] {
        try database.read { db in
            try AnalysisSuggestion
                .filter(AnalysisSuggestion.Columns.status == "pending")
                .order(AnalysisSuggestion.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// Fetch suggestions for a queue item
    func fetchSuggestions(queueId: String) throws -> [AnalysisSuggestion] {
        try database.read { db in
            try AnalysisSuggestion
                .filter(AnalysisSuggestion.Columns.queueId == queueId)
                .fetchAll(db)
        }
    }

    /// Approve a suggestion
    func approveSuggestion(id: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE analysis_suggestions
                    SET status = 'approved',
                        reviewedAt = ?
                    WHERE id = ?
                    """,
                arguments: [Date(), id]
            )
        }
    }

    /// Reject a suggestion with reason
    func rejectSuggestion(id: String, reason: String?) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE analysis_suggestions
                    SET status = 'rejected',
                        reviewedAt = ?,
                        rejectReason = ?
                    WHERE id = ?
                    """,
                arguments: [Date(), reason, id]
            )
        }
    }

    // MARK: - Errors

    enum QueueError: LocalizedError {
        case itemNotClaimed(String)
        case itemNotFound(String)

        var errorDescription: String? {
            switch self {
            case .itemNotClaimed(let id):
                return "Queue item \(id) was not in claimed state"
            case .itemNotFound(let id):
                return "Queue item \(id) not found"
            }
        }
    }
}
