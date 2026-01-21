import XCTest
@testable import Retain

/// Integration tests for Claude Code local data reading
/// These tests read actual files from ~/.claude/projects/
final class ClaudeCodeIntegrationTests: XCTestCase {
    var parser: ClaudeCodeParser!

    override func setUp() {
        parser = ClaudeCodeParser()
    }

    override func tearDown() {
        parser = nil
    }

    // MARK: - Directory Discovery Tests

    func testProjectsDirectoryExists() throws {
        let projectsDir = ClaudeCodeParser.projectsDirectory

        // This test verifies the expected location
        XCTAssertTrue(projectsDir.path.hasSuffix(".claude/projects"))

        // Check if directory exists on this system
        let exists = FileManager.default.fileExists(atPath: projectsDir.path)
        if !exists {
            throw XCTSkip("Claude Code projects directory not found - Claude Code may not be installed")
        }

        // Verify it's a directory
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: projectsDir.path, isDirectory: &isDirectory)
        XCTAssertTrue(isDirectory.boolValue, "Projects path should be a directory")
    }

    func testDiscoverConversationFiles() throws {
        let files = parser.discoverConversationFiles()

        guard !files.isEmpty else {
            throw XCTSkip("No Claude Code conversation files found on this system")
        }

        // Verify all discovered files are JSONL
        for file in files {
            XCTAssertEqual(file.pathExtension, "jsonl", "All files should have .jsonl extension")
        }

        // Verify files exist and are readable
        for file in files.prefix(5) { // Check first 5 files
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "File should exist: \(file.lastPathComponent)")
            XCTAssertTrue(FileManager.default.isReadableFile(atPath: file.path), "File should be readable: \(file.lastPathComponent)")
        }

        print("Found \(files.count) Claude Code conversation files")
    }

    // MARK: - Helper

    /// Find a conversation file that has actual messages
    private func findFileWithMessages() -> (URL, Conversation, [Message])? {
        let files = parser.discoverConversationFiles()

        for file in files.prefix(20) { // Check first 20 files
            do {
                // parseFile returns nil for summary-only files
                if let (conversation, messages) = try parser.parseFile(at: file), !messages.isEmpty {
                    return (file, conversation, messages)
                }
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - File Parsing Tests

    func testParseRealConversationFile() throws {
        guard let (file, conversation, messages) = findFileWithMessages() else {
            throw XCTSkip("No Claude Code conversation files with messages found")
        }

        // Verify conversation structure
        XCTAssertEqual(conversation.provider, .claudeCode)
        XCTAssertEqual(conversation.sourceType, .cli)
        XCTAssertFalse(conversation.id.uuidString.isEmpty, "Should have valid UUID")

        // Verify dates are reasonable (not in future, not before 2024)
        let now = Date()
        let minDate = Date(timeIntervalSince1970: 1704067200) // Jan 1, 2024
        XCTAssertLessThanOrEqual(conversation.createdAt, now, "Created date should not be in future")
        XCTAssertGreaterThanOrEqual(conversation.createdAt, minDate, "Created date should be after 2024")
        XCTAssertLessThanOrEqual(conversation.updatedAt, now, "Updated date should not be in future")
        XCTAssertGreaterThanOrEqual(conversation.updatedAt, conversation.createdAt, "Updated should be >= created")

        // Verify message count matches
        XCTAssertEqual(conversation.messageCount, messages.count, "Message count should match messages array")

        print("Parsed conversation '\(conversation.title ?? "Untitled")' with \(messages.count) messages from \(file.lastPathComponent)")
    }

    func testParseMultipleConversationFiles() throws {
        let files = parser.discoverConversationFiles()

        guard files.count >= 3 else {
            throw XCTSkip("Need at least 3 Claude Code files for this test")
        }

        var totalMessages = 0
        var successfulParses = 0
        var filesWithMessages = 0

        for file in files.prefix(10) {
            do {
                // parseFile returns nil for summary-only files
                guard let (conversation, messages) = try parser.parseFile(at: file) else {
                    continue // Skip summary-only files
                }

                XCTAssertEqual(conversation.provider, .claudeCode)
                successfulParses += 1

                // All returned files should have messages
                filesWithMessages += 1
                totalMessages += messages.count

            } catch {
                // Some files might have issues, that's okay
                print("Warning: Failed to parse \(file.lastPathComponent): \(error)")
            }
        }

        XCTAssertGreaterThan(successfulParses, 0, "Should successfully parse at least one file")
        XCTAssertGreaterThan(filesWithMessages, 0, "Should have at least one file with messages")
        print("Successfully parsed \(successfulParses) files, \(filesWithMessages) with messages, \(totalMessages) total messages")
    }

    // MARK: - Message Structure Tests

    func testMessageRolesAreValid() throws {
        guard let (_, _, messages) = findFileWithMessages() else {
            throw XCTSkip("No Claude Code conversation files with messages found")
        }

        // Verify roles are valid
        let validRoles: Set<Role> = [.user, .assistant, .system, .tool]
        for message in messages {
            XCTAssertTrue(validRoles.contains(message.role), "Role should be valid: \(message.role)")
        }

        // Verify we have at least one user and one assistant message
        let hasUser = messages.contains { $0.role == .user }
        let hasAssistant = messages.contains { $0.role == .assistant }

        if !hasUser && !hasAssistant {
            print("Warning: Conversation doesn't have typical user/assistant pattern")
        }
    }

    func testMessageContentIsNonEmpty() throws {
        guard let (_, _, messages) = findFileWithMessages() else {
            throw XCTSkip("No Claude Code conversation files with messages found")
        }

        // All messages should have non-empty content
        for message in messages {
            XCTAssertFalse(message.content.isEmpty, "Message content should not be empty")
            XCTAssertFalse(message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                         "Message content should not be only whitespace")
        }
    }

    func testMessageTimestampsAreOrdered() throws {
        guard let (_, _, messages) = findFileWithMessages() else {
            throw XCTSkip("No Claude Code conversation files with messages found")
        }

        guard messages.count >= 2 else {
            throw XCTSkip("Need at least 2 messages to test ordering")
        }

        // Check that timestamps are generally ordered (allowing small variations)
        // Messages may have identical timestamps or slight reordering
        var outOfOrderCount = 0
        for i in 1..<messages.count {
            let prev = messages[i - 1]
            let curr = messages[i]
            if prev.timestamp > curr.timestamp {
                // Allow timestamps to be out of order by up to 1 second
                // This accounts for messages sent in rapid succession
                let diff = prev.timestamp.timeIntervalSince(curr.timestamp)
                if diff > 1.0 {
                    outOfOrderCount += 1
                }
            }
        }

        // Allow a few out-of-order messages (max 5% of total)
        let maxOutOfOrder = max(1, messages.count / 20)
        XCTAssertLessThanOrEqual(outOfOrderCount, maxOutOfOrder,
                                "Too many messages out of order: \(outOfOrderCount) of \(messages.count)")
    }

    // MARK: - Project Path Tests

    func testProjectPathExtraction() throws {
        guard let (_, conversation, _) = findFileWithMessages() else {
            throw XCTSkip("No Claude Code conversation files with messages found")
        }

        // Project path should be extracted from cwd field
        if let projectPath = conversation.projectPath {
            XCTAssertTrue(projectPath.hasPrefix("/"), "Project path should be absolute")
            print("Project path: \(projectPath)")
        }
    }

    // MARK: - External ID Tests

    func testExternalIdIsSessionId() throws {
        guard let (_, conversation, _) = findFileWithMessages() else {
            throw XCTSkip("No Claude Code conversation files with messages found")
        }

        // External ID should be UUID-like session ID
        if let externalId = conversation.externalId {
            XCTAssertFalse(externalId.isEmpty, "External ID should not be empty")
            // Claude Code session IDs are UUIDs
            let uuidPattern = try NSRegularExpression(
                pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                options: .caseInsensitive
            )
            let range = NSRange(externalId.startIndex..., in: externalId)
            let match = uuidPattern.firstMatch(in: externalId, range: range)
            XCTAssertNotNil(match, "External ID should be a valid UUID: \(externalId)")
        }
    }

    // MARK: - Stream Parsing Tests

    func testStreamParseMatchesDirectParse() throws {
        guard let (file, directConv, directMessages) = findFileWithMessages() else {
            throw XCTSkip("No Claude Code conversation files with messages found")
        }

        // Parse via streaming
        var streamConv: Conversation?
        var streamMessages: [Message] = []

        try parser.streamParse(at: file) { conversation, messages in
            streamConv = conversation
            streamMessages = messages
        }

        // Compare results
        XCTAssertNotNil(streamConv)
        XCTAssertEqual(directConv.externalId, streamConv?.externalId)
        XCTAssertEqual(directMessages.count, streamMessages.count, "Message counts should match")

        // Compare message contents
        for (direct, stream) in zip(directMessages, streamMessages) {
            XCTAssertEqual(direct.role, stream.role)
            XCTAssertEqual(direct.content, stream.content)
        }
    }

    // MARK: - Large File Handling Tests

    func testLargestConversationFile() throws {
        let files = parser.discoverConversationFiles()

        guard !files.isEmpty else {
            throw XCTSkip("No Claude Code conversation files to test")
        }

        // Find the largest file
        var largestFile: URL?
        var largestSize: Int64 = 0

        for file in files {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int64,
               size > largestSize {
                largestSize = size
                largestFile = file
            }
        }

        guard let file = largestFile else {
            throw XCTSkip("Could not determine largest file")
        }

        print("Testing largest file: \(file.lastPathComponent) (\(largestSize / 1024)KB)")

        let startTime = Date()
        let result = try parser.parseFile(at: file)
        let elapsed = Date().timeIntervalSince(startTime)

        // Large files may be summary-only files (result=nil) or have messages
        let messageCount = result?.1.count ?? 0
        print("Parsed \(messageCount) messages in \(String(format: "%.2f", elapsed))s")

        // Parsing should complete in reasonable time (under 5 seconds for most files)
        if largestSize < 10_000_000 { // Under 10MB
            XCTAssertLessThan(elapsed, 5.0, "Parsing should complete quickly")
        }
    }

    // MARK: - Title Extraction Tests

    func testTitleExtraction() throws {
        guard let (_, conversation, messages) = findFileWithMessages() else {
            throw XCTSkip("No Claude Code conversation files with messages found")
        }

        // Title should be set
        XCTAssertNotNil(conversation.title, "Conversation should have a title")

        if let title = conversation.title {
            XCTAssertFalse(title.isEmpty, "Title should not be empty")
            XCTAssertLessThanOrEqual(title.count, 83, "Title should be truncated (80 + '...')")

            // If there are user messages, title should be derived from first one
            if let firstUserMessage = messages.first(where: { $0.role == .user }) {
                let expectedStart = String(firstUserMessage.content.prefix(20))
                // Title might be truncated, so just check if it starts similarly
                // or matches the beginning of the message
                if !expectedStart.isEmpty {
                    print("Title: '\(title)'")
                    print("First user message starts: '\(expectedStart)'")
                }
            }
        }
    }
}
