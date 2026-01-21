import XCTest
@testable import Retain

/// Unit tests for GeminiClient
final class GeminiClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockGeminiURLProtocol.reset()
    }

    override func tearDown() {
        MockGeminiURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Configuration Tests

    func testConfigurationSetsCorrectBaseURL() {
        let config = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        XCTAssertEqual(
            config.baseURL.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models"
        )
    }

    func testConfigurationSetsCorrectTimeout() {
        let config = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        XCTAssertEqual(config.timeout, 30)
    }

    // MARK: - Request Format Tests

    func testSetsCorrectHeaders() async throws {
        let apiKey = "test-api-key-123"
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let config = GeminiClient.Configuration(apiKey: apiKey, model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: config, session: mockSession)

        MockGeminiURLProtocol.requestHandler = { request in
            // Verify headers
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), apiKey)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let data = MockGeminiResponses.learnings([])
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let schema: [String: Any] = ["type": "object", "properties": [:]]
        _ = try? await client.generateStructuredContent(prompt: "test", schema: schema)

        XCTAssertEqual(MockGeminiURLProtocol.recordedRequests.count, 1)
    }

    func testSetsCorrectURLPath() async throws {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let config = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: config, session: mockSession)

        MockGeminiURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("gemini-2.0-flash:generateContent") ?? false)
            let data = MockGeminiResponses.learnings([])
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let schema: [String: Any] = ["type": "object"]
        _ = try? await client.generateStructuredContent(prompt: "test", schema: schema)
    }

    func testRequestBodyContainsPromptAndSchema() async throws {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let config = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: config, session: mockSession)

        let testPrompt = "Extract user preferences"
        let testSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "learnings": ["type": "array"]
            ]
        ]

        MockGeminiURLProtocol.requestHandler = { request in
            guard let bodyData = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                XCTFail("Request body should be valid JSON")
                return MockGeminiResponses.httpResponse(url: request.url!, statusCode: 400)
            }

            // Verify prompt is in the body
            if let contents = body["contents"] as? [[String: Any]],
               let parts = contents.first?["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                XCTAssertEqual(text, testPrompt)
            } else {
                XCTFail("Prompt not found in request body")
            }

            // Verify generation config
            XCTAssertNotNil(body["generationConfig"])

            let data = MockGeminiResponses.learnings([])
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        _ = try? await client.generateStructuredContent(prompt: testPrompt, schema: testSchema)
    }

    // MARK: - Success Response Tests

    func testParsesValidStructuredResponse() async throws {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let config = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: config, session: mockSession)

        let expectedLearnings = [
            (rule: "Use concise responses", type: "positive", confidence: Float(0.9))
        ]

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.learnings(expectedLearnings)
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let schema: [String: Any] = ["type": "object"]
        let result = try await client.generateStructuredContent(prompt: "test", schema: schema)

        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.contains("Use concise responses"))
    }

    func testTrimsWhitespaceFromResponse() async throws {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let config = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: config, session: mockSession)

        // Response with leading/trailing whitespace
        let innerJSON = ["learnings": [[String: Any]]()]
        let innerText = "  " + String(data: try! JSONSerialization.data(withJSONObject: innerJSON), encoding: .utf8)! + "\n\n"

        let response: [String: Any] = [
            "candidates": [
                [
                    "content": [
                        "parts": [
                            ["text": innerText]
                        ]
                    ]
                ]
            ]
        ]
        let responseData = try! JSONSerialization.data(withJSONObject: response)

        MockGeminiURLProtocol.requestHandler = { request in
            return MockGeminiResponses.successResponse(url: request.url!, data: responseData)
        }

        let schema: [String: Any] = ["type": "object"]
        let result = try await client.generateStructuredContent(prompt: "test", schema: schema)

        // Should be trimmed - no leading/trailing whitespace
        XCTAssertFalse(result.hasPrefix(" "))
        XCTAssertFalse(result.hasSuffix("\n"))
    }

    // MARK: - Error Response Tests

    func testThrows401Unauthorized() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let config = GeminiClient.Configuration(apiKey: "invalid-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: config, session: mockSession)

        MockGeminiURLProtocol.requestHandler = { request in
            let errorBody = MockGeminiResponses.errorBody(message: "Invalid API key")
            return MockGeminiResponses.httpResponse(url: request.url!, statusCode: 401, body: errorBody)
        }

        let schema: [String: Any] = ["type": "object"]
        do {
            _ = try await client.generateStructuredContent(prompt: "test", schema: schema)
            XCTFail("Should throw error for 401 response")
        } catch let error as GeminiClient.GeminiError {
            if case .httpError(let code, _) = error {
                XCTAssertEqual(code, 401)
            } else {
                XCTFail("Expected httpError")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testThrows429RateLimited() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let config = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: config, session: mockSession)

        MockGeminiURLProtocol.requestHandler = { request in
            let errorBody = MockGeminiResponses.errorBody(message: "Rate limit exceeded")
            return MockGeminiResponses.httpResponse(url: request.url!, statusCode: 429, body: errorBody)
        }

        let schema: [String: Any] = ["type": "object"]
        do {
            _ = try await client.generateStructuredContent(prompt: "test", schema: schema)
            XCTFail("Should throw error for 429 response")
        } catch let error as GeminiClient.GeminiError {
            if case .httpError(let code, _) = error {
                XCTAssertEqual(code, 429)
            } else {
                XCTFail("Expected httpError")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testThrows500ServerError() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let config = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: config, session: mockSession)

        MockGeminiURLProtocol.requestHandler = { request in
            let errorBody = MockGeminiResponses.errorBody(message: "Internal server error")
            return MockGeminiResponses.httpResponse(url: request.url!, statusCode: 500, body: errorBody)
        }

        let schema: [String: Any] = ["type": "object"]
        do {
            _ = try await client.generateStructuredContent(prompt: "test", schema: schema)
            XCTFail("Should throw error for 500 response")
        } catch let error as GeminiClient.GeminiError {
            if case .httpError(let code, _) = error {
                XCTAssertEqual(code, 500)
            } else {
                XCTFail("Expected httpError")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testThrowsEmptyResponseError() async {
        let mockSession = MockGeminiURLProtocol.makeMockSession()
        let config = GeminiClient.Configuration(apiKey: "test-key", model: "gemini-2.0-flash")
        let client = GeminiClient(configuration: config, session: mockSession)

        MockGeminiURLProtocol.requestHandler = { request in
            let data = MockGeminiResponses.emptyResponse()
            return MockGeminiResponses.successResponse(url: request.url!, data: data)
        }

        let schema: [String: Any] = ["type": "object"]
        do {
            _ = try await client.generateStructuredContent(prompt: "test", schema: schema)
            XCTFail("Should throw error for empty response")
        } catch let error as GeminiClient.GeminiError {
            if case .emptyResponse = error {
                // Expected
            } else {
                XCTFail("Expected emptyResponse error")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Error Description Tests

    func testInvalidResponseErrorDescription() {
        let error = GeminiClient.GeminiError.invalidResponse
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Invalid") ?? false)
    }

    func testHttpErrorDescription() {
        let error = GeminiClient.GeminiError.httpError(429, "Rate limited")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("429") ?? false)
    }

    func testEmptyResponseErrorDescription() {
        let error = GeminiClient.GeminiError.emptyResponse
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.lowercased().contains("empty") ?? false)
    }
}
