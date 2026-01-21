import Foundation
import SQLite3

/// Helper class to validate UI state against database state.
/// Provides direct database queries to verify that UI displays correct data.
/// Uses SQLite3 directly since UI tests run in a separate process.
class SemanticTestHelper {

    /// Path to the Retain database
    static let dbPath: String = {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir
            .appendingPathComponent("Library/Application Support/Retain/retain.sqlite")
            .path
    }()

    /// Open a read-only connection to the database
    private static func openDatabase() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX

        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            print("⚠️ SemanticTestHelper: Could not open database at \(dbPath)")
            return nil
        }
        return db
    }

    /// Close the database connection
    private static func closeDatabase(_ db: OpaquePointer?) {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Conversation Queries

    /// Get total count of conversations
    static func conversationCount() -> Int {
        guard let db = openDatabase() else { return 0 }
        defer { closeDatabase(db) }

        return executeCountQuery(db: db, sql: "SELECT COUNT(*) FROM conversations")
    }

    /// Get count of conversations for a specific provider
    static func conversationCount(provider: String) -> Int {
        guard let db = openDatabase() else { return 0 }
        defer { closeDatabase(db) }

        return executeCountQuery(
            db: db,
            sql: "SELECT COUNT(*) FROM conversations WHERE provider = ?",
            parameters: [provider]
        )
    }

    /// Get count of conversations updated today
    static func todayConversationCount() -> Int {
        guard let db = openDatabase() else { return 0 }
        defer { closeDatabase(db) }

        return executeCountQuery(
            db: db,
            sql: "SELECT COUNT(*) FROM conversations WHERE date(updatedAt) = date('now')"
        )
    }

    /// Get count of conversations updated this week
    static func thisWeekConversationCount() -> Int {
        guard let db = openDatabase() else { return 0 }
        defer { closeDatabase(db) }

        return executeCountQuery(
            db: db,
            sql: """
                SELECT COUNT(*) FROM conversations
                WHERE updatedAt >= date('now', 'weekday 0', '-7 days')
            """
        )
    }

    // MARK: - Learnings Queries

    /// Get count of conversations with learnings
    static func conversationsWithLearningsCount() -> Int {
        guard let db = openDatabase() else { return 0 }
        defer { closeDatabase(db) }

        return executeCountQuery(
            db: db,
            sql: """
                SELECT COUNT(DISTINCT conversationId) FROM learnings
                WHERE status IN ('pending', 'approved')
            """
        )
    }

    /// Get count of learnings by status
    static func learningsCount(status: String) -> Int {
        guard let db = openDatabase() else { return 0 }
        defer { closeDatabase(db) }

        return executeCountQuery(
            db: db,
            sql: "SELECT COUNT(*) FROM learnings WHERE status = ?",
            parameters: [status]
        )
    }

    /// Get count of pending learnings
    static func pendingLearningsCount() -> Int {
        return learningsCount(status: "pending")
    }

    /// Get count of approved learnings
    static func approvedLearningsCount() -> Int {
        return learningsCount(status: "approved")
    }

    // MARK: - Message Queries

    /// Get total message count
    static func messageCount() -> Int {
        guard let db = openDatabase() else { return 0 }
        defer { closeDatabase(db) }

        return executeCountQuery(db: db, sql: "SELECT COUNT(*) FROM messages")
    }

    /// Get message count for a specific conversation
    static func messageCount(conversationId: String) -> Int {
        guard let db = openDatabase() else { return 0 }
        defer { closeDatabase(db) }

        return executeCountQuery(
            db: db,
            sql: "SELECT COUNT(*) FROM messages WHERE conversationId = ?",
            parameters: [conversationId]
        )
    }

    // MARK: - Search Queries

    /// Search conversations by text (using FTS5)
    static func searchConversations(query: String) -> Int {
        guard let db = openDatabase() else { return 0 }
        defer { closeDatabase(db) }

        // Try FTS5 search if available
        let ftsCount = executeCountQuery(
            db: db,
            sql: """
                SELECT COUNT(DISTINCT m.conversationId) FROM messages_fts f
                JOIN messages m ON f.rowid = m.rowid
                WHERE messages_fts MATCH ?
            """,
            parameters: [query]
        )

        if ftsCount > 0 {
            return ftsCount
        }

        // Fallback to LIKE search
        return executeCountQuery(
            db: db,
            sql: """
                SELECT COUNT(DISTINCT conversationId) FROM messages
                WHERE content LIKE ?
            """,
            parameters: ["%\(query)%"]
        )
    }

    // MARK: - Provider Statistics

    /// Get conversation counts per provider
    static func providerStats() -> [String: Int] {
        guard let db = openDatabase() else { return [:] }
        defer { closeDatabase(db) }

        var stats: [String: Int] = [:]
        let sql = "SELECT provider, COUNT(*) as count FROM conversations GROUP BY provider"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return stats
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let providerPtr = sqlite3_column_text(stmt, 0) {
                let provider = String(cString: providerPtr)
                let count = Int(sqlite3_column_int(stmt, 1))
                stats[provider] = count
            }
        }

        return stats
    }

    // MARK: - Validation Helpers

    /// Verify database exists and is accessible
    static func isDatabaseAccessible() -> Bool {
        let fileExists = FileManager.default.fileExists(atPath: dbPath)
        guard fileExists else { return false }

        guard let db = openDatabase() else { return false }
        defer { closeDatabase(db) }

        // Try a simple query
        let count = executeCountQuery(db: db, sql: "SELECT COUNT(*) FROM sqlite_master")
        return count >= 0
    }

    /// Get database file size
    static func databaseSize() -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    // MARK: - Private Helpers

    private static func executeCountQuery(
        db: OpaquePointer,
        sql: String,
        parameters: [String] = []
    ) -> Int {
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            print("⚠️ SemanticTestHelper SQL error: \(errorMsg)")
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        // Bind parameters
        for (index, param) in parameters.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), param, -1, nil)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(stmt, 0))
    }
}

// MARK: - Test Assertions Extension

extension SemanticTestHelper {

    /// Assert that conversation count matches UI display
    static func assertConversationCount(
        expected: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Bool {
        let actual = conversationCount()
        let matches = actual == expected
        if !matches {
            print("⚠️ Conversation count mismatch: expected \(expected), got \(actual)")
        }
        return matches
    }

    /// Assert that provider has expected conversation count
    static func assertProviderCount(
        provider: String,
        expected: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Bool {
        let actual = conversationCount(provider: provider)
        let matches = actual == expected
        if !matches {
            print("⚠️ Provider \(provider) count mismatch: expected \(expected), got \(actual)")
        }
        return matches
    }

    /// Assert that search returns expected number of results
    static func assertSearchResults(
        query: String,
        minExpected: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Bool {
        let actual = searchConversations(query: query)
        let matches = actual >= minExpected
        if !matches {
            print("⚠️ Search '\(query)' result mismatch: expected >= \(minExpected), got \(actual)")
        }
        return matches
    }
}
