import Foundation

/// Parser for Gemini CLI session files
/// Data stored in: ~/.gemini/tmp/<hash>/(chats)?/session-*.json
enum GeminiCLIParser {

    /// Base directory for Gemini CLI data
    static var geminiDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".gemini/tmp")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Discover all session files
    static func discoverSessionFiles() -> [URL] {
        guard let baseDir = geminiDirectory else { return [] }

        var sessionFiles: [URL] = []
        let fm = FileManager.default

        // Enumerate hash directories
        guard let hashDirs = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        for hashDir in hashDirs {
            // Validate hash directory (32-64 hex characters)
            let hashName = hashDir.lastPathComponent
            guard hashName.range(of: "^[a-fA-F0-9]{32,64}$", options: .regularExpression) != nil else {
                continue
            }

            // Look for session files directly in hash dir or in chats subdir
            let searchPaths = [hashDir, hashDir.appendingPathComponent("chats")]

            for searchPath in searchPaths {
                guard let files = try? fm.contentsOfDirectory(at: searchPath, includingPropertiesForKeys: nil) else {
                    continue
                }

                for file in files {
                    if file.lastPathComponent.hasPrefix("session-") && file.pathExtension == "json" {
                        sessionFiles.append(file)
                    }
                }
            }
        }

        return sessionFiles
    }

    /// Parse a single session file
    static func parseSession(at url: URL) -> (Conversation, [Message])? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Try to parse as JSON
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var messages: [[String: Any]] = []
        var metadata: [String: Any] = [:]

        // Handle both formats: flat array or object wrapper
        if let array = json as? [[String: Any]] {
            messages = array
        } else if let dict = json as? [String: Any] {
            metadata = dict
            // Look for messages in various keys
            if let msgs = dict["messages"] as? [[String: Any]] {
                messages = msgs
            } else if let history = dict["history"] as? [[String: Any]] {
                messages = history
            } else if let items = dict["items"] as? [[String: Any]] {
                messages = items
            }
        }

        guard !messages.isEmpty else { return nil }

        // Extract project path from hash directory
        let hashDir = url.deletingLastPathComponent()
        let projectHash = hashDir.lastPathComponent

        // Parse messages into our format
        var parsedMessages: [Message] = []
        var minTime: Date?
        var maxTime: Date?
        var extractedModel: String?
        var extractedCwd: String?

        let conversationId = UUID()

        for msgDict in messages {
            guard let parsed = parseMessage(msgDict, conversationId: conversationId) else { continue }
            parsedMessages.append(parsed.message)

            // Track time bounds
            if minTime == nil || parsed.message.timestamp < minTime! {
                minTime = parsed.message.timestamp
            }
            if maxTime == nil || parsed.message.timestamp > maxTime! {
                maxTime = parsed.message.timestamp
            }

            // Extract model if present
            if let model = parsed.model {
                extractedModel = model
            }

            // Extract cwd if present
            if let cwd = parsed.cwd {
                extractedCwd = cwd
            }
        }

        guard !parsedMessages.isEmpty else { return nil }

        // Use metadata timestamps if available (ISO8601 strings)
        if let lastUpdatedStr = metadata["lastUpdated"] as? String {
            maxTime = parseISO8601(lastUpdatedStr) ?? maxTime
        } else if let lastUpdated = metadata["lastUpdated"] as? Double {
            maxTime = Date(timeIntervalSince1970: lastUpdated / 1000)
        }
        if let startTimeStr = metadata["startTime"] as? String {
            minTime = parseISO8601(startTimeStr) ?? minTime
        } else if let startTime = metadata["startTime"] as? Double {
            minTime = Date(timeIntervalSince1970: startTime / 1000)
        }

        // Generate title from first user message
        let title = generateTitle(from: parsedMessages)

        let conversation = Conversation(
            id: conversationId,
            provider: .geminiCLI,
            sourceType: .cli,
            externalId: url.lastPathComponent,
            title: title,
            projectPath: extractedCwd,
            createdAt: minTime ?? Date(),
            updatedAt: maxTime ?? Date(),
            messageCount: parsedMessages.count
        )

        return (conversation, parsedMessages)
    }

    // MARK: - Private Helpers

    private struct ParsedMessage {
        let message: Message
        let model: String?
        let cwd: String?
    }

    private static func parseMessage(_ dict: [String: Any], conversationId: UUID) -> ParsedMessage? {
        // Determine role
        let roleStr = (dict["type"] as? String) ?? (dict["role"] as? String) ?? ""
        let role: Role

        switch roleStr.lowercased() {
        case "user", "human":
            role = .user
        case "gemini", "model", "assistant":
            role = .assistant
        case "system":
            role = .system
        case "tool", "tool_result", "tool_use":
            role = .tool
        default:
            role = .assistant
        }

        // Extract content
        var content: String = ""
        if let text = dict["content"] as? String {
            content = text
        } else if let text = dict["text"] as? String {
            content = text
        } else if let parts = dict["parts"] as? [[String: Any]] {
            content = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else if let contentArray = dict["content"] as? [[String: Any]] {
            content = contentArray.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        // Skip empty messages
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Parse timestamp (Gemini CLI uses ISO8601 strings)
        var timestamp = Date()
        if let tsStr = dict["timestamp"] as? String {
            timestamp = parseISO8601(tsStr) ?? Date()
        } else if let ts = dict["ts"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts / 1000)
        } else if let ts = dict["timestamp"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts / 1000)
        } else if let ts = dict["created_at"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts / 1000)
        } else if let ts = dict["time"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts / 1000)
        }

        // Extract model
        let model = dict["model"] as? String

        // Extract cwd
        var cwd: String?
        if let cwdVal = dict["cwd"] as? String {
            cwd = cwdVal
        } else if let workingDir = dict["workingDir"] as? String {
            cwd = workingDir
        }

        let message = Message(
            id: UUID(),
            conversationId: conversationId,
            role: role,
            content: content,
            timestamp: timestamp
        )

        return ParsedMessage(message: message, model: model, cwd: cwd)
    }

    private static func generateTitle(from messages: [Message]) -> String {
        // Find first user message
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let content = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.count > 100 {
                return String(content.prefix(100)) + "..."
            }
            return content
        }
        return "Gemini CLI Session"
    }

    /// Parse ISO8601 date string
    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
