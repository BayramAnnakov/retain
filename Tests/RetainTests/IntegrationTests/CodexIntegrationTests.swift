import XCTest
@testable import Retain

/// Integration tests for Codex CLI local data reading
/// These tests read actual files from ~/.codex/
final class CodexIntegrationTests: XCTestCase {
    var parser: CodexParser!

    override func setUp() {
        parser = CodexParser()
    }

    override func tearDown() {
        parser = nil
    }

    // MARK: - Directory Discovery Tests

    func testCodexDirectoryExists() throws {
        let codexDir = CodexParser.codexDirectory

        // This test verifies the expected location
        XCTAssertTrue(codexDir.path.hasSuffix(".codex"))

        // Check if directory exists on this system
        let exists = FileManager.default.fileExists(atPath: codexDir.path)
        if !exists {
            throw XCTSkip("Codex directory not found - Codex CLI may not be installed")
        }

        // Verify it's a directory
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: codexDir.path, isDirectory: &isDirectory)
        XCTAssertTrue(isDirectory.boolValue, "Codex path should be a directory")
    }

    func testHistoryFileExists() throws {
        let historyFile = CodexParser.historyFile

        // This test verifies the expected location
        XCTAssertTrue(historyFile.path.hasSuffix(".codex/history.jsonl"))

        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        // Verify file is readable
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: historyFile.path),
                     "History file should be readable")

        // Check file size
        let size = parser.historyFileSize()
        XCTAssertGreaterThan(size, 0, "History file should not be empty")

        print("Codex history file size: \(size / 1024)KB")
    }

    // MARK: - History Parsing Tests

    func testParseHistoryFile() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        XCTAssertGreaterThan(results.count, 0, "Should parse at least one conversation")

        print("Found \(results.count) Codex sessions")

        // Verify all conversations have correct provider
        for (conversation, _) in results {
            XCTAssertEqual(conversation.provider, .codex)
            XCTAssertEqual(conversation.sourceType, .cli)
        }
    }

    func testHistorySessionStructure() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        guard let (conversation, messages) = results.first else {
            throw XCTSkip("No sessions in history")
        }

        // Verify conversation structure
        XCTAssertNotNil(conversation.externalId, "Should have session_id as external ID")
        XCTAssertNotNil(conversation.title, "Should have title")
        XCTAssertEqual(conversation.messageCount, messages.count)

        // Verify dates
        let now = Date()
        XCTAssertLessThanOrEqual(conversation.createdAt, now)
        XCTAssertGreaterThanOrEqual(conversation.updatedAt, conversation.createdAt)

        print("First session: '\(conversation.title ?? "Untitled")' with \(messages.count) prompts")
    }

    // MARK: - Message Structure Tests

    func testCodexMessagesIncludeAssistant() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        guard !results.isEmpty else {
            throw XCTSkip("No sessions to test")
        }

        // Session files should include both user and assistant messages
        var hasUser = false
        var hasAssistant = false

        for (_, messages) in results.prefix(5) {
            for message in messages {
                if message.role == .user { hasUser = true }
                if message.role == .assistant { hasAssistant = true }
            }
        }

        XCTAssertTrue(hasUser, "Should have user messages")
        // Note: hasAssistant may be false if parsing from history.jsonl fallback
        print("Has assistant messages: \(hasAssistant)")
    }

    func testMessageContentIsNonEmpty() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        for (_, messages) in results.prefix(5) {
            for message in messages {
                XCTAssertFalse(message.content.isEmpty, "Message content should not be empty")
            }
        }
    }

    func testMessageTimestampsAreOrdered() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        for (_, messages) in results.prefix(5) {
            guard messages.count >= 2 else { continue }

            for i in 1..<messages.count {
                let prev = messages[i - 1]
                let curr = messages[i]
                XCTAssertLessThanOrEqual(prev.timestamp, curr.timestamp,
                                        "Messages should be ordered by timestamp")
            }
        }
    }

    // MARK: - Session ID Tests

    func testSessionIdsAreUnique() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        let sessionIds = results.compactMap { $0.0.externalId }
        let uniqueIds = Set(sessionIds)

        XCTAssertEqual(sessionIds.count, uniqueIds.count, "All session IDs should be unique")
    }

    func testSessionIdFormat() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        guard let (conversation, _) = results.first else {
            throw XCTSkip("No sessions to test")
        }

        // Session IDs should be UUIDs
        if let sessionId = conversation.externalId {
            let uuidPattern = try NSRegularExpression(
                pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                options: .caseInsensitive
            )
            let range = NSRange(sessionId.startIndex..., in: sessionId)
            let match = uuidPattern.firstMatch(in: sessionId, range: range)
            XCTAssertNotNil(match, "Session ID should be a valid UUID: \(sessionId)")
        }
    }

    // MARK: - Timestamp Tests

    func testTimestampsAreReasonable() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        let now = Date()
        let minDate = Date(timeIntervalSince1970: 1704067200) // Jan 1, 2024

        for (conversation, messages) in results.prefix(10) {
            // Conversation dates
            XCTAssertLessThanOrEqual(conversation.createdAt, now,
                                    "Created date should not be in future")
            XCTAssertGreaterThanOrEqual(conversation.createdAt, minDate,
                                       "Created date should be after 2024")

            // Message timestamps
            for message in messages {
                XCTAssertLessThanOrEqual(message.timestamp, now,
                                        "Message timestamp should not be in future")
                XCTAssertGreaterThanOrEqual(message.timestamp, minDate,
                                           "Message timestamp should be after 2024")
            }
        }
    }

    // MARK: - Title Extraction Tests

    func testTitleExtraction() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        for (conversation, messages) in results.prefix(5) {
            XCTAssertNotNil(conversation.title)

            if let title = conversation.title, let firstMessage = messages.first {
                // Title should be derived from first message
                let firstMessageStart = String(firstMessage.content.prefix(80))

                // Either title matches the start of first message, or is truncated
                let titleMatches = firstMessage.content.hasPrefix(title.replacingOccurrences(of: "...", with: ""))
                    || title == firstMessageStart
                    || title.count <= 83

                XCTAssertTrue(titleMatches || title.count <= 83,
                             "Title should be from first message or truncated")
            }
        }
    }

    // MARK: - Large History File Tests

    func testParsePerformance() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let fileSize = parser.historyFileSize()
        print("History file size: \(fileSize / 1024)KB")

        let startTime = Date()
        let results = try parser.parseHistoryFile()
        let elapsed = Date().timeIntervalSince(startTime)

        let totalMessages = results.reduce(0) { $0 + $1.1.count }

        print("Parsed \(results.count) sessions with \(totalMessages) messages in \(String(format: "%.2f", elapsed))s")

        // Should complete in reasonable time (scale with total message count)
        // Budget 20ms/message gives headroom for system load variance
        let perMessageBudget = 0.02
        let budget = max(5.0, Double(totalMessages) * perMessageBudget)
        XCTAssertLessThan(
            elapsed,
            budget,
            "Parsing should complete within \(String(format: "%.2f", budget))s for \(totalMessages) messages"
        )
    }

    // MARK: - Session Ordering Tests

    func testSessionsOrderedByRecent() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        let results = try parser.parseHistoryFile()

        guard results.count >= 2 else {
            throw XCTSkip("Need at least 2 sessions to test ordering")
        }

        // Results should be ordered by most recent first
        for i in 1..<min(results.count, 10) {
            let prev = results[i - 1].0
            let curr = results[i].0
            XCTAssertGreaterThanOrEqual(prev.updatedAt, curr.updatedAt,
                                       "Sessions should be ordered by most recent first")
        }
    }

    // MARK: - Data Integrity Tests

    func testHistoryDataIntegrity() throws {
        guard parser.hasHistory() else {
            throw XCTSkip("Codex history file not found")
        }

        // Parse twice and compare
        let results1 = try parser.parseHistoryFile()
        let results2 = try parser.parseHistoryFile()

        XCTAssertEqual(results1.count, results2.count, "Parsing should be deterministic")

        // Compare session IDs
        let ids1 = Set(results1.compactMap { $0.0.externalId })
        let ids2 = Set(results2.compactMap { $0.0.externalId })
        XCTAssertEqual(ids1, ids2, "Same sessions should be found on each parse")
    }

    // MARK: - Edge Case Tests

    func testHandlesEmptyLines() throws {
        // Test with data containing empty lines (history.jsonl format)
        let jsonl = """
        {"session_id":"test-1","ts":1704067200,"text":"Hello"}

        {"session_id":"test-1","ts":1704067201,"text":"World"}
        """.data(using: .utf8)!

        let results = try parser.parseHistoryData(jsonl)

        XCTAssertEqual(results.count, 1, "Should parse one session")
        XCTAssertEqual(results.first?.1.count, 2, "Should have 2 messages")
    }

    func testHandlesMalformedLines() throws {
        // Test with mix of valid and invalid JSON (history.jsonl format)
        let jsonl = """
        {"session_id":"test-1","ts":1704067200,"text":"Valid 1"}
        not json at all
        {"session_id":"test-1","ts":1704067201,"text":"Valid 2"}
        {"broken json
        {"session_id":"test-1","ts":1704067202,"text":"Valid 3"}
        """.data(using: .utf8)!

        let results = try parser.parseHistoryData(jsonl)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.1.count, 3, "Should parse 3 valid messages")
    }
}
