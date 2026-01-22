import Foundation

/// ChatGPT web API sync implementation
/// API endpoints discovered from chatgpt-exporter project
final class ChatGPTWebSync {
    private let baseURL = "https://chatgpt.com"
    private let sessionStorage: SessionStorage
    private var accessToken: String?
    private static let annotationRegex = try? NSRegularExpression(
        pattern: "\\u{E200}(.*?)\\u{E202}(.*?)\\u{E201}",
        options: [.dotMatchesLineSeparators]
    )

    #if DEBUG
    private func debugLog(_ message: String) {
        print("🟢 ChatGPTWebSync:", message)
    }
    #endif

    // MARK: - API Response Types

    struct SessionResponse: Decodable {
        let user: User?
        let accessToken: String?

        struct User: Decodable {
            let id: String
            let name: String?
            let email: String?
            let image: String?
        }
    }

    struct ConversationsListResponse: Decodable {
        let items: [ConversationItem]
        let total: Int
        let limit: Int
        let offset: Int
        let has_missing_conversations: Bool?

        struct ConversationItem: Decodable {
            let id: String?
            let title: String?
            let create_time: TimeInterval?
            let update_time: TimeInterval?
            let mapping: String? // Not included in list, only in detail

            private enum CodingKeys: String, CodingKey {
                case id
                case conversation_id
                case uuid
                case title
                case create_time
                case update_time
                case created_at
                case updated_at
                case created_time
                case updated_time
                case mapping
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = Self.decodeString(container, keys: [.id, .conversation_id, .uuid])
                title = try container.decodeIfPresent(String.self, forKey: .title)
                create_time = Self.decodeTimeInterval(container, keys: [.create_time, .created_time, .created_at])
                update_time = Self.decodeTimeInterval(container, keys: [.update_time, .updated_time, .updated_at])
                mapping = try container.decodeIfPresent(String.self, forKey: .mapping)
            }

            private static func decodeTimeInterval(
                _ container: KeyedDecodingContainer<CodingKeys>,
                keys: [CodingKeys]
            ) -> TimeInterval? {
                for key in keys {
                    if let value = try? container.decodeIfPresent(TimeInterval.self, forKey: key) {
                        return normalizeEpoch(value)
                    }
                    if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                        return normalizeEpoch(value)
                    }
                    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                        return normalizeEpoch(TimeInterval(value))
                    }
                    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                        if let parsed = TimeInterval(value) {
                            return normalizeEpoch(parsed)
                        }
                        if let parsedDate = parseISODate(value) {
                            return parsedDate.timeIntervalSince1970
                        }
                    }
                }
                return nil
            }

            private static func decodeString(
                _ container: KeyedDecodingContainer<CodingKeys>,
                keys: [CodingKeys]
            ) -> String? {
                for key in keys {
                    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                        return value
                    }
                    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                        return String(value)
                    }
                }
                return nil
            }

            private static func normalizeEpoch(_ value: TimeInterval) -> TimeInterval {
                if value > 10_000_000_000 {
                    return value / 1000.0
                }
                return value
            }

            private static func parseISODate(_ value: String) -> Date? {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: value) {
                    return date
                }
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: value)
            }
        }
    }

    struct ConversationDetailResponse: Decodable {
        let title: String?
        let create_time: TimeInterval
        let update_time: TimeInterval
        let mapping: [String: MappingNode]
        let current_node: String?

        struct MappingNode: Decodable {
            let id: String
            let message: MessageContent?
            let parent: String?
            let children: [String]?

            struct MessageContent: Codable {
                let id: String?
                let author: Author
                let content: Content
                let create_time: TimeInterval?
                let update_time: TimeInterval?
                let status: String?
                let metadata: Metadata?

                struct Author: Codable {
                    let role: String // "user", "assistant", "system", "tool"
                    let name: String?
                    let metadata: AuthorMetadata?

                    struct AuthorMetadata: Codable {
                        // Various metadata fields
                    }
                }

                struct Content: Codable {
                    let content_type: String
                    let parts: [StringOrArray]?
                    let text: String?

                    enum StringOrArray: Codable {
                        case string(String)
                        case object([String: AnyCodable])

                        init(from decoder: Decoder) throws {
                            let container = try decoder.singleValueContainer()
                            if let string = try? container.decode(String.self) {
                                self = .string(string)
                            } else if let obj = try? container.decode([String: AnyCodable].self) {
                                self = .object(obj)
                            } else {
                                self = .string("")
                            }
                        }

                        func encode(to encoder: Encoder) throws {
                            var container = encoder.singleValueContainer()
                            switch self {
                            case .string(let string):
                                try container.encode(string)
                            case .object(let object):
                                try container.encode(object)
                            }
                        }

                        var text: String? {
                            switch self {
                            case .string(let s): return s
                            case .object: return nil
                            }
                        }
                    }
                }

                struct Metadata: Codable {
                    let model_slug: String?
                    let finish_details: FinishDetails?

                    struct FinishDetails: Codable {
                        let type: String?
                    }
                }
            }
        }
    }

    // Generic codable wrapper
    struct AnyCodable: Codable {
        let value: Any

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = NSNull()
            } else if let string = try? container.decode(String.self) {
                value = string
            } else if let int = try? container.decode(Int.self) {
                value = int
            } else if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let double = try? container.decode(Double.self) {
                value = double
            } else if let array = try? container.decode([AnyCodable].self) {
                value = array
            } else if let dict = try? container.decode([String: AnyCodable].self) {
                value = dict
            } else {
                value = NSNull()
            }
        }

        init(_ value: Any) {
            self.value = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch value {
            case is NSNull:
                try container.encodeNil()
            case let string as String:
                try container.encode(string)
            case let int as Int:
                try container.encode(int)
            case let bool as Bool:
                try container.encode(bool)
            case let double as Double:
                try container.encode(double)
            case let array as [AnyCodable]:
                try container.encode(array)
            case let array as [Any]:
                try container.encode(array.map(AnyCodable.init))
            case let dict as [String: AnyCodable]:
                try container.encode(dict)
            case let dict as [String: Any]:
                try container.encode(dict.mapValues(AnyCodable.init))
            default:
                try container.encode(String(describing: value))
            }
        }
    }

    // MARK: - Init

    private var hasLoadedFromKeychain = false

    init(sessionStorage: SessionStorage) {
        self.sessionStorage = sessionStorage
        // NOTE: Keychain access deferred to first use via loadAccessTokenFromKeychain()
        // to avoid prompting during onboarding
    }

    /// Load access token from keychain (deferred from init to avoid onboarding prompt)
    private func loadAccessTokenFromKeychain() {
        guard !hasLoadedFromKeychain else { return }
        hasLoadedFromKeychain = true
        accessToken = KeychainHelper.chatgptAccessToken
    }

    /// Clear cached access token (e.g., after session expiry)
    func clearAccessToken() {
        accessToken = nil
        KeychainHelper.chatgptAccessToken = nil
    }

    // MARK: - Session Validation

    /// Validate current session and return user info
    func validateSession() async throws -> WebUserInfo {
        let session = try await fetchSession()
        accessToken = session.accessToken
        // Persist access token to Keychain for restart survival
        KeychainHelper.chatgptAccessToken = session.accessToken
        #if DEBUG
        // Redact email in logs for privacy
        let redactedEmail = session.user?.email.map { email in
            email.count > 4 ? "\(email.prefix(2))***\(email.suffix(2))" : "***"
        } ?? "nil"
        debugLog("validateSession: accessToken=\(accessToken?.isEmpty == false ? "yes" : "no") user=\(redactedEmail)")
        #endif
        guard let user = session.user else {
            throw WebSyncEngine.WebSyncError.notAuthenticated
        }

        return WebUserInfo(
            email: user.email,
            name: user.name,
            organizationId: user.id
        )
    }

    // MARK: - API Calls

    /// Fetch session info
    private func fetchSession() async throws -> SessionResponse {
        let url = URL(string: "\(baseURL)/api/auth/session")!
        let data = try await performRequest(url: url, allowTokenRefresh: false)
        return try JSONDecoder().decode(SessionResponse.self, from: data)
    }

    struct ConversationListPage {
        let metas: [ConversationMeta]
        let oldestUpdatedAt: Date?
    }

    /// Fetch conversation list with pagination
    func fetchConversationList(offset: Int = 0, limit: Int = 20) async throws -> ConversationListPage {
        let url = URL(string: "\(baseURL)/backend-api/conversations?offset=\(offset)&limit=\(limit)&order=updated")!
        let token = try await accessTokenValue()
        let data = try await performRequest(url: url, accessToken: token)
        #if DEBUG
        if offset == 0 {
            writeDebugPayload(data, label: "chatgpt-list")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = json["items"] as? [[String: Any]],
           let first = items.first {
            let itemKeys = first.keys.sorted().joined(separator: ",")
            debugLog("list first item keys: \(itemKeys)")
            if let id = first["id"] ?? first["conversation_id"] ?? first["uuid"] {
                debugLog("list first item id: \(id)")
            }
            if let create = first["create_time"] ?? first["created_at"] ?? first["created_time"] {
                debugLog("list first item create_time: \(create)")
            }
            if let update = first["update_time"] ?? first["updated_at"] ?? first["updated_time"] {
                debugLog("list first item update_time: \(update)")
            }
        }
        #endif
        let response: ConversationsListResponse
        do {
            response = try JSONDecoder().decode(ConversationsListResponse.self, from: data)
        } catch {
            #if DEBUG
            debugLog("list decode failed: \(error.localizedDescription) bytes=\(data.count)")
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let keys = json.keys.sorted().joined(separator: ",")
                debugLog("list response keys: \(keys)")
                if let items = json["items"] as? [[String: Any]], let first = items.first {
                    let itemKeys = first.keys.sorted().joined(separator: ",")
                    debugLog("list first item keys: \(itemKeys)")
                }
            }
            writeDebugPayload(data, label: "chatgpt-list")
            #endif
            throw error
        }
        #if DEBUG
        debugLog("list: offset=\(offset) limit=\(limit) items=\(response.items.count) total=\(response.total)")
        #endif

        var metas: [ConversationMeta] = []
        var oldestUpdatedAt: Date? = nil

        for item in response.items {
            guard let id = item.id,
                  let createTime = item.create_time ?? item.update_time else {
                continue
            }
            let updateTime = item.update_time ?? createTime
            let createdAt = Date(timeIntervalSince1970: createTime)
            let updatedAt = Date(timeIntervalSince1970: updateTime)
            metas.append(ConversationMeta(
                id: id,
                title: item.title,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))

            if oldestUpdatedAt == nil || updatedAt < oldestUpdatedAt! {
                oldestUpdatedAt = updatedAt
            }
        }
        return ConversationListPage(metas: metas, oldestUpdatedAt: oldestUpdatedAt)
    }

    /// Fetch full conversation with messages
    func fetchConversation(id: String) async throws -> (Conversation, [Message]) {
        let url = URL(string: "\(baseURL)/backend-api/conversation/\(id)")!
        let token = try await accessTokenValue()
        let data = try await performRequest(url: url, accessToken: token)
        let detail: ConversationDetailResponse
        do {
            detail = try JSONDecoder().decode(ConversationDetailResponse.self, from: data)
        } catch {
            #if DEBUG
            debugLog("conversation decode failed: \(error.localizedDescription) bytes=\(data.count)")
            writeDebugPayload(data, label: "chatgpt-conversation")
            #endif
            throw error
        }
        #if DEBUG
        debugLog("conversation: id=\(id) mapping=\(detail.mapping.count) current=\(detail.current_node ?? "nil")")
        #endif

        // Convert mapping tree to flat message list
        let conversationId = UUID()
        var messages: [Message] = []

        // Traverse the conversation tree to get messages in order
        let orderedMessages = traverseMapping(detail.mapping, currentNode: detail.current_node)

        for msg in orderedMessages {
            let text = extractText(from: msg.content) ?? extractFallbackText(from: msg.content)
            guard var displayText = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !displayText.isEmpty else {
                continue
            }
            displayText = sanitizeChatGPTText(displayText)
            guard !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let role: Role
            switch msg.author.role {
            case "user": role = .user
            case "assistant": role = .assistant
            case "system": role = .system
            default: role = .tool
            }

            let timestamp = msg.create_time.map { Date(timeIntervalSince1970: $0) } ?? Date()

            let message = Message(
                id: UUID(),
                conversationId: conversationId,
                externalId: msg.id,
                role: role,
                content: displayText,
                timestamp: timestamp,
                model: msg.metadata?.model_slug,
                rawPayload: encodeMessageMetadata(msg)
            )
            messages.append(message)
        }

        let createdAt = Date(timeIntervalSince1970: detail.create_time)
        let updatedAt = Date(timeIntervalSince1970: detail.update_time)

        let conversation = Conversation(
            id: conversationId,
            provider: .chatgptWeb,
            sourceType: .web,
            externalId: id,
            title: normalizedTitle(detail.title) ?? extractTitle(from: messages.first?.content),
            previewText: extractPreview(from: messages),
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: messages.count,
            rawPayload: data
        )

        return (conversation, messages)
    }

    // MARK: - Helpers

    private func performRequest(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        accessToken: String? = nil,
        allowTokenRefresh: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        // Set headers
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        // Add cookies from session - only essential auth cookies to avoid 431 error.
        // Keep to the minimum needed for auth + workspace selection.
        let cookies = sessionStorage.getCookies(for: .chatgptWeb)
        let essentialCookies = cookies.filter { cookie in
            let name = cookie.name.lowercased()
            return name.contains("session-token")
                || name.contains("csrf-token")
                || name == "__cf_bm"  // Cloudflare bot management
                || name == "cf_clearance"  // Cloudflare clearance
                || name == "_account"  // Workspace/account selection cookie
                || name == "oai-did"  // Device identifier (paired with header)
        }
        let cookieHeader = essentialCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let accountId = cookieValue(in: cookies, name: "_account") {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        if let deviceId = cookieValue(in: cookies, name: "oai-did") {
            request.setValue(deviceId, forHTTPHeaderField: "oai-device-id")
        }
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSyncEngine.WebSyncError.networkError(URLError(.badServerResponse))
        }
        #if DEBUG
        let path = url.path + (url.query.map { "?\($0)" } ?? "")
        debugLog("request: \(method) \(path) status=\(httpResponse.statusCode)")
        #endif

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401, 403:
            if allowTokenRefresh, let accessToken, !accessToken.isEmpty {
                // Clear cached token and try to refresh session once.
                self.accessToken = nil
                KeychainHelper.chatgptAccessToken = nil
                let session = try await fetchSession()
                self.accessToken = session.accessToken
                KeychainHelper.chatgptAccessToken = session.accessToken
                return try await performRequest(
                    url: url,
                    method: method,
                    body: body,
                    accessToken: session.accessToken,
                    allowTokenRefresh: false
                )
            }
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

    private func cookieValue(in cookies: [HTTPCookie], name: String) -> String? {
        let target = name.lowercased()
        return cookies.first { $0.name.lowercased() == target }?.value
    }

    /// Traverse the mapping tree following only the active branch from current_node to root.
    /// Discards alternative/rejected branches for cleaner learning extraction.
    private func traverseMapping(_ mapping: [String: ConversationDetailResponse.MappingNode], currentNode: String?) -> [ConversationDetailResponse.MappingNode.MessageContent] {
        guard let current = currentNode else {
            // Fallback: if no current_node, traverse from root
            return traverseFromRoot(mapping)
        }

        // Walk backwards from current_node to root, building the active path
        var path: [ConversationDetailResponse.MappingNode.MessageContent] = []
        var nodeId: String? = current

        while let id = nodeId, let node = mapping[id] {
            if let message = node.message {
                path.insert(message, at: 0)  // Insert at beginning to maintain chronological order
            }
            nodeId = node.parent
        }

        return path
    }

    /// Fallback traversal when current_node is nil - BFS from root nodes
    private func traverseFromRoot(_ mapping: [String: ConversationDetailResponse.MappingNode]) -> [ConversationDetailResponse.MappingNode.MessageContent] {
        var messages: [ConversationDetailResponse.MappingNode.MessageContent] = []

        // Find root nodes (nodes with no parent or parent not in mapping)
        let rootNodes = mapping.values.filter { node in
            node.parent == nil || mapping[node.parent!] == nil
        }

        // BFS traversal
        var visited = Set<String>()
        var queue: [String] = rootNodes.map { $0.id }

        while !queue.isEmpty {
            let nodeId = queue.removeFirst()
            guard !visited.contains(nodeId),
                  let node = mapping[nodeId] else {
                continue
            }

            visited.insert(nodeId)

            if let message = node.message {
                messages.append(message)
            }

            if let children = node.children {
                queue.append(contentsOf: children)
            }
        }

        // Sort by create_time
        messages.sort { ($0.create_time ?? 0) < ($1.create_time ?? 0) }

        return messages
    }

    /// Extract text content from message
    private func extractText(from content: ConversationDetailResponse.MappingNode.MessageContent.Content) -> String? {
        if let text = content.text {
            return text
        }

        if let parts = content.parts {
            let texts = parts.compactMap { $0.text }
            if !texts.isEmpty {
                return texts.joined(separator: "\n\n")
            }
        }

        return nil
    }

    private func extractFallbackText(from content: ConversationDetailResponse.MappingNode.MessageContent.Content) -> String? {
        if content.text == nil && (content.parts?.isEmpty ?? true) {
            return nil
        }

        let typeLabel = content.content_type
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if typeLabel.isEmpty {
            return "[Non-text content]"
        }

        return "[\(typeLabel.capitalized)]"
    }

    private func encodeMessageMetadata(
        _ message: ConversationDetailResponse.MappingNode.MessageContent
    ) -> Data? {
        try? JSONEncoder().encode(message)
    }

    private func extractTitle(from content: String?) -> String? {
        guard let content = content else { return nil }
        let firstLine = content.components(separatedBy: .newlines).first ?? content
        if firstLine.count <= 80 {
            return firstLine
        }
        return String(firstLine.prefix(80)) + "..."
    }

    private func normalizedTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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

    private func sanitizeChatGPTText(_ text: String) -> String {
        guard let regex = Self.annotationRegex else { return text }
        let nsText = text as NSString
        var result = ""
        var lastIndex = 0

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let range = match.range(at: 0)
            if range.location > lastIndex {
                let chunk = nsText.substring(with: NSRange(location: lastIndex, length: range.location - lastIndex))
                result.append(chunk)
            }

            let type = nsText.substring(with: match.range(at: 1)).lowercased()
            let payload = nsText.substring(with: match.range(at: 2))
            if let replacement = chatgptAnnotationReplacement(type: type, payload: payload) {
                result.append(replacement)
            }

            lastIndex = range.location + range.length
        }

        if lastIndex < nsText.length {
            result.append(nsText.substring(from: lastIndex))
        }

        return collapseWhitespace(result)
    }

    private func chatgptAnnotationReplacement(type: String, payload: String) -> String? {
        if type == "entity" {
            if let array = parseAnnotationPayload(payload) as? [Any] {
                if array.count > 1, let value = array[1] as? String {
                    return value
                }
                if let value = array.first as? String {
                    return value
                }
            }
            if let dict = parseAnnotationPayload(payload) as? [String: Any] {
                if let value = dict["text"] as? String {
                    return value
                }
                if let value = dict["name"] as? String {
                    return value
                }
            }
        }
        return nil
    }

    private func parseAnnotationPayload(_ payload: String) -> Any? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func collapseWhitespace(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }

    private func accessTokenValue() async throws -> String? {
        // Ensure keychain is loaded (deferred from init to avoid onboarding prompt)
        loadAccessTokenFromKeychain()
        if let accessToken, !accessToken.isEmpty {
            return accessToken
        }
        let session = try await fetchSession()
        accessToken = session.accessToken
        // Persist access token to Keychain
        KeychainHelper.chatgptAccessToken = session.accessToken
        #if DEBUG
        debugLog("fetchSession: accessToken=\(accessToken?.isEmpty == false ? "yes" : "no")")
        #endif
        return session.accessToken
    }

    private func writeDebugPayload(_ data: Data, label: String) {
        #if DEBUG
        let fileManager = FileManager.default
        let appSupportURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
        let directoryURL = appSupportURL
            .appendingPathComponent("Retain", isDirectory: true)
            .appendingPathComponent("Debug", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let filename = "\(label)-\(timestamp).json"
        let fileURL = directoryURL.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL, options: [.atomic])
            debugLog("saved response to \(fileURL.path)")
        } catch {
            debugLog("failed to save response: \(error.localizedDescription)")
        }
        #endif
    }
}

extension ChatGPTWebSync.AnyCodable {
    var stringValue: String? {
        value as? String
    }

    var intValue: Int? {
        value as? Int
    }

    var doubleValue: Double? {
        value as? Double
    }

    var boolValue: Bool? {
        value as? Bool
    }

    var arrayValue: [ChatGPTWebSync.AnyCodable]? {
        value as? [ChatGPTWebSync.AnyCodable]
    }

    var dictionaryValue: [String: ChatGPTWebSync.AnyCodable]? {
        value as? [String: ChatGPTWebSync.AnyCodable]
    }
}
