import Foundation

/// Mock URL protocol for intercepting network requests in tests
final class MockURLProtocol: URLProtocol {
    /// Handler type for processing requests
    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    /// Registered handlers for specific URLs
    static var handlers: [String: RequestHandler] = [:]

    /// Default response for unhandled requests
    static var defaultHandler: RequestHandler?

    /// Recorded requests for verification
    static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        MockURLProtocol.recordedRequests.append(request)

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let handler = MockURLProtocol.handlers[url.absoluteString] ?? MockURLProtocol.defaultHandler

            guard let handler = handler else {
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

            let (response, data) = try handler(request)
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

    // MARK: - Test Helpers

    /// Reset all handlers and recorded requests
    static func reset() {
        handlers.removeAll()
        defaultHandler = nil
        recordedRequests.removeAll()
    }

    /// Register a handler for a specific URL
    static func register(url: String, handler: @escaping RequestHandler) {
        handlers[url] = handler
    }

    /// Register a JSON response for a specific URL
    static func registerJSON(url: String, statusCode: Int = 200, json: Any) {
        handlers[url] = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = try JSONSerialization.data(withJSONObject: json)
            return (response, data)
        }
    }

    /// Register an error response for a specific URL
    static func registerError(url: String, statusCode: Int) {
        handlers[url] = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
    }
}

// MARK: - Mock API Responses

/// Factory for creating mock API responses
enum MockAPIResponses {

    // MARK: - Claude.ai Responses

    static func claudeOrganizations(orgId: String = "org-123", name: String = "Test Org") -> [[String: Any]] {
        return [
            [
                "uuid": orgId,
                "name": name,
                "settings": [
                    "claude_console_privacy": "internal"
                ]
            ]
        ]
    }

    static func claudeConversationList(conversations: [(id: String, title: String, created: String, updated: String)]) -> [[String: Any]] {
        return conversations.map { conv in
            [
                "uuid": conv.id,
                "name": conv.title,
                "created_at": conv.created,
                "updated_at": conv.updated,
                "is_starred": false
            ]
        }
    }

    static func claudeConversation(
        id: String,
        title: String,
        messages: [(uuid: String, text: String, sender: String, created: String)]
    ) -> [String: Any] {
        return [
            "uuid": id,
            "name": title,
            "created_at": "2024-01-01T00:00:00.000Z",
            "updated_at": "2024-01-01T01:00:00.000Z",
            "chat_messages": messages.enumerated().map { (index, msg) in
                [
                    "uuid": msg.uuid,
                    "text": msg.text,
                    "sender": msg.sender,
                    "created_at": msg.created,
                    "updated_at": msg.created,
                    "index": index
                ]
            }
        ]
    }

    // MARK: - ChatGPT Responses

    static func chatgptSession(userId: String = "user-123", email: String = "test@example.com") -> [String: Any] {
        return [
            "user": [
                "id": userId,
                "name": "Test User",
                "email": email,
                "image": NSNull()
            ],
            "accessToken": "test-access-token"
        ]
    }

    static func chatgptConversationList(
        conversations: [(id: String, title: String, createTime: TimeInterval, updateTime: TimeInterval)],
        total: Int? = nil,
        offset: Int = 0
    ) -> [String: Any] {
        return [
            "items": conversations.map { conv in
                [
                    "id": conv.id,
                    "title": conv.title,
                    "create_time": conv.createTime,
                    "update_time": conv.updateTime
                ]
            },
            "total": total ?? conversations.count,
            "limit": 20,
            "offset": offset,
            "has_missing_conversations": false
        ]
    }

    static func chatgptConversation(
        title: String,
        messages: [(id: String, role: String, text: String, createTime: TimeInterval)]
    ) -> [String: Any] {
        var mapping: [String: Any] = [:]
        var previousId: String? = nil

        for (index, msg) in messages.enumerated() {
            let nodeId = "node-\(index)"
            var nodeDict: [String: Any] = [
                "id": nodeId,
                "message": [
                    "id": msg.id,
                    "author": [
                        "role": msg.role,
                        "metadata": [String: Any]()
                    ] as [String: Any],
                    "content": [
                        "content_type": "text",
                        "parts": [msg.text]
                    ],
                    "create_time": msg.createTime,
                    "update_time": msg.createTime,
                    "status": "finished_successfully",
                    "metadata": [
                        "model_slug": "gpt-4"
                    ]
                ],
                "children": index < messages.count - 1 ? ["node-\(index + 1)"] : []
            ]
            if let parent = previousId {
                nodeDict["parent"] = parent
            }
            mapping[nodeId] = nodeDict
            previousId = nodeId
        }

        return [
            "title": title,
            "create_time": messages.first?.createTime ?? Date().timeIntervalSince1970,
            "update_time": messages.last?.createTime ?? Date().timeIntervalSince1970,
            "mapping": mapping,
            "current_node": "node-\(messages.count - 1)"
        ]
    }
}
