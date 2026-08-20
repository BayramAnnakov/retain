import Foundation
import CryptoKit

/// Parser for Antigravity (CLI & IDE) conversation transcripts
///
/// Storage layout:
/// - Base directories: `~/.gemini/antigravity-cli/`, `~/.gemini/antigravity/`, `~/.gemini/antigravity-ide/`, `~/.antigravity/`
/// - Transcripts: `<base>/brain/<conversation-id>/.system_generated/logs/transcript_full.jsonl` and `transcript.jsonl`
/// - Metadata: `<base>/cache/conversation_metadata.json`, `conversation_summaries.db`, `cache/last_conversations.json`
enum AntigravityParser {

    // MARK: - Candidate Base Directories

    /// Base directories searched for Antigravity conversations (in order of priority)
    static var candidateBaseDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        let relativePaths = [
            ".gemini/antigravity-cli",
            ".gemini/antigravity",
            ".gemini/antigravity-ide",
            ".antigravity",
            "Library/Application Support/Antigravity",
            "Library/Application Support/Antigravity IDE"
        ]

        return relativePaths.compactMap { rel in
            let dir = home.appendingPathComponent(rel)
            return fm.fileExists(atPath: dir.path) ? dir : nil
        }
    }

    /// Primary data directory for Antigravity
    static var primaryDirectory: URL? {
        candidateBaseDirectories.first
    }

    /// Whether Antigravity is detected as installed on the system
    static var isInstalled: Bool {
        if !candidateBaseDirectories.isEmpty {
            return true
        }

        let standardBinaries = [
            "/usr/local/bin/agy",
            "/opt/homebrew/bin/agy",
            "\(NSHomeDirectory())/.local/bin/agy",
            "\(NSHomeDirectory())/.gemini/antigravity-cli/bin/agy",
            "\(NSHomeDirectory())/.gemini/antigravity/bin/agy"
        ]

        return standardBinaries.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Check if a path belongs to an Antigravity conversation directory
    static func isAntigravityPath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let isAntigravityDir = normalized.contains("/.gemini/antigravity") ||
                               normalized.contains("/.antigravity/") ||
                               normalized.contains("/Application Support/Antigravity")
        return isAntigravityDir && (normalized.contains("/brain/") || normalized.contains(".jsonl"))
    }

    // MARK: - Discovered Conversation Model

    struct DiscoveredConversation {
        let conversationId: String
        let fullTranscriptURL: URL?
        let plainTranscriptURL: URL?
        let baseDirectory: URL
        let lastModified: Date

        var preferredURL: URL? {
            fullTranscriptURL ?? plainTranscriptURL
        }
    }

    // MARK: - UUID Validation Regex

    private static let uuidRegex: NSRegularExpression = {
        let pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    // MARK: - Discovery

    /// Discover all valid Antigravity conversations across candidate base directories
    static func discoverConversations() -> [DiscoveredConversation] {
        let fm = FileManager.default
        var discoveredById: [String: DiscoveredConversation] = [:]

        for base in candidateBaseDirectories {
            let brainDir = base.appendingPathComponent("brain")
            guard let children = try? fm.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
                continue
            }

            for child in children {
                let folderName = child.lastPathComponent

                // Validate that the folder name is a valid UUID (excludes tempmediaStorage, .git, etc.)
                let range = NSRange(location: 0, length: folderName.utf16.count)
                guard uuidRegex.firstMatch(in: folderName, options: [], range: range) != nil else {
                    continue
                }

                let logsDir = child.appendingPathComponent(".system_generated/logs")
                let fullURL = logsDir.appendingPathComponent("transcript_full.jsonl")
                let plainURL = logsDir.appendingPathComponent("transcript.jsonl")

                let hasFull = fm.fileExists(atPath: fullURL.path)
                let hasPlain = fm.fileExists(atPath: plainURL.path)

                guard hasFull || hasPlain else { continue }

                let modDateFull = hasFull ? (try? fullURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) : nil
                let modDatePlain = hasPlain ? (try? plainURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) : nil
                let latestMod = [modDateFull, modDatePlain].compactMap { $0 }.max() ?? Date.distantPast

                let item = DiscoveredConversation(
                    conversationId: folderName,
                    fullTranscriptURL: hasFull ? fullURL : nil,
                    plainTranscriptURL: hasPlain ? plainURL : nil,
                    baseDirectory: base,
                    lastModified: latestMod
                )

                // If already discovered from another base directory, keep the one with newer modification date
                if let existing = discoveredById[folderName] {
                    if latestMod > existing.lastModified {
                        discoveredById[folderName] = item
                    }
                } else {
                    discoveredById[folderName] = item
                }
            }
        }

        return Array(discoveredById.values)
    }

    /// Convenience discovery returning all primary transcript file URLs
    static func discoverSessionFiles() -> [URL] {
        return discoverConversations().compactMap { $0.preferredURL }
    }

    // MARK: - Parsing

    /// Raw step record parsed from a JSONL line
    struct RawRecord {
        let stepIndex: Int
        let source: String?
        let type: String?
        let status: String?
        let createdAt: Date?
        let content: String?
        let thinking: String?
        let toolCallsDescription: String?
        let error: String?
        let isFullTranscript: Bool
    }

    /// Parse a discovered conversation by merging both `transcript.jsonl` (full step history)
    /// and `transcript_full.jsonl` (untruncated rolling window content).
    static func parseConversation(_ discovered: DiscoveredConversation) -> (Conversation, [Message])? {
        var plainRecords: [RawRecord] = []
        var fullRecords: [RawRecord] = []

        if let plainURL = discovered.plainTranscriptURL {
            plainRecords = parseTranscriptFile(at: plainURL, isFullTranscript: false)
        }
        if let fullURL = discovered.fullTranscriptURL {
            fullRecords = parseTranscriptFile(at: fullURL, isFullTranscript: true)
        }

        guard !plainRecords.isEmpty || !fullRecords.isEmpty else { return nil }

        // Merge two passes by step_index
        let mergedRecords = mergeRecords(plain: plainRecords, full: fullRecords)
        guard !mergedRecords.isEmpty else { return nil }

        // Load cached metadata (Preview, Title, WorkspaceURIs, etc.)
        let metadata = loadMetadata(for: discovered.conversationId)

        return buildConversation(
            conversationIdString: discovered.conversationId,
            records: mergedRecords,
            metadata: metadata
        )
    }

    /// Parse a single session file (or its parent conversation directory)
    static func parseSession(at url: URL) -> (Conversation, [Message])? {
        let path = url.path

        // Extract conversation UUID from path
        let parts = path.components(separatedBy: "/brain/")
        if parts.count >= 2 {
            let subPath = parts[1]
            let convId = subPath.components(separatedBy: "/")[0]
            let range = NSRange(location: 0, length: convId.utf16.count)
            if uuidRegex.firstMatch(in: convId, options: [], range: range) != nil {
                let baseDir = URL(fileURLWithPath: parts[0])
                let logsDir = baseDir.appendingPathComponent("brain/\(convId)/.system_generated/logs")
                let fullURL = logsDir.appendingPathComponent("transcript_full.jsonl")
                let plainURL = logsDir.appendingPathComponent("transcript.jsonl")
                let fm = FileManager.default

                let discovered = DiscoveredConversation(
                    conversationId: convId,
                    fullTranscriptURL: fm.fileExists(atPath: fullURL.path) ? fullURL : nil,
                    plainTranscriptURL: fm.fileExists(atPath: plainURL.path) ? plainURL : nil,
                    baseDirectory: baseDir,
                    lastModified: Date()
                )
                return parseConversation(discovered)
            }
        }

        // Fallback: parse single file standalone
        let isFull = url.lastPathComponent.contains("full")
        let records = parseTranscriptFile(at: url, isFullTranscript: isFull)
        guard !records.isEmpty else { return nil }

        let convId = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return buildConversation(conversationIdString: convId, records: records, metadata: nil)
    }

    /// Parse raw Data content (useful for unit testing)
    static func parseData(_ data: Data, conversationId: String = UUID().uuidString, isFull: Bool = true) -> (Conversation, [Message])? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        let records = parseLines(content.components(separatedBy: .newlines), isFullTranscript: isFull)
        guard !records.isEmpty else { return nil }
        return buildConversation(conversationIdString: conversationId, records: records, metadata: nil)
    }

    // MARK: - Tolerant Line Reader & Parser

    /// Parses a transcript file into RawRecord objects with tolerant buffering for multiline JSON records
    static func parseTranscriptFile(at url: URL, isFullTranscript: Bool) -> [RawRecord] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let lines = content.components(separatedBy: .newlines)
        return parseLines(lines, isFullTranscript: isFullTranscript)
    }

    /// Sanitizes candidate JSON string by escaping unescaped literal newlines and control characters inside string literals
    static func sanitizeJSON(_ str: String) -> String {
        if let data = str.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            return str
        }

        var result = ""
        var inString = false
        var isEscaped = false

        for char in str {
            if char == "\"" && !isEscaped {
                inString.toggle()
                result.append(char)
            } else if inString && char == "\n" && !isEscaped {
                result.append("\\n")
            } else if inString && char == "\r" && !isEscaped {
                result.append("\\r")
            } else if inString && char == "\t" && !isEscaped {
                result.append("\\t")
            } else {
                result.append(char)
            }

            if char == "\\" && !isEscaped {
                isEscaped = true
            } else {
                isEscaped = false
            }
        }
        return result
    }

    /// Tolerant parser that buffers lines when multiline strings or JSON fragments occur
    static func parseLines(_ lines: [String], isFullTranscript: Bool) -> [RawRecord] {
        var records: [RawRecord] = []
        var buffer = ""
        var bufferLineCount = 0
        let maxBufferLines = 64

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let candidateJSON: String
            if buffer.isEmpty {
                candidateJSON = trimmed
            } else {
                buffer.append("\n" + trimmed)
                candidateJSON = buffer
            }

            let sanitized = sanitizeJSON(candidateJSON)
            guard let lineData = sanitized.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                // Decode failed: buffer and retry on next line (unless buffer exceeded)
                if buffer.isEmpty {
                    buffer = trimmed
                    bufferLineCount = 1
                } else {
                    bufferLineCount += 1
                    if bufferLineCount > maxBufferLines {
                        buffer = ""
                        bufferLineCount = 0
                    }
                }
                continue
            }

            // Successfully decoded JSON object, reset buffer
            buffer = ""
            bufferLineCount = 0

            if let record = parseRecordObject(obj, isFullTranscript: isFullTranscript) {
                records.append(record)
            }
        }

        return records
    }

    private static func parseRecordObject(_ obj: [String: Any], isFullTranscript: Bool) -> RawRecord? {
        guard let stepIndex = (obj["step_index"] as? Int) ?? (obj["step_index"] as? Double).map({ Int($0) }) else {
            return nil
        }

        let source = obj["source"] as? String
        let type = obj["type"] as? String
        let status = obj["status"] as? String
        let content = obj["content"] as? String
        let thinking = obj["thinking"] as? String
        let error = obj["error"] as? String

        var createdAt: Date? = nil
        if let tsStr = obj["created_at"] as? String {
            createdAt = parseISO8601(tsStr)
        }

        var toolDesc: String? = nil
        if let toolCalls = obj["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            let names = toolCalls.compactMap { $0["name"] as? String }
            if !names.isEmpty {
                toolDesc = names.joined(separator: ", ")
            }
        }

        return RawRecord(
            stepIndex: stepIndex,
            source: source,
            type: type,
            status: status,
            createdAt: createdAt,
            content: content,
            thinking: thinking,
            toolCallsDescription: toolDesc,
            error: error,
            isFullTranscript: isFullTranscript
        )
    }

    // MARK: - Two-Pass Record Merging

    /// Merges plain transcript (full step range) with full transcript (untruncated content window)
    static func mergeRecords(plain: [RawRecord], full: [RawRecord]) -> [RawRecord] {
        var mergedByStep: [Int: RawRecord] = [:]

        // 1. First populate with plain records
        for record in plain {
            if let existing = mergedByStep[record.stepIndex] {
                // If duplicate step_index in same file: prefer DONE over RUNNING, otherwise later wins
                if existing.status == "RUNNING" && record.status == "DONE" {
                    mergedByStep[record.stepIndex] = record
                } else if existing.status == record.status {
                    mergedByStep[record.stepIndex] = record
                }
            } else {
                mergedByStep[record.stepIndex] = record
            }
        }

        // 2. Overlay with full records (untruncated content wins)
        for record in full {
            if let existing = mergedByStep[record.stepIndex] {
                // Prefer full record's untruncated content, unless full is RUNNING and plain is DONE
                if record.status == "RUNNING" && existing.status == "DONE" {
                    // Keep plain DONE status, but if full has longer content use full content
                    let longerContent = (record.content?.count ?? 0) > (existing.content?.count ?? 0) ? record.content : existing.content
                    mergedByStep[record.stepIndex] = RawRecord(
                        stepIndex: existing.stepIndex,
                        source: existing.source,
                        type: existing.type,
                        status: "DONE",
                        createdAt: existing.createdAt ?? record.createdAt,
                        content: longerContent,
                        thinking: record.thinking ?? existing.thinking,
                        toolCallsDescription: record.toolCallsDescription ?? existing.toolCallsDescription,
                        error: record.error ?? existing.error,
                        isFullTranscript: true
                    )
                } else {
                    mergedByStep[record.stepIndex] = record
                }
            } else {
                mergedByStep[record.stepIndex] = record
            }
        }

        return mergedByStep.values.sorted { $0.stepIndex < $1.stepIndex }
    }

    // MARK: - Cleaning Regular Expressions

    private static let userRequestRegex: NSRegularExpression = {
        let pattern = "<USER_REQUEST>\\s*([\\s\\S]*?)\\s*</USER_REQUEST>"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let unclosedUserRequestRegex: NSRegularExpression = {
        let pattern = "<USER_REQUEST>\\s*([\\s\\S]*)"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let additionalMetadataRegex: NSRegularExpression = {
        let pattern = "<ADDITIONAL_METADATA>[\\s\\S]*?</ADDITIONAL_METADATA>"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let userSettingsChangeRegex: NSRegularExpression = {
        let pattern = "<USER_SETTINGS_CHANGE>[\\s\\S]*?</USER_SETTINGS_CHANGE>"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let systemMessageBlockRegex: NSRegularExpression = {
        let pattern = "<SYSTEM_MESSAGE>[\\s\\S]*?</SYSTEM_MESSAGE>"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Clean and extract user prompt from Antigravity user input wrappers
    static func cleanUserContent(_ raw: String) -> String {
        var text = raw

        // Strip additional metadata blocks
        let metaRange = NSRange(location: 0, length: text.utf16.count)
        text = additionalMetadataRegex.stringByReplacingMatches(in: text, options: [], range: metaRange, withTemplate: "")

        // Strip user settings change blocks
        let settingsRange = NSRange(location: 0, length: text.utf16.count)
        text = userSettingsChangeRegex.stringByReplacingMatches(in: text, options: [], range: settingsRange, withTemplate: "")

        // Strip system message wrappers if embedded
        let sysRange = NSRange(location: 0, length: text.utf16.count)
        text = systemMessageBlockRegex.stringByReplacingMatches(in: text, options: [], range: sysRange, withTemplate: "")

        // Extract content inside <USER_REQUEST>...</USER_REQUEST>
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        if let match = userRequestRegex.firstMatch(in: text, options: [], range: fullRange), match.numberOfRanges > 1 {
            if let swiftRange = Range(match.range(at: 1), in: text) {
                text = String(text[swiftRange])
            }
        } else if let unclosedMatch = unclosedUserRequestRegex.firstMatch(in: text, options: [], range: fullRange), unclosedMatch.numberOfRanges > 1 {
            if let swiftRange = Range(unclosedMatch.range(at: 1), in: text) {
                text = String(text[swiftRange])
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Conversation Construction

    private static func buildConversation(
        conversationIdString: String,
        records: [RawRecord],
        metadata: MetadataSummary?
    ) -> (Conversation, [Message])? {
        let conversationUUID = UUID(uuidString: conversationIdString) ?? deterministicUUID(for: "antigravity:\(conversationIdString)")

        var messages: [Message] = []
        var minTime: Date?
        var maxTime: Date?
        var firstUserPrompt: String?

        for record in records {
            let (role, content, shouldInclude) = mapRoleAndContent(record)
            guard shouldInclude, let finalContent = content, !finalContent.isEmpty else {
                continue
            }

            let timestamp = record.createdAt ?? Date()
            if minTime == nil || timestamp < minTime! { minTime = timestamp }
            if maxTime == nil || timestamp > maxTime! { maxTime = timestamp }

            if role == .user && firstUserPrompt == nil {
                firstUserPrompt = finalContent
            }

            // Message identity: step-keyed to prevent duplicates on RUNNING -> DONE transitions
            let stepKey = "\(conversationIdString):\(record.stepIndex)"
            let messageUUID = deterministicUUID(for: stepKey)

            let message = Message(
                id: messageUUID,
                conversationId: conversationUUID,
                role: role,
                content: finalContent,
                timestamp: timestamp
            )
            messages.append(message)
        }

        guard !messages.isEmpty else { return nil }

        // Title resolution chain: Preview -> Title -> first user prompt -> fallback
        let title = deriveTitle(metadata: metadata, firstUserPrompt: firstUserPrompt, date: minTime ?? Date())

        // Project path resolution
        let projectPath = metadata?.primaryWorkspacePath

        let conversation = Conversation(
            id: conversationUUID,
            provider: .antigravity,
            sourceType: .cli,
            externalId: conversationIdString,
            title: title,
            projectPath: projectPath,
            createdAt: minTime ?? metadata?.updatedAt ?? Date(),
            updatedAt: maxTime ?? metadata?.updatedAt ?? Date(),
            messageCount: messages.count
        )

        return (conversation, messages)
    }

    private static func mapRoleAndContent(_ record: RawRecord) -> (Role, String?, Bool) {
        let typeStr = record.type ?? ""
        let sourceStr = record.source ?? ""

        // 1. Noise types to drop
        switch typeStr {
        case "CONVERSATION_HISTORY", "GENERIC", "EPHEMERAL_MESSAGE", "DIRECTORY_RULES":
            return (.system, nil, false)
        default:
            break
        }

        // 2. User messages
        if typeStr == "USER_INPUT" || sourceStr == "USER_EXPLICIT" {
            let cleaned = cleanUserContent(record.content ?? "")
            return (.user, cleaned, !cleaned.isEmpty)
        }

        // 3. Assistant responses
        if typeStr == "PLANNER_RESPONSE" || sourceStr == "MODEL" {
            if let content = record.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (.assistant, content, true)
            } else if let toolDesc = record.toolCallsDescription {
                return (.assistant, "[Using tool: \(toolDesc)]", true)
            } else if let thinking = record.thinking, !thinking.isEmpty {
                // Keep thinking as secondary fallback if content is completely empty
                return (.assistant, thinking.trimmingCharacters(in: .whitespacesAndNewlines), true)
            }
            return (.assistant, nil, false)
        }

        // 4. Tool executions
        switch typeStr {
        case "RUN_COMMAND", "VIEW_FILE", "LIST_DIRECTORY", "GREP_SEARCH", "SEARCH_WEB", "READ_URL_CONTENT", "CODE_ACTION", "INVOKE_SUBAGENT":
            let body = (record.content ?? record.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (.tool, body, !body.isEmpty)
        default:
            break
        }

        // 5. System messages
        if typeStr == "ERROR_MESSAGE" {
            let errText = record.error ?? record.content ?? "Unknown error"
            return (.system, errText.trimmingCharacters(in: .whitespacesAndNewlines), true)
        }
        if typeStr == "CHECKPOINT" || typeStr == "SYSTEM_MESSAGE" {
            let sysText = (record.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (.system, sysText, !sysText.isEmpty)
        }

        // Default: assistant if content exists
        if let c = record.content, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.assistant, c, true)
        }

        return (.system, nil, false)
    }

    // MARK: - Title & Project Path Derivation

    private static func deriveTitle(metadata: MetadataSummary?, firstUserPrompt: String?, date: Date) -> String {
        // 1. Preview from metadata (human-readable title)
        if let preview = metadata?.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            return preview
        }

        // 2. Title from metadata
        if let title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }

        // 3. First line of first user message
        if let prompt = firstUserPrompt {
            let firstLine = prompt.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? prompt

            if firstLine.count > 100 {
                return String(firstLine.prefix(100)) + "..."
            }
            if !firstLine.isEmpty {
                return firstLine
            }
        }

        // 4. Fallback
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Antigravity Session — \(formatter.string(from: date))"
    }

    // MARK: - Metadata Loader (JSON & SQLite)

    struct MetadataSummary {
        var title: String?
        var preview: String?
        var workspaceURIs: [String]?
        var updatedAt: Date?
        var parentConversationId: String?
        var nestingDepth: Int?

        var primaryWorkspacePath: String? {
            guard let firstURI = workspaceURIs?.first else { return nil }
            return AntigravityParser.decodeWorkspaceURI(firstURI)
        }
    }

    /// Load conversation metadata from `cache/conversation_metadata.json` and `cache/last_conversations.json`
    static func loadMetadata(for conversationId: String) -> MetadataSummary? {
        var summary = MetadataSummary()

        // 1. Try cache/conversation_metadata.json across candidate directories
        for base in candidateBaseDirectories {
            let metaFile = base.appendingPathComponent("cache/conversation_metadata.json")
            guard let data = try? Data(contentsOf: metaFile),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let convs = json["conversations"] as? [String: Any],
                  let convData = convs[conversationId] as? [String: Any],
                  let summaryDict = convData["summary"] as? [String: Any] else {
                continue
            }

            summary.title = summaryDict["Title"] as? String
            summary.preview = summaryDict["Preview"] as? String
            summary.workspaceURIs = summaryDict["WorkspaceURIs"] as? [String]

            if let updatedStr = summaryDict["UpdatedAt"] as? String {
                summary.updatedAt = parseISO8601(updatedStr)
            }

            return summary
        }

        // 2. Try cache/last_conversations.json for workspace mapping
        for base in candidateBaseDirectories {
            let lastConvsFile = base.appendingPathComponent("cache/last_conversations.json")
            guard let data = try? Data(contentsOf: lastConvsFile),
                  let mapping = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                continue
            }

            for (path, id) in mapping where id == conversationId {
                summary.workspaceURIs = [path]
                return summary
            }
        }

        return nil
    }

    /// Convert file:// URI or raw path to clean absolute filesystem path
    static func decodeWorkspaceURI(_ uriString: String) -> String {
        if uriString.hasPrefix("file://") {
            if let url = URL(string: uriString) {
                return url.path
            }
            return uriString.replacingOccurrences(of: "file://", with: "")
        }
        return uriString
    }

    // MARK: - Date Helpers

    /// Tolerant ISO8601 date parser supporting standard format and fractional seconds
    static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()

        // 1. Try with internet date time and fractional seconds
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }

        // 2. Try standard internet date time (Antigravity format: 2026-07-01T09:27:05Z)
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) {
            return date
        }

        // 3. Fallback for date strings with custom timezone format
        let customFormatter = DateFormatter()
        customFormatter.locale = Locale(identifier: "en_US_POSIX")
        customFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd HH:mm:ss.SSSSSS"
        ]

        for format in formats {
            customFormatter.dateFormat = format
            if let date = customFormatter.date(from: string) {
                return date
            }
        }

        return nil
    }

    // MARK: - Deterministic UUID Generator

    /// Generate a deterministic UUID from SHA256 of a string key
    static func deterministicUUID(for key: String) -> UUID {
        let hash = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(hash.prefix(16))

        // Set version to 4 (UUIDv4) and variant to RFC 4122
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let uuidTuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidTuple)
    }
}
