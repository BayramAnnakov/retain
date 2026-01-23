import Foundation

/// Parser for GitHub Copilot CLI session files
/// Data stored in: ~/.copilot/session-state/<sessionId>.jsonl
/// Format: JSONL with event envelopes { type, data, id, timestamp, parentId }
enum CopilotCLIParser {

    /// Base directory for Copilot CLI data
    static var copilotDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".copilot/session-state")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Discover all session files
    static func discoverSessionFiles() -> [URL] {
        guard let baseDir = copilotDirectory else { return [] }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else {
            return []
        }

        return files.filter { $0.pathExtension == "jsonl" }
    }

    /// Parse a single session file
    static func parseSession(at url: URL) -> (Conversation, [Message])? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }

        var messages: [Message] = []
        var sessionId: String?
        var model: String?
        var minTime: Date?
        var maxTime: Date?
        var toolCalls: [String: ToolCallInfo] = [:] // Track pending tool calls

        let conversationId = UUID()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let lineData = trimmed.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let eventType = event["type"] as? String ?? ""
            let data = event["data"] as? [String: Any] ?? [:]
            let timestamp = parseTimestamp(event["timestamp"])

            // Track time bounds
            if let ts = timestamp {
                if minTime == nil || ts < minTime! { minTime = ts }
                if maxTime == nil || ts > maxTime! { maxTime = ts }
            }

            switch eventType {
            case "session.info", "session.start":
                sessionId = sessionId ?? (data["sessionId"] as? String)

            case "session.model_change":
                model = data["model"] as? String

            case "user.message":
                if let content = data["content"] as? String, !content.isEmpty {
                    messages.append(Message(
                        id: UUID(),
                        conversationId: conversationId,
                        role: .user,
                        content: content,
                        timestamp: timestamp ?? Date()
                    ))
                }

            case "assistant.message":
                // Handle assistant message content
                if let content = data["content"] as? String, !content.isEmpty {
                    messages.append(Message(
                        id: UUID(),
                        conversationId: conversationId,
                        role: .assistant,
                        content: content,
                        timestamp: timestamp ?? Date()
                    ))
                }

                // Handle tool requests within assistant message
                if let toolRequests = data["toolRequests"] as? [[String: Any]] {
                    for request in toolRequests {
                        if let toolCallId = request["id"] as? String,
                           let toolName = request["name"] as? String {
                            let input = request["input"] as? [String: Any]
                            toolCalls[toolCallId] = ToolCallInfo(name: toolName, input: input, timestamp: timestamp ?? Date())
                        }
                    }
                }

            case "tool.execution_start":
                if let toolCallId = data["toolCallId"] as? String,
                   let toolName = data["name"] as? String {
                    let input = data["input"] as? [String: Any]
                    toolCalls[toolCallId] = ToolCallInfo(name: toolName, input: input, timestamp: timestamp ?? Date())
                }

            case "tool.execution_complete":
                if let toolCallId = data["toolCallId"] as? String {
                    var toolContent = ""

                    if let callInfo = toolCalls[toolCallId] {
                        toolContent = "Tool: \(callInfo.name)"
                        if let input = callInfo.input,
                           let jsonData = try? JSONSerialization.data(withJSONObject: input, options: .prettyPrinted),
                           let jsonStr = String(data: jsonData, encoding: .utf8) {
                            toolContent += "\nInput: \(jsonStr)"
                        }
                    } else {
                        toolContent = "Tool execution"
                    }

                    if let output = data["content"] as? String {
                        toolContent += "\nOutput: \(output)"
                    } else if let result = data["result"] as? String {
                        toolContent += "\nResult: \(result)"
                    }

                    if let error = data["error"] as? String {
                        toolContent += "\nError: \(error)"
                    }

                    messages.append(Message(
                        id: UUID(),
                        conversationId: conversationId,
                        role: .tool,
                        content: toolContent,
                        timestamp: timestamp ?? Date()
                    ))

                    toolCalls.removeValue(forKey: toolCallId)
                }

            default:
                break
            }
        }

        guard !messages.isEmpty else { return nil }

        let title = generateTitle(from: messages)

        let conversation = Conversation(
            id: conversationId,
            provider: .copilot,
            sourceType: .cli,
            externalId: sessionId ?? url.deletingPathExtension().lastPathComponent,
            title: title,
            projectPath: nil,
            createdAt: minTime ?? Date(),
            updatedAt: maxTime ?? Date(),
            messageCount: messages.count
        )

        return (conversation, messages)
    }

    // MARK: - Private Helpers

    private struct ToolCallInfo {
        let name: String
        let input: [String: Any]?
        let timestamp: Date
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let ts = value as? Double {
            // Unix timestamp (seconds or milliseconds)
            return ts > 1_000_000_000_000 ? Date(timeIntervalSince1970: ts / 1000) : Date(timeIntervalSince1970: ts)
        } else if let str = value as? String {
            // ISO8601 string
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) {
                return date
            }
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: str)
        }
        return nil
    }

    private static func generateTitle(from messages: [Message]) -> String {
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let content = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.count > 100 {
                return String(content.prefix(100)) + "..."
            }
            return content
        }
        return "Copilot CLI Session"
    }
}
