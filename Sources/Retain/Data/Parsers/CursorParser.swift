import Foundation
import GRDB

/// Parser for Cursor AI IDE session data
/// Data stored in SQLite databases:
/// - Chat mode: ~/Library/Application Support/Cursor/User/workspaceStorage/<hash>/state.vscdb
/// - Composer mode: ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
///
/// Tables:
/// - ItemTable (key, value) - Chat mode data
/// - cursorDiskKV (key, value) - Composer/Agent mode data
///
/// Keys:
/// - workbench.panel.aichat.view.aichat.chatdata - Chat mode
/// - composerData:<uuid> - Composer conversations
enum CursorParser {

    /// Base directory for Cursor workspace storage
    static var workspaceStorageDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Global storage directory for Composer data
    static var globalStorageDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Discover all state.vscdb files
    static func discoverDatabaseFiles() -> [URL] {
        var dbFiles: [URL] = []
        let fm = FileManager.default

        // Check workspace storage (Chat mode)
        if let wsDir = workspaceStorageDirectory {
            if let hashDirs = try? fm.contentsOfDirectory(at: wsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
                for hashDir in hashDirs {
                    let dbPath = hashDir.appendingPathComponent("state.vscdb")
                    if fm.fileExists(atPath: dbPath.path) {
                        dbFiles.append(dbPath)
                    }
                }
            }
        }

        // Check global storage (Composer mode)
        if let gsDir = globalStorageDirectory {
            let dbPath = gsDir.appendingPathComponent("state.vscdb")
            if fm.fileExists(atPath: dbPath.path) {
                dbFiles.append(dbPath)
            }
        }

        return dbFiles
    }

    /// Parse all conversations from discovered databases
    static func parseAllSessions() -> [(Conversation, [Message])] {
        var results: [(Conversation, [Message])] = []

        for dbFile in discoverDatabaseFiles() {
            // Try Chat mode parsing
            if let chatSessions = parseChatMode(from: dbFile) {
                results.append(contentsOf: chatSessions)
            }

            // Try Composer mode parsing
            if let composerSessions = parseComposerMode(from: dbFile) {
                results.append(contentsOf: composerSessions)
            }
        }

        return results
    }

    // MARK: - Chat Mode Parsing

    /// Parse Chat mode data from ItemTable
    private static func parseChatMode(from dbFile: URL) -> [(Conversation, [Message])]? {
        guard let dbQueue = try? DatabaseQueue(path: dbFile.path) else { return nil }

        do {
            let chatDataJson: String? = try dbQueue.read { db in
                // Check if ItemTable exists
                let tableExists = try db.tableExists("ItemTable")
                guard tableExists else { return nil }

                let row = try Row.fetchOne(db, sql: """
                    SELECT value FROM ItemTable
                    WHERE [key] = 'workbench.panel.aichat.view.aichat.chatdata'
                """)
                return row?["value"] as? String
            }

            guard let json = chatDataJson,
                  let data = json.data(using: .utf8),
                  let chatData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return parseChatDataJson(chatData, sourceFile: dbFile)

        } catch {
            print("Error reading Cursor Chat mode: \(error)")
            return nil
        }
    }

    /// Parse the chat data JSON structure: { tabs: [ { timestamp, bubbles: [...] } ] }
    private static func parseChatDataJson(_ chatData: [String: Any], sourceFile: URL) -> [(Conversation, [Message])]? {
        guard let tabs = chatData["tabs"] as? [[String: Any]] else { return nil }

        var results: [(Conversation, [Message])] = []

        for (index, tab) in tabs.enumerated() {
            guard let bubbles = tab["bubbles"] as? [[String: Any]], !bubbles.isEmpty else { continue }

            let conversationId = UUID()
            var messages: [Message] = []
            var minTime: Date?
            var maxTime: Date?

            for bubble in bubbles {
                guard let parsed = parseBubble(bubble, conversationId: conversationId) else { continue }
                messages.append(parsed)

                if minTime == nil || parsed.timestamp < minTime! { minTime = parsed.timestamp }
                if maxTime == nil || parsed.timestamp > maxTime! { maxTime = parsed.timestamp }
            }

            guard !messages.isEmpty else { continue }

            // Get timestamp from tab
            var tabTime = Date()
            if let ts = tab["timestamp"] as? Double {
                tabTime = Date(timeIntervalSince1970: ts / 1000)
            }

            let conversation = Conversation(
                id: conversationId,
                provider: .cursor,
                sourceType: .cli,
                externalId: "chat-\(sourceFile.deletingLastPathComponent().lastPathComponent)-\(index)",
                title: generateTitle(from: messages),
                projectPath: extractProjectPath(from: sourceFile),
                createdAt: minTime ?? tabTime,
                updatedAt: maxTime ?? tabTime,
                messageCount: messages.count
            )

            results.append((conversation, messages))
        }

        return results.isEmpty ? nil : results
    }

    // MARK: - Composer Mode Parsing

    /// Parse Composer mode data from cursorDiskKV
    private static func parseComposerMode(from dbFile: URL) -> [(Conversation, [Message])]? {
        guard let dbQueue = try? DatabaseQueue(path: dbFile.path) else { return nil }

        do {
            let composerData: [(String, String)] = try dbQueue.read { db in
                // Check if cursorDiskKV exists
                let tableExists = try db.tableExists("cursorDiskKV")
                guard tableExists else { return [] }

                let rows = try Row.fetchAll(db, sql: """
                    SELECT key, value FROM cursorDiskKV
                    WHERE key LIKE 'composerData:%'
                """)

                return rows.compactMap { row -> (String, String)? in
                    guard let key = row["key"] as? String,
                          let value = row["value"] as? String else { return nil }
                    return (key, value)
                }
            }

            guard !composerData.isEmpty else { return nil }

            var results: [(Conversation, [Message])] = []

            for (key, jsonStr) in composerData {
                guard let data = jsonStr.data(using: .utf8),
                      let composerDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                if let parsed = parseComposerData(composerDict, key: key, sourceFile: dbFile) {
                    results.append(parsed)
                }
            }

            return results.isEmpty ? nil : results

        } catch {
            print("Error reading Cursor Composer mode: \(error)")
            return nil
        }
    }

    /// Parse a single Composer conversation
    private static func parseComposerData(_ composerDict: [String: Any], key: String, sourceFile: URL) -> (Conversation, [Message])? {
        let conversationId = UUID()
        var messages: [Message] = []

        // Extract composer ID from key (composerData:<uuid>)
        let composerId = String(key.dropFirst("composerData:".count))

        // Try to get messages from conversation array
        if let conversation = composerDict["conversation"] as? [[String: Any]] {
            for msgDict in conversation {
                if let msg = parseComposerMessage(msgDict, conversationId: conversationId) {
                    messages.append(msg)
                }
            }
        }

        // Also try bubbles format
        if let bubbles = composerDict["bubbles"] as? [[String: Any]] {
            for bubble in bubbles {
                if let msg = parseBubble(bubble, conversationId: conversationId) {
                    messages.append(msg)
                }
            }
        }

        guard !messages.isEmpty else { return nil }

        // Sort by timestamp
        messages.sort { $0.timestamp < $1.timestamp }

        let conversation = Conversation(
            id: conversationId,
            provider: .cursor,
            sourceType: .cli,
            externalId: composerId,
            title: composerDict["name"] as? String ?? generateTitle(from: messages),
            projectPath: composerDict["workspacePath"] as? String ?? extractProjectPath(from: sourceFile),
            createdAt: messages.first?.timestamp ?? Date(),
            updatedAt: messages.last?.timestamp ?? Date(),
            messageCount: messages.count
        )

        return (conversation, messages)
    }

    // MARK: - Message Parsing Helpers

    private static func parseBubble(_ bubble: [String: Any], conversationId: UUID) -> Message? {
        // Determine role
        let type = bubble["type"] as? String ?? bubble["role"] as? String ?? ""
        let role: Role

        switch type.lowercased() {
        case "user", "human":
            role = .user
        case "ai", "assistant", "model":
            role = .assistant
        case "tool", "tool_result":
            role = .tool
        case "system":
            role = .system
        default:
            role = .assistant
        }

        // Extract content
        var content = ""
        if let text = bubble["text"] as? String {
            content = text
        } else if let msg = bubble["message"] as? String {
            content = msg
        } else if let contentStr = bubble["content"] as? String {
            content = contentStr
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Parse timestamp
        var timestamp = Date()
        if let ts = bubble["timestamp"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts / 1000)
        } else if let ts = bubble["createdAt"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts / 1000)
        }

        return Message(
            id: UUID(),
            conversationId: conversationId,
            role: role,
            content: content,
            timestamp: timestamp
        )
    }

    private static func parseComposerMessage(_ msgDict: [String: Any], conversationId: UUID) -> Message? {
        let role: Role
        let sender = msgDict["sender"] as? String ?? msgDict["role"] as? String ?? ""

        switch sender.lowercased() {
        case "user", "human":
            role = .user
        case "ai", "assistant", "model":
            role = .assistant
        case "tool":
            role = .tool
        default:
            role = .assistant
        }

        var content = ""
        if let text = msgDict["text"] as? String {
            content = text
        } else if let contentStr = msgDict["content"] as? String {
            content = contentStr
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var timestamp = Date()
        if let ts = msgDict["timestamp"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts / 1000)
        }

        return Message(
            id: UUID(),
            conversationId: conversationId,
            role: role,
            content: content,
            timestamp: timestamp
        )
    }

    private static func generateTitle(from messages: [Message]) -> String {
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let content = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.count > 100 {
                return String(content.prefix(100)) + "..."
            }
            return content
        }
        return "Cursor Session"
    }

    private static func extractProjectPath(from dbFile: URL) -> String? {
        // The workspace hash directory might contain workspace.json with the folder path
        let workspaceJson = dbFile.deletingLastPathComponent().appendingPathComponent("workspace.json")
        if let data = try? Data(contentsOf: workspaceJson),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let folder = json["folder"] as? String {
            // folder is usually a file:// URL
            if folder.hasPrefix("file://") {
                return String(folder.dropFirst("file://".count))
            }
            return folder
        }
        return nil
    }
}
