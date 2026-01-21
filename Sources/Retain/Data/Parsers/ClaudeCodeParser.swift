import Foundation

/// Parser for Claude Code JSONL conversation files
/// Located at: ~/.claude/projects/**/*.jsonl
final class ClaudeCodeParser: Sendable {
    /// Chunk size for streaming reads (256KB)
    private static let chunkSize = 256 * 1024

    /// Claude Code projects directory
    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    // MARK: - JSONL Line Structure

    /// Raw structure of a line in Claude Code JSONL
    struct RawLine: Decodable {
        let uuid: String
        let parentUuid: String?
        let type: String  // "user" or "assistant"
        let sessionId: String
        let timestamp: String
        let cwd: String?
        let gitBranch: String?
        let version: String?
        let agentId: String?
        let isMeta: Bool?      // True for meta/system messages
        let message: RawMessage?

        struct RawMessage: Decodable {
            let role: String
            let content: ContentType
            let model: String?
            let id: String?

            enum ContentType: Decodable {
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

                var text: String {
                    switch self {
                    case .string(let s): return s
                    case .array(let blocks):
                        return blocks.compactMap { $0.text }.joined()
                    }
                }

                var blocks: [ContentBlock] {
                    switch self {
                    case .string(let s):
                        return [ContentBlock(type: "text", text: s)]
                    case .array(let blocks):
                        return blocks
                    }
                }
            }

            struct ContentBlock: Decodable {
                let type: String?
                let text: String?
                let name: String?
                let title: String?
                let id: String?
                let toolUseId: String?
                let input: AnyCodable?
                let content: BlockContent?

                enum CodingKeys: String, CodingKey {
                    case type
                    case text
                    case name
                    case title
                    case id
                    case toolUseId = "tool_use_id"
                    case input
                    case content
                }

                init(type: String, text: String?) {
                    self.type = type
                    self.text = text
                    self.name = nil
                    self.title = nil
                    self.id = nil
                    self.toolUseId = nil
                    self.input = nil
                    self.content = nil
                }

                var contentText: String? {
                    if let contentText = content?.text, !contentText.isEmpty {
                        return contentText
                    }
                    return text
                }
            }
        }
    }

    // MARK: - Parsing

    /// Parse all conversations from a single JSONL file
    /// Returns nil if the file contains no actual messages (e.g., summary-only files)
    func parseFile(at url: URL) throws -> (Conversation, [Message])? {
        let data = try Data(contentsOf: url)
        return try parseData(data, fileURL: url)
    }

    /// Parse JSONL data with streaming support
    /// Returns nil if no actual messages found (e.g., summary-only files)
    func parseData(_ data: Data, fileURL: URL) throws -> (Conversation, [Message])? {
        var messages: [Message] = []
        var sessionId: String?
        var projectPath: String?
        var conversationTitle: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        // Split by newlines and parse each line
        let lines = data.split(separator: UInt8(ascii: "\n"))

        for lineData in lines {
            guard !lineData.isEmpty else { continue }

            do {
                let line = try JSONDecoder().decode(RawLine.self, from: Data(lineData))

                // Extract metadata from first line
                if sessionId == nil {
                    sessionId = line.sessionId
                    projectPath = line.cwd
                }

                // Parse timestamp
                let timestamp = parseTimestamp(line.timestamp) ?? Date()
                if firstTimestamp == nil {
                    firstTimestamp = timestamp
                }
                lastTimestamp = timestamp

                // Extract message content
                guard let rawMessage = line.message else { continue }

                let role: Role = switch rawMessage.role {
                case "user": .user
                case "assistant": .assistant
                case "system": .system
                default: .tool
                }

                let blocks = rawMessage.content.blocks
                let (textContent, toolBlocks) = splitContentBlocks(blocks)

                if !textContent.isEmpty {
                    // Extract title from user messages (skip meta messages)
                    if conversationTitle == nil && role == .user && line.isMeta != true {
                        if let title = extractTitle(from: textContent) {
                            conversationTitle = title
                        }
                    }

                    // Encode metadata for CLI sources (agentId, gitBranch, version)
                    let metadata: Data? = {
                        let dict: [String: String] = [
                            "agentId": line.agentId,
                            "gitBranch": line.gitBranch,
                            "version": line.version
                        ].compactMapValues { $0 }
                        guard !dict.isEmpty else { return nil }
                        return try? JSONEncoder().encode(dict)
                    }()

                    let message = Message(
                        id: UUID(),
                        conversationId: UUID(), // Will be set during insert
                        externalId: line.uuid,
                        parentId: nil,
                        role: role,
                        content: textContent,
                        timestamp: timestamp,
                        model: rawMessage.model,
                        metadata: metadata
                        // Note: rawPayload dropped for CLI sources - only needed for web structured rendering
                    )

                    messages.append(message)
                }

                let toolMessages = buildToolMessages(
                    from: toolBlocks,
                    baseExternalId: line.uuid,
                    timestamp: timestamp,
                    model: rawMessage.model
                )
                messages.append(contentsOf: toolMessages)

            } catch {
                // Skip malformed lines
                continue
            }
        }

        // Skip files with no actual messages (e.g., summary-only files)
        guard !messages.isEmpty else {
            return nil
        }

        // Create conversation
        // Note: rawPayload dropped for CLI sources - only needed for web structured rendering
        let conversation = Conversation(
            id: UUID(),
            provider: .claudeCode,
            sourceType: .cli,
            externalId: sessionId,
            title: conversationTitle ?? extractTitleFromPath(fileURL),
            previewText: extractPreview(from: messages),
            projectPath: projectPath,
            sourceFilePath: fileURL.path,
            createdAt: firstTimestamp ?? Date(),
            updatedAt: lastTimestamp ?? Date(),
            messageCount: messages.count
        )

        return (conversation, messages)
    }

    /// Stream parse a large file in chunks
    func streamParse(at url: URL, onConversation: (Conversation, [Message]) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        var allMessages: [Message] = []
        var currentSessionId: String?
        var projectPath: String?
        var conversationTitle: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        while true {
            let chunk = handle.readData(ofLength: Self.chunkSize)
            if chunk.isEmpty { break }

            buffer.append(chunk)

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[..<newlineIndex]
                buffer = buffer[buffer.index(after: newlineIndex)...]

                guard !lineData.isEmpty else { continue }

                do {
                    let line = try JSONDecoder().decode(RawLine.self, from: Data(lineData))

                    if currentSessionId == nil {
                        currentSessionId = line.sessionId
                        projectPath = line.cwd
                    }

                    let timestamp = parseTimestamp(line.timestamp) ?? Date()
                    if firstTimestamp == nil { firstTimestamp = timestamp }
                    lastTimestamp = timestamp

                    guard let rawMessage = line.message else { continue }

                    let role: Role = switch rawMessage.role {
                    case "user": .user
                    case "assistant": .assistant
                    case "system": .system
                    default: .tool
                    }

                    let blocks = rawMessage.content.blocks
                    let (textContent, toolBlocks) = splitContentBlocks(blocks)

                    if !textContent.isEmpty {
                        // Extract title from user messages (skip meta messages) - parity with batch parser
                        if conversationTitle == nil && role == .user && line.isMeta != true {
                            if let title = extractTitle(from: textContent) {
                                conversationTitle = title
                            }
                        }

                        // Encode metadata for CLI sources (agentId, gitBranch, version) - parity with batch parser
                        let metadata: Data? = {
                            let dict: [String: String] = [
                                "agentId": line.agentId,
                                "gitBranch": line.gitBranch,
                                "version": line.version
                            ].compactMapValues { $0 }
                            guard !dict.isEmpty else { return nil }
                            return try? JSONEncoder().encode(dict)
                        }()

                        let message = Message(
                            id: UUID(),
                            conversationId: UUID(),
                            externalId: line.uuid,
                            role: role,
                            content: textContent,
                            timestamp: timestamp,
                            model: rawMessage.model,
                            metadata: metadata
                            // Note: rawPayload dropped for CLI sources - only needed for web structured rendering
                        )

                        allMessages.append(message)
                    }

                    let toolMessages = buildToolMessages(
                        from: toolBlocks,
                        baseExternalId: line.uuid,
                        timestamp: timestamp,
                        model: rawMessage.model
                    )
                    allMessages.append(contentsOf: toolMessages)

                } catch {
                    continue
                }
            }
        }

        // Process remaining buffer
        if !buffer.isEmpty {
            if let line = try? JSONDecoder().decode(RawLine.self, from: buffer),
               let rawMessage = line.message {
                let role: Role = switch rawMessage.role {
                case "user": .user
                case "assistant": .assistant
                case "system": .system
                default: .tool
                }
                let timestamp = parseTimestamp(line.timestamp) ?? Date()
                lastTimestamp = timestamp

                let blocks = rawMessage.content.blocks
                let (textContent, toolBlocks) = splitContentBlocks(blocks)

                if !textContent.isEmpty {
                    // Encode metadata for CLI sources - parity with batch parser
                    let metadata: Data? = {
                        let dict: [String: String] = [
                            "agentId": line.agentId,
                            "gitBranch": line.gitBranch,
                            "version": line.version
                        ].compactMapValues { $0 }
                        guard !dict.isEmpty else { return nil }
                        return try? JSONEncoder().encode(dict)
                    }()

                    let message = Message(
                        id: UUID(),
                        conversationId: UUID(),
                        externalId: line.uuid,
                        role: role,
                        content: textContent,
                        timestamp: timestamp,
                        model: rawMessage.model,
                        metadata: metadata
                        // Note: rawPayload dropped for CLI sources
                    )
                    allMessages.append(message)
                }

                let toolMessages = buildToolMessages(
                    from: toolBlocks,
                    baseExternalId: line.uuid,
                    timestamp: timestamp,
                    model: rawMessage.model
                )
                allMessages.append(contentsOf: toolMessages)
            }
        }

        let conversation = Conversation(
            id: UUID(),
            provider: .claudeCode,
            sourceType: .cli,
            externalId: currentSessionId,
            title: conversationTitle ?? extractTitleFromPath(url),
            previewText: extractPreview(from: allMessages),
            projectPath: projectPath,
            sourceFilePath: url.path,
            createdAt: firstTimestamp ?? Date(),
            updatedAt: lastTimestamp ?? Date(),
            messageCount: allMessages.count
        )

        try onConversation(conversation, allMessages)
    }

    // MARK: - Discovery

    /// Find all JSONL files in Claude Code projects directory
    func discoverConversationFiles() -> [URL] {
        let projectsDir = Self.projectsDirectory

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return []
        }

        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "jsonl" {
                files.append(url)
            }
        }

        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Helpers

    /// Content representation for tool_result blocks.
    enum BlockContent: Decodable {
        case string(String)
        case array([BlockContentBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let array = try? container.decode([BlockContentBlock].self) {
                self = .array(array)
            } else {
                self = .string("")
            }
        }

        var text: String {
            switch self {
            case .string(let string):
                return string
            case .array(let blocks):
                return blocks.compactMap { $0.text }.joined()
            }
        }
    }

    struct BlockContentBlock: Decodable {
        let type: String?
        let text: String?
    }

    struct AnyCodable: Codable {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let int = try? container.decode(Int.self) {
                value = int
            } else if let double = try? container.decode(Double.self) {
                value = double
            } else if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let array = try? container.decode([AnyCodable].self) {
                value = array
            } else if let dict = try? container.decode([String: AnyCodable].self) {
                value = dict
            } else {
                value = ""
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch value {
            case let string as String:
                try container.encode(string)
            case let int as Int:
                try container.encode(int)
            case let double as Double:
                try container.encode(double)
            case let bool as Bool:
                try container.encode(bool)
            case let array as [AnyCodable]:
                try container.encode(array)
            case let dict as [String: AnyCodable]:
                try container.encode(dict)
            default:
                try container.encode(String(describing: value))
            }
        }

        var stringValue: String? {
            value as? String
        }

        var arrayValue: [AnyCodable]? {
            value as? [AnyCodable]
        }

        var dictionaryValue: [String: AnyCodable]? {
            value as? [String: AnyCodable]
        }
    }

    private struct ToolMetadata: Codable {
        let toolType: String
        let toolName: String?
        let toolUseId: String?
        let toolInput: String?
        let toolOutput: String?
    }

    private func splitContentBlocks(
        _ blocks: [RawLine.RawMessage.ContentBlock]
    ) -> (text: String, toolBlocks: [RawLine.RawMessage.ContentBlock]) {
        var textSegments: [String] = []
        var toolBlocks: [RawLine.RawMessage.ContentBlock] = []

        for block in blocks {
            let blockType = block.type?.lowercased()
            if blockType == "tool_use" || blockType == "tool_result" {
                toolBlocks.append(block)
            } else if let text = block.text, !text.isEmpty {
                textSegments.append(text)
            }
        }

        return (textSegments.joined(), toolBlocks)
    }

    private func buildToolMessages(
        from blocks: [RawLine.RawMessage.ContentBlock],
        baseExternalId: String,
        timestamp: Date,
        model: String?
    ) -> [Message] {
        var messages: [Message] = []

        for (index, block) in blocks.enumerated() {
            guard let summary = toolSummary(for: block), !summary.isEmpty else { continue }

            let metadata = ToolMetadata(
                toolType: block.type ?? "tool",
                toolName: block.name ?? block.title,
                toolUseId: block.id ?? block.toolUseId,
                toolInput: formatToolInput(block.input),
                toolOutput: formatToolOutput(block.contentText)
            )

            let metadataData = try? JSONEncoder().encode(metadata)
            let toolMessage = Message(
                id: UUID(),
                conversationId: UUID(),
                externalId: "\(baseExternalId):tool:\(index)",
                role: .tool,
                content: summary,
                timestamp: timestamp.addingTimeInterval(Double(index + 1) * 0.001),
                model: model,
                metadata: metadataData
            )
            messages.append(toolMessage)
        }

        return messages
    }

    private func toolSummary(for block: RawLine.RawMessage.ContentBlock) -> String? {
        let blockType = block.type?.lowercased() ?? "tool"
        let name = block.name ?? block.title ?? "Tool"

        switch blockType {
        case "tool_use":
            if let input = formatToolInput(block.input) {
                return "\(name) • \(input)"
            }
            return "\(name) • call"
        case "tool_result":
            if let output = formatToolOutput(block.contentText) {
                return "\(name) • result: \(output)"
            }
            return "\(name) • result"
        default:
            return nil
        }
    }

    private func formatToolInput(_ input: AnyCodable?) -> String? {
        guard let input else { return nil }

        if let string = input.stringValue, !string.isEmpty {
            return truncate(string, maxLength: 180)
        }

        if let dict = input.dictionaryValue {
            let preferredKeys = ["command", "query", "code", "path", "url", "args", "prompt", "pattern"]
            for key in preferredKeys {
                if let value = dict[key]?.stringValue, !value.isEmpty {
                    return "\(key): \(truncate(value, maxLength: 160))"
                }
            }
            let compact = dict.map { key, value in
                if let valueString = value.stringValue {
                    return "\(key): \(truncate(valueString, maxLength: 120))"
                }
                return key
            }.joined(separator: ", ")
            return compact.isEmpty ? nil : truncate(compact, maxLength: 180)
        }

        if let array = input.arrayValue {
            let joined = array.compactMap { $0.stringValue }.joined(separator: ", ")
            return joined.isEmpty ? nil : truncate(joined, maxLength: 180)
        }

        return nil
    }

    private func formatToolOutput(_ output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        return truncate(output, maxLength: 200)
    }

    private func truncate(_ text: String, maxLength: Int) -> String {
        if text.count <= maxLength {
            return text
        }
        let index = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<index]) + "..."
    }

    private func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Strip Claude Code metadata tags from content for display
    private func stripMetadataTags(_ content: String) -> String {
        var result = content

        // Remove XML-like metadata tags and their content
        let tagPatterns = [
            // Tags with content: <tag>...</tag>
            "<local-command-stdout>[^<]*</local-command-stdout>",
            "<local-command-stderr>[^<]*</local-command-stderr>",
            "<local-command-caveat>[^<]*</local-command-caveat>",
            "<command-name>[^<]*</command-name>",
            "<command-message>[^<]*</command-message>",
            "<command-args>[^<]*</command-args>",
            "<system-reminder>[\\s\\S]*?</system-reminder>",
            // Self-closing or unclosed tags
            "<local-command-stdout>",
            "<local-command-stderr>",
            "<local-command-caveat>",
            "</local-command-stdout>",
            "</local-command-stderr>",
            "</local-command-caveat>",
            "<command-name>",
            "</command-name>",
            // Common prefixes to strip
            "^Caveat: The messages below were generated by the user while running local command[^.]*\\.",
        ]

        for pattern in tagPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }

        // Clean up extra whitespace
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractTitle(from content: String) -> String? {
        let cleaned = stripMetadataTags(content)
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip very short content
        if trimmed.count < 10 {
            return nil
        }

        // Skip meta/system messages
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("caveat:") ||
           lowercased.contains("<command-name>") ||
           lowercased.contains("[request interrupted") ||
           lowercased.hasPrefix("```") ||
           lowercased.hasPrefix("cd ") ||
           lowercased.hasPrefix("ls ") ||
           lowercased.hasPrefix("git ") {
            return nil
        }

        let lines = trimmed.components(separatedBy: .newlines)
        let firstLine = lines.first(where: { !$0.isEmpty }) ?? trimmed
        let maxLength = 80

        // Clean up the first line
        let title = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression) // Remove markdown headers

        // Skip if the cleaned title is too short
        if title.count < 10 {
            return nil
        }

        if title.count <= maxLength {
            return title
        }

        // Try to cut at a natural boundary (space, punctuation)
        let truncated = String(title.prefix(maxLength))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "..."
        }
        return truncated + "..."
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
        // Strip metadata tags first, then format
        let cleaned = stripMetadataTags(text)
        let singleLine = cleaned.replacingOccurrences(of: "\n", with: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 120)
        return String(trimmed[..<index]) + "..."
    }

    private func extractTitleFromPath(_ url: URL) -> String {
        // Path structure: ~/.claude/projects/-Users-username-path-to-project/conversations.jsonl
        // We want to extract meaningful project info

        let parentDir = url.deletingLastPathComponent().lastPathComponent

        // Parse the encoded path: "-Users-bayram-GH-project-name" -> "project-name"
        let parts = parentDir.components(separatedBy: "-")

        // Find meaningful parts (skip common path components)
        let skipParts = Set(["", "Users", "home", "var", "tmp", "GH", "GitHub", "projects", "dev", "code", "src"])
        let meaningfulParts = parts.filter { part in
            !skipParts.contains(part) && part.count > 1
        }

        // Use last 1-2 meaningful parts as the project name
        if meaningfulParts.count >= 2 {
            return meaningfulParts.suffix(2).joined(separator: "/")
        } else if let last = meaningfulParts.last, !last.isEmpty {
            return last
        }

        // Fallback to session filename if path doesn't give us good info
        let filename = url.deletingPathExtension().lastPathComponent
        if filename != "conversations" && !filename.isEmpty {
            return filename
        }

        return "Untitled Conversation"
    }
}
