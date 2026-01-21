import Foundation

/// Claude.ai web API sync implementation
/// API endpoints discovered from unofficial-claude-api project
final class ClaudeWebSync {
    private let baseURL = "https://claude.ai"
    private let sessionStorage: SessionStorage
    private var cachedOrganizationId: String?

    // MARK: - API Response Types

    struct OrganizationsResponse: Decodable {
        let uuid: String
        let name: String?
        let settings: Settings?

        struct Settings: Decodable {
            let claude_console_privacy: String?
        }
    }

    struct ConversationsResponse: Decodable {
        let uuid: String
        let name: String?
        let created_at: String
        let updated_at: String
        let is_starred: Bool?
    }

    struct ConversationDetailResponse: Decodable {
        let uuid: String
        let name: String?
        let created_at: String
        let updated_at: String
        let chat_messages: [ChatMessage]

        struct ChatMessage: Codable {
            let uuid: String
            let text: String
            let sender: String // "human" or "assistant"
            let created_at: String
            let updated_at: String?
            let index: Int?
            let content: ContentType?

            enum ContentType: Codable {
                case string(String)
                case array([ContentBlock])

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let string = try? container.decode(String.self) {
                        self = .string(string)
                    } else if let array = try? container.decode([ContentBlock].self) {
                        self = .array(array)
                    } else {
                        self = .string("")
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    switch self {
                    case .string(let string):
                        try container.encode(string)
                    case .array(let blocks):
                        try container.encode(blocks)
                    }
                }

                var text: String {
                    switch self {
                    case .string(let s): return s
                    case .array(let blocks):
                        return blocks.compactMap { $0.textValue }.joined(separator: "\n\n")
                    }
                }
            }

            struct ContentBlock: Codable {
                let type: String?
                let text: String?
                let title: String?
                let name: String?
                let url: String?
                let language: String?
                let content: ContentType?

                var textValue: String? {
                    if !shouldIncludeText {
                        return nil
                    }
                    if let text, !text.isEmpty { return text }
                    if let contentText = content?.text, !contentText.isEmpty { return contentText }
                    if let title, !title.isEmpty { return title }
                    if let name, !name.isEmpty { return name }
                    return nil
                }

                private var shouldIncludeText: Bool {
                    guard let type else { return true }
                    let normalized = type.lowercased()
                    return normalized != "thinking" && normalized != "analysis"
                }
            }
        }
    }

    struct UserInfoResponse: Decodable {
        let uuid: String
        let email_address: String?
        let full_name: String?
    }

    // MARK: - Init

    init(sessionStorage: SessionStorage) {
        self.sessionStorage = sessionStorage
    }

    // MARK: - Session Validation

    /// Validate current session and return user info
    func validateSession() async throws -> WebUserInfo {
        // First get organizations to verify auth
        let orgs = try await fetchOrganizations()
        guard let org = orgs.first else {
            throw WebSyncEngine.WebSyncError.notAuthenticated
        }
        cachedOrganizationId = org.uuid

        return WebUserInfo(
            email: nil, // Claude.ai doesn't expose email in org endpoint
            name: org.name,
            organizationId: org.uuid
        )
    }

    // MARK: - API Calls

    /// Fetch user's organizations
    private func fetchOrganizations() async throws -> [OrganizationsResponse] {
        let url = URL(string: "\(baseURL)/api/organizations")!
        let data = try await performRequest(url: url)
        return try JSONDecoder().decode([OrganizationsResponse].self, from: data)
    }

    /// Fetch conversation list
    func fetchConversationList(since: Date? = nil) async throws -> [ConversationMeta] {
        let orgId = try await organizationId()
        let url = URL(string: "\(baseURL)/api/organizations/\(orgId)/chat_conversations")!
        let data = try await performRequest(url: url)
        let conversations = try JSONDecoder().decode([ConversationsResponse].self, from: data)

        return conversations.compactMap { conv -> ConversationMeta? in
            guard let createdAt = parseDate(conv.created_at),
                  let updatedAt = parseDate(conv.updated_at) else {
                return nil
            }

            // Filter by last sync date if provided
            if let since = since, updatedAt < since {
                return nil
            }

            return ConversationMeta(
                id: conv.uuid,
                title: conv.name,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    /// Fetch full conversation with messages
    func fetchConversation(id: String) async throws -> (Conversation, [Message]) {
        let orgId = try await organizationId()
        let url = URL(string: "\(baseURL)/api/organizations/\(orgId)/chat_conversations/\(id)")!
        let data = try await performRequest(url: url)
        let detail = try JSONDecoder().decode(ConversationDetailResponse.self, from: data)
        let rawMessagePayloads = extractRawMessages(from: data)

        // Convert to our models
        let conversationId = UUID()
        let createdAt = parseDate(detail.created_at) ?? Date()
        let updatedAt = parseDate(detail.updated_at) ?? Date()

        var messages: [Message] = []

        for chatMessage in detail.chat_messages {
            let role: Role = chatMessage.sender == "human" ? .user : .assistant
            let timestamp = parseDate(chatMessage.created_at) ?? Date()

            let content = extractMessageContent(from: chatMessage)
            guard !content.isEmpty else { continue }

            let rawPayload = rawMessagePayloads[chatMessage.uuid] ?? encodeMessageMetadata(chatMessage)

            let message = Message(
                id: UUID(),
                conversationId: conversationId,
                externalId: chatMessage.uuid,
                role: role,
                content: content,
                timestamp: timestamp,
                rawPayload: rawPayload
            )
            messages.append(message)
        }

        // Sort messages by timestamp
        messages.sort { $0.timestamp < $1.timestamp }

        let conversation = Conversation(
            id: conversationId,
            provider: .claudeWeb,
            sourceType: .web,
            externalId: detail.uuid,
            title: normalizedTitle(detail.name) ?? extractTitle(from: messages.first?.content),
            previewText: extractPreview(from: messages),
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messages.count,
            rawPayload: data
        )

        return (conversation, messages)
    }

    // MARK: - Helpers

    private func encodeMessageMetadata(_ chatMessage: ConversationDetailResponse.ChatMessage) -> Data? {
        try? JSONEncoder().encode(chatMessage)
    }

    private func organizationId() async throws -> String {
        if let cached = cachedOrganizationId {
            return cached
        }
        let orgs = try await fetchOrganizations()
        guard let org = orgs.first else {
            throw WebSyncEngine.WebSyncError.notAuthenticated
        }
        cachedOrganizationId = org.uuid
        return org.uuid
    }

    private func extractRawMessages(from data: Data) -> [String: Data] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = object["chat_messages"] as? [[String: Any]] else {
            return [:]
        }

        var payloads: [String: Data] = [:]
        for message in messages {
            guard let uuid = message["uuid"] as? String else { continue }
            if let payload = try? JSONSerialization.data(withJSONObject: message, options: []) {
                payloads[uuid] = payload
            }
        }

        return payloads
    }

    private func performRequest(url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        // Set headers
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        // Add cookies from session
        let cookies = sessionStorage.getCookies(for: .claudeWeb)
        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSyncEngine.WebSyncError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            cachedOrganizationId = nil
            throw WebSyncEngine.WebSyncError.sessionExpired
        case 429:
            throw WebSyncEngine.WebSyncError.rateLimited(retryAfter: parseRetryAfter(httpResponse))
        default:
            throw WebSyncEngine.WebSyncError.networkError(
                URLError(.init(rawValue: httpResponse.statusCode))
            )
        }
    }

    private func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        if let date = formatter.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: string) {
            return date
        }

        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func extractTitle(from content: String?) -> String? {
        guard let content = content else { return nil }
        let firstLine = content.components(separatedBy: .newlines).first ?? content
        if firstLine.count <= 80 {
            return firstLine
        }
        return String(firstLine.prefix(80)) + "..."
    }

    private func extractPreview(from messages: [Message]) -> String? {
        if let userMessage = messages.first(where: { $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return formatPreview(userMessage.content)
        }
        if let firstMessage = messages.first(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return formatPreview(firstMessage.content)
        }
        return nil
    }

    private func formatPreview(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 120)
        return String(trimmed[..<index]) + "..."
    }

    private func normalizedTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func extractMessageContent(from chatMessage: ConversationDetailResponse.ChatMessage) -> String {
        let rawText = chatMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentText = chatMessage.content?.text ?? ""
        let trimmedContent = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContent.isEmpty {
            return trimmedContent
        }

        if !rawText.isEmpty && !isUnsupportedBlockPlaceholder(rawText) {
            return rawText
        }

        return "[Unsupported content]"
    }

    private func isUnsupportedBlockPlaceholder(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized == "this block is not supported on your current device yet."
    }
}
