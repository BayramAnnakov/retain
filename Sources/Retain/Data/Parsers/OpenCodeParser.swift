import Foundation

/// Parser for OpenCode session files
/// Data structure:
/// - Sessions: ~/.local/share/opencode/storage/session/<projectID>/ses_<ID>.json
/// - Messages: ~/.local/share/opencode/storage/message/<sessionID>/msg_*.json
/// - Parts: ~/.local/share/opencode/storage/part/<messageID>/prt_*.json
enum OpenCodeParser {

    /// Base directory for OpenCode data
    static var openCodeDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".local/share/opencode/storage")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Discover all session files
    static func discoverSessionFiles() -> [URL] {
        guard let baseDir = openCodeDirectory else { return [] }

        let sessionDir = baseDir.appendingPathComponent("session")
        guard FileManager.default.fileExists(atPath: sessionDir.path) else { return [] }

        var sessionFiles: [URL] = []
        let fm = FileManager.default

        // Enumerate project directories
        guard let projectDirs = try? fm.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        for projectDir in projectDirs {
            // Look for ses_*.json files
            guard let files = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else {
                continue
            }

            for file in files {
                if file.lastPathComponent.hasPrefix("ses_") && file.pathExtension == "json" {
                    sessionFiles.append(file)
                }
            }
        }

        return sessionFiles
    }

    /// Parse a single session file with its messages
    static func parseSession(at url: URL) -> (Conversation, [Message])? {
        guard let baseDir = openCodeDirectory else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let sessionDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Extract session metadata
        guard let sessionId = sessionDict["id"] as? String else { return nil }

        let projectPath = sessionDict["directory"] as? String
        let title = sessionDict["title"] as? String

        // Parse timestamps (stored in milliseconds)
        var createdAt = Date()
        var updatedAt = Date()

        if let time = sessionDict["time"] as? [String: Any] {
            if let created = time["created"] as? Double {
                createdAt = Date(timeIntervalSince1970: created / 1000)
            }
            if let updated = time["updated"] as? Double {
                updatedAt = Date(timeIntervalSince1970: updated / 1000)
            }
        }

        let conversationId = UUID()

        // Load messages from message directory
        let messageDir = baseDir.appendingPathComponent("message").appendingPathComponent(sessionId)
        var parsedMessages = loadMessages(from: messageDir, baseDir: baseDir, conversationId: conversationId)

        // Sort messages by timestamp
        parsedMessages.sort { $0.timestamp < $1.timestamp }

        // Update time bounds from messages if available
        if let firstMsg = parsedMessages.first {
            createdAt = min(createdAt, firstMsg.timestamp)
        }
        if let lastMsg = parsedMessages.last {
            updatedAt = max(updatedAt, lastMsg.timestamp)
        }

        let conversation = Conversation(
            id: conversationId,
            provider: .opencode,
            sourceType: .cli,
            externalId: sessionId,
            title: title ?? generateTitle(from: parsedMessages),
            projectPath: projectPath,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: parsedMessages.count
        )

        return (conversation, parsedMessages)
    }

    // MARK: - Private Helpers

    private static func loadMessages(from messageDir: URL, baseDir: URL, conversationId: UUID) -> [Message] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: messageDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var messages: [Message] = []

        // Sort files by name for consistent ordering
        let sortedFiles = files.filter { $0.lastPathComponent.hasPrefix("msg_") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in sortedFiles {
            guard let msgData = try? Data(contentsOf: file),
                  let msgDict = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] else {
                continue
            }

            // Parse the message
            if let parsed = parseMessage(msgDict, baseDir: baseDir, conversationId: conversationId) {
                messages.append(contentsOf: parsed)
            }
        }

        return messages
    }

    private static func parseMessage(_ dict: [String: Any], baseDir: URL, conversationId: UUID) -> [Message]? {
        // Determine role
        let roleStr = (dict["role"] as? String) ?? ""
        let role: Role

        switch roleStr.lowercased() {
        case "user":
            role = .user
        case "assistant":
            role = .assistant
        case "system":
            role = .system
        case "tool":
            role = .tool
        default:
            role = .assistant
        }

        // Parse timestamp
        var timestamp = Date()
        if let time = dict["time"] as? [String: Any],
           let created = time["created"] as? Double {
            timestamp = Date(timeIntervalSince1970: created / 1000)
        }

        var messages: [Message] = []

        // Try to load parts for richer content
        if let messageId = dict["id"] as? String {
            let partsMessages = loadParts(messageId: messageId, baseDir: baseDir, conversationId: conversationId, baseTimestamp: timestamp, baseRole: role)
            if !partsMessages.isEmpty {
                messages.append(contentsOf: partsMessages)
            }
        }

        // If no parts, use summary or fallback
        if messages.isEmpty {
            var content = ""

            // Try summary first
            if let summary = dict["summary"] as? [String: Any] {
                if let body = summary["body"] as? String, !body.isEmpty {
                    content = body
                } else if let title = summary["title"] as? String, !title.isEmpty {
                    content = title
                }
            }

            // Skip empty content
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            messages.append(Message(
                id: UUID(),
                conversationId: conversationId,
                role: role,
                content: content,
                timestamp: timestamp
            ))
        }

        return messages.isEmpty ? nil : messages
    }

    private static func loadParts(messageId: String, baseDir: URL, conversationId: UUID, baseTimestamp: Date, baseRole: Role) -> [Message] {
        let fm = FileManager.default
        let partDir = baseDir.appendingPathComponent("part").appendingPathComponent(messageId)

        guard let files = try? fm.contentsOfDirectory(at: partDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var messages: [Message] = []

        // Sort files by name
        let sortedFiles = files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in sortedFiles {
            guard let partData = try? Data(contentsOf: file),
                  let partDict = try? JSONSerialization.jsonObject(with: partData) as? [String: Any] else {
                continue
            }

            let partType = partDict["type"] as? String ?? ""

            // Parse timestamp
            var timestamp = baseTimestamp
            if let ts = partDict["time"] as? Double {
                timestamp = Date(timeIntervalSince1970: ts / 1000)
            }

            switch partType {
            case "text":
                if let text = partDict["text"] as? String, !text.isEmpty {
                    messages.append(Message(
                        id: UUID(),
                        conversationId: conversationId,
                        role: baseRole,
                        content: text,
                        timestamp: timestamp
                    ))
                }

            case "tool":
                // Extract tool call info
                let toolName = partDict["tool"] as? String ?? "unknown_tool"
                var toolContent = "Tool: \(toolName)"

                if let state = partDict["state"] as? [String: Any] {
                    if let input = state["input"] {
                        if let inputStr = input as? String {
                            toolContent += "\nInput: \(inputStr)"
                        } else if let inputDict = input as? [String: Any],
                                  let jsonData = try? JSONSerialization.data(withJSONObject: inputDict, options: .prettyPrinted),
                                  let jsonStr = String(data: jsonData, encoding: .utf8) {
                            toolContent += "\nInput: \(jsonStr)"
                        }
                    }

                    if let output = state["output"] as? String, !output.isEmpty {
                        toolContent += "\nOutput: \(output)"
                    }

                    if let error = state["error"] as? String, !error.isEmpty {
                        toolContent += "\nError: \(error)"
                    }
                }

                messages.append(Message(
                    id: UUID(),
                    conversationId: conversationId,
                    role: .tool,
                    content: toolContent,
                    timestamp: timestamp
                ))

            case "reasoning":
                if let text = partDict["text"] as? String, !text.isEmpty {
                    messages.append(Message(
                        id: UUID(),
                        conversationId: conversationId,
                        role: .assistant,
                        content: "[Reasoning]\n\(text)",
                        timestamp: timestamp
                    ))
                }

            default:
                // Try to extract any text content
                if let text = partDict["text"] as? String, !text.isEmpty {
                    messages.append(Message(
                        id: UUID(),
                        conversationId: conversationId,
                        role: baseRole,
                        content: text,
                        timestamp: timestamp
                    ))
                }
            }
        }

        return messages
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
        return "OpenCode Session"
    }
}
