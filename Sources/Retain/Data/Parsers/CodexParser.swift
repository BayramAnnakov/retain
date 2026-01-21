import Foundation
import CryptoKit

/// Parser for Codex CLI JSONL history and session files
/// History: ~/.codex/history.jsonl (user prompts only)
/// Sessions: ~/.codex/sessions/YYYY/MM/DD/*.jsonl (full conversations)
final class CodexParser: Sendable {
    /// Codex CLI directory
    static var codexDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    /// History file location
    static var historyFile: URL {
        codexDirectory.appendingPathComponent("history.jsonl")
    }

    /// Sessions directory
    static var sessionsDirectory: URL {
        codexDirectory.appendingPathComponent("sessions")
    }

    // MARK: - History JSONL Line Structure

    /// Raw structure of a line in Codex history JSONL
    struct HistoryLine: Decodable {
        let session_id: String
        let ts: Int          // Unix timestamp
        let text: String     // User prompt text
    }

    // MARK: - Session JSONL Line Structures

    /// Raw structure of a line in Codex session JSONL
    struct SessionLine: Decodable {
        let timestamp: String
        let type: String     // "session_meta", "response_item", "event_msg", etc.
        let payload: SessionPayload?

        struct SessionPayload: Decodable {
            // For session_meta
            let id: String?
            let cwd: String?
            let cli_version: String?
            let model_provider: String?

            // For response_item (messages)
            let role: String?
            let content: [ContentBlock]?

            // Nested type field for response_item
            // "type": "message" indicates a message payload
            // We use CodingKeys to avoid conflict with outer type

            struct ContentBlock: Decodable {
                let type: String?  // "input_text" or "output_text"
                let text: String?
            }
        }
    }

    // MARK: - Parsing

    /// Parse all Codex conversations (sessions preferred, fallback to history)
    func parseHistoryFile() throws -> [(Conversation, [Message])] {
        // Try session files first (they have assistant responses)
        let sessionResults = try parseSessionFiles()
        if !sessionResults.isEmpty {
            return sessionResults
        }

        // Fallback to history.jsonl (user prompts only)
        return try parseHistoryOnly()
    }

    /// Parse history.jsonl file only (user prompts)
    func parseHistoryOnly() throws -> [(Conversation, [Message])] {
        let url = Self.historyFile

        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        return try parseHistoryData(data)
    }

    /// Parse history.jsonl data grouped by session_id (user prompts only)
    func parseHistoryData(_ data: Data) throws -> [(Conversation, [Message])] {
        // Note: rawPayload dropped for CLI sources - only store (line, timestamp)
        var sessionMessages: [String: [(HistoryLine, Date)]] = [:]

        let lines = data.split(separator: UInt8(ascii: "\n"))

        for lineData in lines {
            guard !lineData.isEmpty else { continue }

            do {
                let line = try JSONDecoder().decode(HistoryLine.self, from: Data(lineData))
                let timestamp = Date(timeIntervalSince1970: Double(line.ts))

                if sessionMessages[line.session_id] == nil {
                    sessionMessages[line.session_id] = []
                }
                sessionMessages[line.session_id]?.append((line, timestamp))

            } catch {
                continue
            }
        }

        // Convert to conversations and messages
        var results: [(Conversation, [Message])] = []

        for (sessionId, entries) in sessionMessages {
            guard !entries.isEmpty else { continue }

            let sortedEntries = entries.sorted { $0.1 < $1.1 }
            let firstEntry = sortedEntries.first!
            let lastEntry = sortedEntries.last!

            // Create messages (history only stores user prompts)
            var messages: [Message] = []
            for (line, timestamp) in sortedEntries {
                let identity = stableMessageIdentity(
                    sessionId: sessionId,
                    role: .user,
                    timestamp: timestamp,
                    content: line.text
                )
                let message = Message(
                    id: identity.id,
                    conversationId: UUID(),
                    externalId: identity.externalId,
                    role: .user,
                    content: line.text,
                    timestamp: timestamp
                    // Note: rawPayload dropped for CLI sources - only needed for web structured rendering
                )
                messages.append(message)
            }

            // Extract title from first message
            let title = extractTitle(from: firstEntry.0.text) ?? String(firstEntry.0.text.prefix(80))

            let conversation = Conversation(
                id: UUID(),
                provider: .codex,
                sourceType: .cli,
                externalId: sessionId,
                title: title,
                previewText: extractPreview(from: messages),
                createdAt: firstEntry.1,
                updatedAt: lastEntry.1,
                messageCount: messages.count
            )

            results.append((conversation, messages))
        }

        // Sort by most recent first
        return results.sorted { $0.0.updatedAt > $1.0.updatedAt }
    }

    /// Parse session-specific JSONL files from ~/.codex/sessions/ (full conversations)
    func parseSessionFiles() throws -> [(Conversation, [Message])] {
        let sessionsDir = Self.sessionsDirectory

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return []
        }

        var results: [(Conversation, [Message])] = []

        // Recursively find all JSONL files in sessions directory
        // Structure: sessions/YYYY/MM/DD/*.jsonl
        let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }

            if let (conversation, messages) = try? parseSessionFile(at: url) {
                results.append((conversation, messages))
            }
        }

        return results.sorted { $0.0.updatedAt > $1.0.updatedAt }
    }

    /// Parse a single session file (full conversation with assistant responses)
    /// Public to allow incremental sync of individual session files
    func parseSessionFile(at url: URL) throws -> (Conversation, [Message])? {
        let data = try Data(contentsOf: url)
        return try parseSessionData(data, fileURL: url)
    }

    /// Chunk size for streaming reads (256KB)
    private static let chunkSize = 256 * 1024

    /// Stream parse a session file to avoid loading entire file into memory
    /// Use this for large session files to prevent memory spikes
    func streamParseSessionFile(at url: URL) throws -> (Conversation, [Message])? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        var messages: [Message] = []
        var sessionId: String?
        var projectPath: String?
        var model: String?
        var conversationTitle: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        while true {
            guard let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[..<newlineIndex]
                buffer = buffer[buffer.index(after: newlineIndex)...]

                guard !lineData.isEmpty else { continue }

                do {
                    let line = try JSONDecoder().decode(SessionLine.self, from: Data(lineData))
                    let timestamp = parseTimestamp(line.timestamp) ?? Date()

                    if firstTimestamp == nil {
                        firstTimestamp = timestamp
                    }
                    lastTimestamp = timestamp

                    switch line.type {
                    case "session_meta":
                        sessionId = line.payload?.id
                        projectPath = line.payload?.cwd
                        model = line.payload?.model_provider

                    case "response_item":
                        guard let payload = line.payload,
                              let role = payload.role,
                              let contentBlocks = payload.content else {
                            continue
                        }

                        let content = contentBlocks.compactMap { $0.text }.joined()
                        guard !content.isEmpty else { continue }

                        // Skip system/instruction messages
                        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.hasPrefix("# AGENTS.md") ||
                           trimmed.hasPrefix("<environment_context>") ||
                           trimmed.hasPrefix("<INSTRUCTIONS>") {
                            continue
                        }

                        let messageRole: Role = switch role {
                        case "user": .user
                        case "assistant": .assistant
                        case "system": .system
                        default: .tool
                        }

                        if conversationTitle == nil && messageRole == .user {
                            if let title = extractTitle(from: content) {
                                conversationTitle = title
                            }
                        }

                        let sessionKey = sessionId ?? url.deletingPathExtension().lastPathComponent
                        let identity = stableMessageIdentity(
                            sessionId: sessionKey,
                            role: messageRole,
                            timestamp: timestamp,
                            content: content
                        )
                        let message = Message(
                            id: identity.id,
                            conversationId: UUID(),
                            externalId: identity.externalId,
                            role: messageRole,
                            content: content,
                            timestamp: timestamp,
                            model: messageRole == .assistant ? model : nil
                        )
                        messages.append(message)

                    default:
                        continue
                    }

                } catch {
                    continue
                }
            }
        }

        guard !messages.isEmpty else {
            return nil
        }

        // Generate session ID from filename if not found in metadata
        if sessionId == nil {
            let filename = url.deletingPathExtension().lastPathComponent
            if let uuidRange = filename.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                                               options: .regularExpression) {
                sessionId = String(filename[uuidRange])
            } else {
                sessionId = filename
            }
        }

        // Build conversation - same logic as parseSessionData
        let conversation = Conversation(
            id: UUID(),
            provider: .codex,
            sourceType: .cli,
            externalId: sessionId,
            title: conversationTitle ?? extractTitleFromFilename(url),
            previewText: extractPreview(from: messages),
            projectPath: projectPath,
            createdAt: firstTimestamp ?? Date(),
            updatedAt: lastTimestamp ?? Date(),
            messageCount: messages.count
        )

        return (conversation, messages)
    }

    /// Check if sessions directory exists AND contains .jsonl files
    func hasSessionFiles() -> Bool {
        let sessionsDir = Self.sessionsDirectory
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return false
        }

        // Check if there are any .jsonl files (quick check, not full enumeration)
        let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "jsonl" {
                return true
            }
        }

        return false
    }

    /// Discover all session files in the sessions directory
    func discoverSessionFiles() -> [URL] {
        let sessionsDir = Self.sessionsDirectory

        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return []
        }

        var files: [URL] = []

        let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "jsonl" {
                files.append(url)
            }
        }

        return files
    }

    /// Parse session JSONL data (full conversations)
    func parseSessionData(_ data: Data, fileURL: URL) throws -> (Conversation, [Message])? {
        var messages: [Message] = []
        var sessionId: String?
        var projectPath: String?
        var model: String?
        var conversationTitle: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        let lines = data.split(separator: UInt8(ascii: "\n"))

        for lineData in lines {
            guard !lineData.isEmpty else { continue }

            do {
                let line = try JSONDecoder().decode(SessionLine.self, from: Data(lineData))
                let timestamp = parseTimestamp(line.timestamp) ?? Date()

                if firstTimestamp == nil {
                    firstTimestamp = timestamp
                }
                lastTimestamp = timestamp

                switch line.type {
                case "session_meta":
                    // Extract session metadata
                    sessionId = line.payload?.id
                    projectPath = line.payload?.cwd
                    model = line.payload?.model_provider

                case "response_item":
                    // Extract messages (user and assistant)
                    guard let payload = line.payload,
                          let role = payload.role,
                          let contentBlocks = payload.content else {
                        continue
                    }

                    // Concatenate all text content blocks
                    let content = contentBlocks.compactMap { $0.text }.joined()
                    guard !content.isEmpty else { continue }

                    // Skip system/instruction messages
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("# AGENTS.md") ||
                       trimmed.hasPrefix("<environment_context>") ||
                       trimmed.hasPrefix("<INSTRUCTIONS>") {
                        continue
                    }

                    let messageRole: Role = switch role {
                    case "user": .user
                    case "assistant": .assistant
                    case "system": .system
                    default: .tool
                    }

                    // Extract title from first meaningful user message
                    if conversationTitle == nil && messageRole == .user {
                        if let title = extractTitle(from: content) {
                            conversationTitle = title
                        }
                    }

                    let sessionKey = sessionId ?? fileURL.deletingPathExtension().lastPathComponent
                    let identity = stableMessageIdentity(
                        sessionId: sessionKey,
                        role: messageRole,
                        timestamp: timestamp,
                        content: content
                    )
                    let message = Message(
                        id: identity.id,
                        conversationId: UUID(),
                        externalId: identity.externalId,
                        role: messageRole,
                        content: content,
                        timestamp: timestamp,
                        model: messageRole == .assistant ? model : nil
                        // Note: rawPayload dropped for CLI sources - only needed for web structured rendering
                    )
                    messages.append(message)

                default:
                    // Skip event_msg, turn_context, reasoning, function_call, etc.
                    continue
                }

            } catch {
                continue
            }
        }

        // Skip files with no actual messages
        guard !messages.isEmpty else {
            return nil
        }

        // Generate session ID from filename if not found in metadata
        if sessionId == nil {
            // Extract session ID from filename like "rollout-2026-01-05T03-03-27-019b8dd3-81ff-78f1-a7d4-307bcdf8a757.jsonl"
            let filename = fileURL.deletingPathExtension().lastPathComponent
            if let uuidRange = filename.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                                               options: .regularExpression) {
                sessionId = String(filename[uuidRange])
            } else {
                sessionId = filename
            }
        }

        // Note: rawPayload dropped for CLI sources - only needed for web structured rendering
        let conversation = Conversation(
            id: UUID(),
            provider: .codex,
            sourceType: .cli,
            externalId: sessionId,
            title: conversationTitle ?? extractTitleFromFilename(fileURL),
            previewText: extractPreview(from: messages),
            projectPath: projectPath,
            createdAt: firstTimestamp ?? Date(),
            updatedAt: lastTimestamp ?? Date(),
            messageCount: messages.count
        )

        return (conversation, messages)
    }

    // MARK: - Discovery

    /// Check if Codex CLI is installed and has history
    func hasHistory() -> Bool {
        FileManager.default.fileExists(atPath: Self.historyFile.path)
    }

    /// Get size of history file
    func historyFileSize() -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.historyFile.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    // MARK: - Helpers

    private func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private func extractTitle(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip very short content
        if trimmed.count < 10 {
            return nil
        }

        // Skip system/meta messages
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("# agents.md") ||
           lowercased.hasPrefix("<environment") ||
           lowercased.hasPrefix("<instructions") ||
           lowercased.hasPrefix("```") {
            return nil
        }

        let lines = trimmed.components(separatedBy: .newlines)
        let firstLine = lines.first(where: { !$0.isEmpty }) ?? trimmed
        let maxLength = 80

        if firstLine.count <= maxLength {
            return firstLine
        }

        // Try to cut at a natural boundary
        let truncated = String(firstLine.prefix(maxLength))
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
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 120)
        return String(trimmed[..<index]) + "..."
    }

    private func extractTitleFromFilename(_ url: URL) -> String {
        // Extract meaningful title from filename like "rollout-2026-01-05T03-03-27-019b8dd3..."
        let filename = url.deletingPathExtension().lastPathComponent

        // Try to extract date for a readable title
        if filename.hasPrefix("rollout-") {
            // Extract date portion: "2026-01-05T03-03-27" -> "Jan 5, 2026 03:03"
            let dateStr = String(filename.dropFirst("rollout-".count).prefix(19))
            let cleanDateStr = dateStr.replacingOccurrences(of: "T", with: " ")
                .replacingOccurrences(of: "-", with: ":", options: [], range: dateStr.index(dateStr.startIndex, offsetBy: 10)..<dateStr.endIndex)

            let inputFormatter = DateFormatter()
            inputFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = inputFormatter.date(from: cleanDateStr.prefix(19).replacingOccurrences(of: "-", with: ":").replacingOccurrences(of: "T", with: " ")) {
                let outputFormatter = DateFormatter()
                outputFormatter.dateFormat = "MMM d, yyyy HH:mm"
                return "Codex Session - \(outputFormatter.string(from: date))"
            }
        }

        return "Codex Session"
    }

    private func stableMessageIdentity(sessionId: String, role: Role, timestamp: Date, content: String) -> (id: UUID, externalId: String) {
        let millis = Int(timestamp.timeIntervalSince1970 * 1000)
        let fingerprint = "\(sessionId)|\(role.rawValue)|\(millis)|\(content)"
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
        let bytes = Array(digest)
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (uuid, hex)
    }
}
