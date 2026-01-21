import Foundation

/// Mock URL protocol for intercepting Gemini API requests in tests
final class MockGeminiURLProtocol: URLProtocol {
    /// Handler type for processing requests
    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    /// Default handler for all requests
    static var requestHandler: RequestHandler?

    /// Recorded requests for verification
    static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        // Capture body data from stream if needed (httpBody may be nil in URLProtocol)
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
            capturedRequest.httpBody = readData(from: stream)
        }
        MockGeminiURLProtocol.recordedRequests.append(capturedRequest)

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            guard let handler = MockGeminiURLProtocol.requestHandler else {
                // Return 404 for unhandled requests
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            let (response, data) = try handler(capturedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // Nothing to clean up
    }

    /// Read data from an input stream
    private func readData(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            }
        }
        return data
    }

    // MARK: - Test Helpers

    /// Reset handler and recorded requests
    static func reset() {
        requestHandler = nil
        recordedRequests.removeAll()
    }

    /// Create a mock URLSession configured with this protocol
    static func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockGeminiURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Mock Gemini API Responses

enum MockGeminiResponses {
    /// Create a successful learning extraction response
    static func learnings(_ items: [(rule: String, type: String, confidence: Float)]) -> Data {
        let learnings = items.map { item in
            [
                "rule": item.rule,
                "type": item.type,
                "confidence": item.confidence,
                "evidence": "Test evidence"
            ] as [String: Any]
        }

        let innerJSON = ["learnings": learnings]
        let innerText = String(data: try! JSONSerialization.data(withJSONObject: innerJSON), encoding: .utf8)!

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

        return try! JSONSerialization.data(withJSONObject: response)
    }

    /// Create a successful workflow signature response
    static func workflow(
        action: String,
        artifact: String,
        domains: [String],
        isPriming: Bool = false,
        isAutomationCandidate: Bool = true
    ) -> Data {
        let innerJSON: [String: Any] = [
            "action": action,
            "artifact": artifact,
            "domains": domains,
            "isPriming": isPriming,
            "isAutomationCandidate": isAutomationCandidate,
            "reason": "Test reason"
        ]
        let innerText = String(data: try! JSONSerialization.data(withJSONObject: innerJSON), encoding: .utf8)!

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

        return try! JSONSerialization.data(withJSONObject: response)
    }

    /// Create an empty learnings response
    static func emptyLearnings() -> Data {
        let innerJSON = ["learnings": [Any]()]
        let innerText = String(data: try! JSONSerialization.data(withJSONObject: innerJSON), encoding: .utf8)!

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

        return try! JSONSerialization.data(withJSONObject: response)
    }

    /// Create an empty response (no candidates)
    static func emptyResponse() -> Data {
        let response: [String: Any] = ["candidates": [Any]()]
        return try! JSONSerialization.data(withJSONObject: response)
    }

    /// Create an HTTP response with given status code
    static func httpResponse(url: URL, statusCode: Int, body: Data = Data()) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body)
    }

    /// Create a 200 OK response with the given data
    static func successResponse(url: URL, data: Data) -> (HTTPURLResponse, Data) {
        return httpResponse(url: url, statusCode: 200, body: data)
    }

    /// Create error response body
    static func errorBody(message: String) -> Data {
        let error: [String: Any] = [
            "error": [
                "code": 400,
                "message": message,
                "status": "INVALID_ARGUMENT"
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: error)
    }
}
