import XCTest
@testable import Retain

final class AntigravityParserTests: XCTestCase {

    // MARK: - Sample Fixtures

    private func makeBasicJSONL() -> Data {
        let lines = [
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":"<USER_REQUEST>\\nHow do I configure Swift Concurrency in Retain?\\n</USER_REQUEST>"}
            """,
            """
            {"step_index":1,"source":"SYSTEM","type":"CONVERSATION_HISTORY","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":""}
            """,
            """
            {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-07-30T15:27:55Z","content":"To configure Swift Concurrency, make sure your services use actors and tasks properly."}
            """
        ]
        return lines.joined(separator: "\n").data(using: .utf8)!
    }

    private func makeMergeTestData() -> (plain: [AntigravityParser.RawRecord], full: [AntigravityParser.RawRecord]) {
        let plainLines = [
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":"<USER_REQUEST>\\nInitial prompt\\n</USER_REQUEST>","truncated_fields":["content"]}
            """,
            """
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-07-30T15:27:55Z","content":"Step 1 truncated...","truncated_fields":["content"]}
            """,
            """
            {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-07-30T15:28:05Z","content":"Step 2 truncated...","truncated_fields":["content"]}
            """
        ]

        // Rolling window containing only steps 1 and 2, but untruncated
        let fullLines = [
            """
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-07-30T15:27:55Z","content":"Step 1 complete full untruncated answer with complete code and explanations."}
            """,
            """
            {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-07-30T15:28:05Z","content":"Step 2 complete full untruncated answer."}
            """
        ]

        let plain = AntigravityParser.parseLines(plainLines, isFullTranscript: false)
        let full = AntigravityParser.parseLines(fullLines, isFullTranscript: true)
        return (plain, full)
    }

    // MARK: - Tests

    func testBasicJSONLParsing() throws {
        let data = makeBasicJSONL()
        let convId = "12345678-1234-1234-1234-123456789abc"
        guard let (conversation, messages) = AntigravityParser.parseData(data, conversationId: convId) else {
            XCTFail("Should parse basic Antigravity JSONL")
            return
        }

        XCTAssertEqual(conversation.provider, .antigravity)
        XCTAssertEqual(conversation.sourceType, .cli)
        XCTAssertEqual(conversation.externalId, convId)
        // Noise type CONVERSATION_HISTORY should be dropped, leaving 2 messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "How do I configure Swift Concurrency in Retain?")
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertTrue(messages[1].content.contains("To configure Swift Concurrency"))
    }

    func testTwoPassMerge() throws {
        let (plain, full) = makeMergeTestData()
        let merged = AntigravityParser.mergeRecords(plain: plain, full: full)

        // All 3 steps must be present (step 0 preserved from plain, steps 1-2 upgraded from full)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].stepIndex, 0)
        XCTAssertEqual(merged[1].stepIndex, 1)
        XCTAssertEqual(merged[2].stepIndex, 2)

        // Step 0 comes from plain
        XCTAssertTrue(merged[0].content?.contains("Initial prompt") == true)

        // Steps 1 and 2 have full untruncated content
        XCTAssertEqual(merged[1].content, "Step 1 complete full untruncated answer with complete code and explanations.")
        XCTAssertEqual(merged[2].content, "Step 2 complete full untruncated answer.")
    }

    func testMultilineTolerantParsing() throws {
        let multilineJSONL = [
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":"<USER_REQUEST>Test</USER_REQUEST>"}
            """,
            """
            {"step_index":1,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","created_at":"2026-07-30T15:27:50Z","content":"Line 1
            Line 2 of multiline output
            Line 3"}
            """,
            """
            {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-07-30T15:27:55Z","content":"Done"}
            """
        ]

        let records = AntigravityParser.parseLines(multilineJSONL, isFullTranscript: true)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[1].stepIndex, 1)
        XCTAssertEqual(records[1].type, "RUN_COMMAND")
    }

    func testISO8601DateParsing() {
        // Antigravity format without fractional seconds
        let dateNoFrac = AntigravityParser.parseISO8601("2026-07-01T09:27:05Z")
        XCTAssertNotNil(dateNoFrac)

        // Format with fractional seconds
        let dateFrac = AntigravityParser.parseISO8601("2026-07-01T09:27:05.123456Z")
        XCTAssertNotNil(dateFrac)

        // Metadata format with offset
        let dateOffset = AntigravityParser.parseISO8601("2026-07-16 07:34:57.157887+00:00")
        XCTAssertNotNil(dateOffset)
    }

    func testRunningToDoneDeduplication() {
        let lines = [
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":"<USER_REQUEST>Hi</USER_REQUEST>"}
            """,
            """
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"RUNNING","created_at":"2026-07-30T15:27:50Z","content":"In progress..."}
            """,
            """
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-07-30T15:27:55Z","content":"Completed final answer."}
            """
        ]

        let records = AntigravityParser.parseLines(lines, isFullTranscript: true)
        let merged = AntigravityParser.mergeRecords(plain: records, full: [])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[1].stepIndex, 1)
        XCTAssertEqual(merged[1].status, "DONE")
        XCTAssertEqual(merged[1].content, "Completed final answer.")
    }

    func testContentCleaning() {
        // Tag unwrapping
        let wrapped = "<USER_REQUEST>\nFix the memory leak\n</USER_REQUEST>"
        XCTAssertEqual(AntigravityParser.cleanUserContent(wrapped), "Fix the memory leak")

        // Metadata and settings stripping
        let withMetadata = """
        <USER_REQUEST>
        Refactor the database layer
        </USER_REQUEST>
        <ADDITIONAL_METADATA>
        The current local time is: 2026-08-18T15:26:23+03:00.
        </ADDITIONAL_METADATA>
        <USER_SETTINGS_CHANGE>
        The user changed setting Model Selection.
        </USER_SETTINGS_CHANGE>
        """
        XCTAssertEqual(AntigravityParser.cleanUserContent(withMetadata), "Refactor the database layer")

        // Unclosed tag handling (truncated history)
        let unclosed = "<USER_REQUEST>\nUnclosed prompt content"
        XCTAssertEqual(AntigravityParser.cleanUserContent(unclosed), "Unclosed prompt content")
    }

    func testNoiseTypeFiltering() {
        let lines = [
            """
            {"step_index":0,"source":"SYSTEM","type":"CONVERSATION_HISTORY","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":"History"}
            """,
            """
            {"step_index":1,"source":"SYSTEM","type":"GENERIC","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":"Generic status"}
            """,
            """
            {"step_index":2,"source":"SYSTEM","type":"EPHEMERAL_MESSAGE","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":"Ephemeral notice"}
            """,
            """
            {"step_index":3,"source":"SYSTEM","type":"DIRECTORY_RULES","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":"Rules"}
            """,
            """
            {"step_index":4,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-07-30T15:27:50Z","content":"<USER_REQUEST>Real question</USER_REQUEST>"}
            """
        ]

        let data = lines.joined(separator: "\n").data(using: .utf8)!
        guard let (_, messages) = AntigravityParser.parseData(data) else {
            XCTFail("Should parse valid user question")
            return
        }

        // Only the 1 real user message should remain
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "Real question")
    }

    func testToolExecutionMapping() {
        let lines = [
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-07-30T15:27:49Z","content":"<USER_REQUEST>Run test</USER_REQUEST>"}
            """,
            """
            {"step_index":1,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","created_at":"2026-07-30T15:27:50Z","content":"Test passed in 0.4s"}
            """,
            """
            {"step_index":2,"source":"MODEL","type":"VIEW_FILE","status":"DONE","created_at":"2026-07-30T15:27:52Z","content":"File contents: func test() {}"}
            """
        ]

        let data = lines.joined(separator: "\n").data(using: .utf8)!
        guard let (_, messages) = AntigravityParser.parseData(data) else {
            XCTFail("Should parse data with tool actions")
            return
        }

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .tool)
        XCTAssertEqual(messages[1].content, "Test passed in 0.4s")
        XCTAssertEqual(messages[2].role, .tool)
        XCTAssertEqual(messages[2].content, "File contents: func test() {}")
    }

    func testWorkspaceURIDecoding() {
        let fileURI = "file:///Users/max/PycharmProjects/Jarvis"
        XCTAssertEqual(AntigravityParser.decodeWorkspaceURI(fileURI), "/Users/max/PycharmProjects/Jarvis")

        let rawPath = "/Users/max/PycharmProjects/Retain"
        XCTAssertEqual(AntigravityParser.decodeWorkspaceURI(rawPath), "/Users/max/PycharmProjects/Retain")
    }

    func testDeterministicIdentity() {
        let data = makeBasicJSONL()
        let convId = "a1b2c3d4-e5f6-7a8b-9c0d-1e2f3a4b5c6d"

        guard let (conv1, msgs1) = AntigravityParser.parseData(data, conversationId: convId),
              let (conv2, msgs2) = AntigravityParser.parseData(data, conversationId: convId) else {
            XCTFail("Should parse deterministic data")
            return
        }

        XCTAssertEqual(conv1.id, conv2.id)
        XCTAssertEqual(conv1.externalId, conv2.externalId)
        XCTAssertEqual(msgs1.count, msgs2.count)

        for i in 0..<msgs1.count {
            XCTAssertEqual(msgs1[i].id, msgs2[i].id)
            XCTAssertEqual(msgs1[i].conversationId, msgs2[i].conversationId)
        }
    }
}
