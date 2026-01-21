import Foundation
import Combine

/// Orchestrates LLM analysis through unified queue pipeline
/// ALL backends (CLI, Gemini) go through the same queue for consistency
@MainActor
final class LLMOrchestrator: ObservableObject {

    // MARK: - Backend Types

    enum Backend: String, CaseIterable, Identifiable {
        case claudeCode = "claude_code"
        case codex = "codex"
        case gemini = "gemini"
        case none = "none"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex CLI"
            case .gemini: return "Gemini API"
            case .none: return "None"
            }
        }

        var isCloudBased: Bool {
            self != .none
        }
    }

    // MARK: - Published State

    @Published private(set) var activeBackend: Backend = .none
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisProgress: Double = 0
    @Published private(set) var totalQueuedItems: Int = 0
    @Published private(set) var processedItems: Int = 0
    @Published private(set) var estimatedTimeRemaining: TimeInterval? = nil
    @Published private(set) var lastAnalysisError: String?
    @Published private(set) var availableCLITools: [CLILLMService.DetectedTool] = []

    // MARK: - Dependencies

    /// CLI service for subprocess spawning (internal for config updates)
    let cliService: CLILLMService
    private let queueRepository: AnalysisQueueRepository
    private let resultProcessor: AnalysisResultProcessor
    private let conversationRepository: ConversationRepository

    // Process ID for claim ownership
    private let processId = UUID().uuidString
    private var fullScanActive = false
    private var fullScanStart: Date?

    // Gemini client (lazily initialized with API key)
    private var geminiClient: GeminiClient?

    // MARK: - Init

    init(
        cliService: CLILLMService = CLILLMService(),
        queueRepository: AnalysisQueueRepository = AnalysisQueueRepository(),
        resultProcessor: AnalysisResultProcessor = AnalysisResultProcessor(),
        conversationRepository: ConversationRepository = ConversationRepository()
    ) {
        self.cliService = cliService
        self.queueRepository = queueRepository
        self.resultProcessor = resultProcessor
        self.conversationRepository = conversationRepository
    }

    // MARK: - Configuration

    /// Configure Gemini backend with API key
    func configureGemini(apiKey: String, model: String = "gemini-2.0-flash") {
        let config = GeminiClient.Configuration(apiKey: apiKey, model: model)
        geminiClient = GeminiClient(configuration: config)
    }

    /// Clear Gemini configuration (when disabled or key removed)
    func clearGemini() {
        geminiClient = nil
    }

    /// Check if cloud analysis is allowed
    var isCloudAnalysisAllowed: Bool {
        UserDefaults.standard.bool(forKey: "allowCloudAnalysis")
    }

    // MARK: - Backend Selection

    /// Detect available tools and select best backend
    func selectBackend() async -> Backend {
        // Check user consent first
        guard isCloudAnalysisAllowed else {
            activeBackend = .none
            return .none
        }

        // Detect CLI tools (runs on non-main actor)
        let tools = await cliService.detectAvailableTools()
        availableCLITools = tools

        // 1. Prefer Claude Code if available
        if tools.contains(where: { $0.tool == .claudeCode }) {
            activeBackend = .claudeCode
            return .claudeCode
        }

        // NOTE: Codex CLI is disabled for alpha release (lacks hard no-tools flag)
        // Will not be detected even if Backend.codex exists in enum

        // 2. Fall back to Gemini if configured
        if geminiClient != nil {
            activeBackend = .gemini
            return .gemini
        }

        activeBackend = .none
        return .none
    }

    /// Refresh tool detection
    func refreshToolDetection() async {
        let tools = await cliService.detectAvailableTools()
        availableCLITools = tools
    }

    // MARK: - Queue-Based Analysis (Primary API)

    /// Queue conversations for analysis - detects backend first, then queues
    func queueAnalysis(_ conversationIds: [UUID], type: AnalysisType, priority: Int = 0) async throws {
        // Refuse dedupe upfront - it operates on learnings, not conversations
        // Use runDedupeAnalysis() directly instead
        guard type != .dedupe else {
            throw LLMError.queueError("Dedupe cannot be queued. Use runDedupeAnalysis() directly - it operates on learnings, not conversations.")
        }

        // Detect backend first (fixes fresh start issue)
        let backend = await selectBackend()
        guard backend != .none else {
            throw LLMError.noBackendAvailable("Enable cloud analysis in Settings or configure Gemini API key")
        }

        for conversationId in conversationIds {
            let item = AnalysisQueueItem(
                id: UUID().uuidString,
                conversationId: conversationId,
                analysisType: type.rawValue,
                status: "pending",
                priority: priority,
                attemptCount: 0,
                maxAttempts: 3,
                schemaVersion: 1,
                createdAt: Date()
            )
            try queueRepository.insert(item)
        }
    }

    /// Queue a single conversation for analysis
    func queueAnalysis(_ conversationId: UUID, type: AnalysisType, priority: Int = 0) async throws {
        try await queueAnalysis([conversationId], type: type, priority: priority)
    }

    // MARK: - Queue Processing

    /// Process pending queue items using selected backend
    /// Called periodically or on-demand
    func processQueue(batchSize: Int = 10) async throws {
        isAnalyzing = true
        lastAnalysisError = nil
        analysisProgress = 0
        defer {
            isAnalyzing = false
            analysisProgress = 0
        }

        try await processQueueBatch(batchSize: batchSize, updateProgress: true)
    }

    private func processQueueBatch(batchSize: Int, updateProgress: Bool) async throws {
        let backend = await selectBackend()
        guard backend != .none else {
            throw LLMError.noBackendAvailable("No backend available")
        }

        // Claim items atomically
        let claimedItems = try queueRepository.claimPendingItems(count: batchSize, claimedBy: processId)
        guard !claimedItems.isEmpty else { return }

        // Group by analysis type for batching
        let grouped = Dictionary(grouping: claimedItems) { $0.analysisType }
        let totalGroups = grouped.count
        var processedGroups = 0

        for (analysisTypeStr, items) in grouped {
            guard let analysisType = AnalysisType(rawValue: analysisTypeStr) else {
                // Mark items as failed for unknown type
                for item in items {
                    try? queueRepository.markFailed(id: item.id, error: "Unknown analysis type: \(analysisTypeStr)")
                }
                continue
            }

            // Pre-LLM guard: Short-circuit dedupe items that may exist from before the fix
            // Dedupe operates on learnings, not conversations - use runDedupeAnalysis() directly
            if analysisType == .dedupe {
                for item in items {
                    try? queueRepository.markFailed(
                        id: item.id,
                        error: "Dedupe cannot be processed via queue. Use runDedupeAnalysis() directly."
                    )
                }
                continue  // Skip to next type group without fetching data or calling LLM
            }

            // Fetch conversation data for this batch
            let conversationIds = items.map { $0.conversationId }
            let conversations = try await prepareConversationData(conversationIds)

            do {
                let resultJSON: String
                var includedItems = items  // Items actually sent to LLM

                switch backend {
                case .claudeCode, .codex:
                    let cliResult = try await processCLIBatch(
                        items: items,
                        conversations: conversations,
                        type: analysisType,
                        backend: backend
                    )
                    resultJSON = cliResult.jsonOutput

                    // Mark dropped items due to truncation with specific reason
                    for item in items where cliResult.droppedQueueIds.contains(item.id) {
                        try? queueRepository.markFailed(
                            id: item.id,
                            error: "Conversation dropped due to context window truncation"
                        )
                    }

                    // Only process items that were actually included
                    includedItems = items.filter { cliResult.includedQueueIds.contains($0.id) }

                case .gemini:
                    resultJSON = try await processGeminiBatch(
                        items: items,
                        conversations: conversations,
                        type: analysisType
                    )

                case .none:
                    throw LLMError.noBackendAvailable("Backend became unavailable")
                }

                // Parse batch results and map to individual queue items (only included ones)
                try mapBatchResultsToQueueItems(
                    resultJSON: resultJSON,
                    items: includedItems,
                    analysisType: analysisType,
                    backend: backend
                )

            } catch {
                // Mark items as failed
                for item in items {
                    try? queueRepository.markFailed(id: item.id, error: error.localizedDescription)
                }
                lastAnalysisError = error.localizedDescription
            }

            if updateProgress {
                processedGroups += 1
                analysisProgress = Double(processedGroups) / Double(totalGroups)
            }
        }

        // Process completed items to persist results
        _ = try? resultProcessor.processAllUnprocessed()
    }

    // MARK: - Backend-Specific Processing

    /// Result from CLI processing with separate tracking for truncated items
    struct CLIBatchResult {
        let jsonOutput: String
        let includedQueueIds: Set<String>
        let droppedQueueIds: Set<String>
    }

    private func processCLIBatch(
        items: [AnalysisQueueItem],
        conversations: [ConversationData],
        type: AnalysisType,
        backend: Backend
    ) async throws -> CLIBatchResult {
        // Only Claude Code is supported for alpha (Codex disabled - lacks hard no-tools flag)
        guard backend == .claudeCode else {
            throw LLMError.noBackendAvailable("Codex CLI is disabled for alpha release (security)")
        }

        guard let tool = availableCLITools.first(where: { $0.tool == .claudeCode }) else {
            throw LLMError.toolNotFound
        }

        let conversationMap = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        func runSingleBatch(_ batchItems: [AnalysisQueueItem]) async throws -> CLIBatchResult {
            let batchConversations = batchItems.compactMap { conversationMap[$0.conversationId.uuidString] }
            let result = try await cliService.runAnalysis(
                tool: tool.tool,
                queueItems: batchItems,
                conversations: batchConversations,
                analysisType: type
            )

            return CLIBatchResult(
                jsonOutput: result.jsonOutput,
                includedQueueIds: result.includedQueueIds,
                droppedQueueIds: result.droppedQueueIds
            )
        }

        func mergeJSONArrays(_ arrays: [String]) throws -> String {
            var merged: [Any] = []
            for array in arrays {
                let trimmed = array.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
                let parsed = try JSONSerialization.jsonObject(with: data)
                if let list = parsed as? [Any] {
                    merged.append(contentsOf: list)
                } else if let item = parsed as? [String: Any] {
                    merged.append(item)
                }
            }
            let data = try JSONSerialization.data(withJSONObject: merged)
            return String(data: data, encoding: .utf8) ?? "[]"
        }

        func runWithSplit(_ batchItems: [AnalysisQueueItem]) async throws -> CLIBatchResult {
            do {
                return try await runSingleBatch(batchItems)
            } catch let error as CLILLMService.CLIError {
                if case .payloadTooLarge = error, batchItems.count > 1 {
                    let mid = batchItems.count / 2
                    let firstItems = Array(batchItems.prefix(mid))
                    let secondItems = Array(batchItems.suffix(from: mid))
                    let firstResult = try await runWithSplit(firstItems)
                    let secondResult = try await runWithSplit(secondItems)
                    let mergedJSON = try mergeJSONArrays([firstResult.jsonOutput, secondResult.jsonOutput])
                    return CLIBatchResult(
                        jsonOutput: mergedJSON,
                        includedQueueIds: firstResult.includedQueueIds.union(secondResult.includedQueueIds),
                        droppedQueueIds: firstResult.droppedQueueIds.union(secondResult.droppedQueueIds)
                    )
                }
                throw error
            }
        }

        return try await runWithSplit(items)
    }

    private func processGeminiBatch(
        items: [AnalysisQueueItem],
        conversations: [ConversationData],
        type: AnalysisType
    ) async throws -> String {
        guard let gemini = geminiClient else {
            throw LLMError.noBackendAvailable("Gemini not configured")
        }

        // Truncate conversations to fit within Gemini context (100k tokens)
        let truncatedConversations = truncateForGemini(conversations, maxTokens: 100_000)

        // Filter queue items to match surviving conversations (fix truncation alignment)
        let survivingConvoIds = Set(truncatedConversations.map { $0.id })
        let includedItems = items.filter { survivingConvoIds.contains($0.conversationId.uuidString) }

        // Mark dropped items as failed with specific reason
        let droppedItems = items.filter { !survivingConvoIds.contains($0.conversationId.uuidString) }
        for item in droppedItems {
            try? queueRepository.markFailed(
                id: item.id,
                error: "Conversation dropped due to context window truncation"
            )
        }

        // Apply PII redaction (same as CLI path)
        let redactedConversations = redactSensitiveData(truncatedConversations)

        // Build prompt for Gemini with only included items and redacted data
        let prompt = buildGeminiPrompt(for: type, conversations: redactedConversations, items: includedItems)
        let schema = buildGeminiSchema(for: type)

        // Call Gemini API
        let response = try await gemini.generateStructuredContent(prompt: prompt, schema: schema)
        return response
    }

    /// Redact sensitive data before sending to LLM (email, phone, API keys, tokens)
    private func redactSensitiveData(_ convos: [ConversationData]) -> [ConversationData] {
        convos.map { convo in
            var redacted = convo
            redacted.messages = convo.messages.map { msg in
                var m = msg
                m.content = m.content
                    // Email addresses
                    .replacingOccurrences(of: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b"#, with: "[EMAIL]", options: .regularExpression)
                    // Phone numbers (US format)
                    .replacingOccurrences(of: #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#, with: "[PHONE]", options: .regularExpression)
                    // OpenAI API keys
                    .replacingOccurrences(of: #"sk-[a-zA-Z0-9]{20,}"#, with: "[API_KEY]", options: .regularExpression)
                    // GitHub tokens
                    .replacingOccurrences(of: #"ghp_[a-zA-Z0-9]{36}"#, with: "[GITHUB_TOKEN]", options: .regularExpression)
                    // Anthropic API keys
                    .replacingOccurrences(of: #"sk-ant-[a-zA-Z0-9-]{20,}"#, with: "[ANTHROPIC_KEY]", options: .regularExpression)
                return m
            }
            return redacted
        }
    }

    /// Truncate conversations to fit within Gemini context window
    private func truncateForGemini(_ convos: [ConversationData], maxTokens: Int) -> [ConversationData] {
        var result: [ConversationData] = []
        var totalTokens = 0
        let tokensPerChar = 0.25 // Rough estimate

        for convo in convos {
            var truncated = convo
            let convoTokens = Int(Double(convo.estimatedCharCount) * tokensPerChar)

            // If this conversation would exceed limit and has many messages, truncate it
            if totalTokens + convoTokens > maxTokens && convo.messages.count > 10 {
                // Keep first message + last 9 messages
                truncated.messages = [convo.messages[0]] + Array(convo.messages.suffix(9))
                truncated.wasTruncated = true
            }

            result.append(truncated)
            totalTokens += Int(Double(truncated.estimatedCharCount) * tokensPerChar)

            // Stop adding conversations if we've hit the limit
            if totalTokens >= maxTokens { break }
        }

        return result
    }

    // MARK: - JSONL Parsing (for Codex)

    /// Parse JSONL (newline-delimited JSON) into array
    /// Codex with --json flag emits JSONL, not a single JSON array
    /// Uses try? to skip non-result lines (progress, metadata, etc.)
    private func parseJSONL<T: Decodable>(_ jsonl: String, as type: T.Type) -> [T] {
        let lines = jsonl.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.hasPrefix("{") }  // Only lines that look like JSON objects

        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else {
                return nil
            }
            // Use try? to silently skip non-result lines (progress, metadata, errors)
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }

    // MARK: - Batch Result Mapping

    /// Parse batch results array and map each result to its queue item by queue_id
    /// Handles both JSON array (Claude Code, Gemini) and JSONL (Codex)
    private func mapBatchResultsToQueueItems(
        resultJSON: String,
        items: [AnalysisQueueItem],
        analysisType: AnalysisType,
        backend: Backend
    ) throws {
        // Determine if we need to parse JSONL (Codex) or standard JSON array
        let jsonData: Data
        if backend == .codex {
            // Codex emits JSONL - parse lines and check if we got valid objects
            // If only one line that looks like an array, it might be JSON array format
            let trimmed = resultJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                // Actually a JSON array, parse normally
                guard let data = trimmed.data(using: .utf8) else {
                    throw LLMError.invalidResponse
                }
                jsonData = data
            } else {
                // True JSONL - parse each line and re-encode as array
                // This is type-specific, so we handle in each case below
                jsonData = Data() // Placeholder, handled per-type
            }
        } else {
            guard let data = resultJSON.data(using: .utf8) else {
                throw LLMError.invalidResponse
            }
            jsonData = data
        }

        // Create lookup for queue items by ID
        let itemLookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var matchedItems = Set<String>()

        // Check if this is Codex JSONL that needs special parsing
        let isCodexJSONL = backend == .codex && !resultJSON.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")

        switch analysisType {
        case .workflow:
            let batchResults: [WorkflowBatchResult]
            if isCodexJSONL {
                batchResults = parseJSONL(resultJSON, as: WorkflowBatchResult.self)
            } else {
                batchResults = try JSONDecoder().decode([WorkflowBatchResult].self, from: jsonData)
            }
            for result in batchResults {
                guard itemLookup[result.queueId] != nil else { continue }
                let itemJSON = try result.toResultJSON()
                try queueRepository.markCompleted(
                    id: result.queueId,
                    resultJSON: itemJSON,
                    backend: backend.rawValue,
                    model: getModelName(for: backend)
                )
                matchedItems.insert(result.queueId)
            }

        case .learning:
            let batchResults: [LearningBatchResult]
            if isCodexJSONL {
                batchResults = parseJSONL(resultJSON, as: LearningBatchResult.self)
            } else {
                batchResults = try JSONDecoder().decode([LearningBatchResult].self, from: jsonData)
            }
            for result in batchResults {
                guard itemLookup[result.queueId] != nil else { continue }
                let itemJSON = try result.toResultJSON()
                try queueRepository.markCompleted(
                    id: result.queueId,
                    resultJSON: itemJSON,
                    backend: backend.rawValue,
                    model: getModelName(for: backend)
                )
                matchedItems.insert(result.queueId)
            }

        case .summary:
            let batchResults: [SummaryBatchResult]
            if isCodexJSONL {
                batchResults = parseJSONL(resultJSON, as: SummaryBatchResult.self)
            } else {
                batchResults = try JSONDecoder().decode([SummaryBatchResult].self, from: jsonData)
            }
            for result in batchResults {
                guard itemLookup[result.queueId] != nil else { continue }
                let itemJSON = try result.toResultJSON()
                try queueRepository.markCompleted(
                    id: result.queueId,
                    resultJSON: itemJSON,
                    backend: backend.rawValue,
                    model: getModelName(for: backend)
                )
                matchedItems.insert(result.queueId)
            }

        case .dedupe:
            // Dedupe is refused at queueAnalysis() entry point, so this should never be reached
            // If somehow we get here (e.g., manual DB insert), mark as failed immediately
            for item in items {
                try? queueRepository.markFailed(
                    id: item.id,
                    error: "Dedupe cannot be processed via queue. Use runDedupeAnalysis() directly."
                )
            }
            return  // Skip the unmatched items check
        }

        // Mark any unmatched items as failed
        for item in items where !matchedItems.contains(item.id) {
            try? queueRepository.markFailed(id: item.id, error: "No result returned for this queue item")
        }
    }

    // MARK: - Data Preparation

    private func prepareConversationData(_ ids: [UUID]) async throws -> [ConversationData] {
        try await Task.detached { [conversationRepository] in
            ids.compactMap { id -> ConversationData? in
                guard let convo = try? conversationRepository.fetch(id: id),
                      let messages = try? conversationRepository.fetchMessages(conversationId: id) else {
                    return nil
                }
                return ConversationData(
                    id: convo.id.uuidString,
                    title: convo.title,
                    messages: messages.map { MessageData(id: $0.id.uuidString, role: $0.role.rawValue, content: $0.content) }
                )
            }
        }.value
    }

    // MARK: - Prompt Building

    private func buildGeminiPrompt(for type: AnalysisType, conversations: [ConversationData], items: [AnalysisQueueItem]) -> String {
        // Build queue item mapping
        let queueItemsMapping = items.map { item in
            ["queue_id": item.id, "conversation_id": item.conversationId.uuidString]
        }
        let queueItemsJSON = (try? JSONEncoder().encode(queueItemsMapping)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let conversationsJSON = try? JSONEncoder().encode(conversations)
        let conversationsString = conversationsJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let baseInstruction = """
        You are analyzing conversations for an AI assistant.

        Queue Items (each maps a queue_id to a conversation_id):
        \(queueItemsJSON)

        Conversations:
        \(conversationsString)

        IMPORTANT: For EACH queue item, produce a result object with the matching queue_id.
        Return a JSON ARRAY with one result per queue item.
        """

        switch type {
        case .workflow:
            return """
            \(baseInstruction)

            Analyze each conversation for automation workflow candidates.
            Look for repetitive patterns that could be automated.

            Output format: [{"queue_id": "<id>", "action": "...", "confidence": 0.8, ...}, ...]
            """

        case .learning:
            return """
            \(baseInstruction)

            Extract learning patterns and corrections from each conversation.
            Look for user corrections, preferences, and implicit learnings.

            Output format: [{"queue_id": "<id>", "learnings": [{"type": "...", "rule": "...", "confidence": 0.8}, ...]}, ...]
            """

        case .summary:
            return """
            \(baseInstruction)

            Generate a concise title and summary for each conversation.
            Focus on the main topic and key outcomes.

            Output format: [{"queue_id": "<id>", "suggested_title": "...", "confidence": 0.8, ...}, ...]
            """

        case .dedupe:
            return """
            \(baseInstruction)

            Identify duplicate or similar learnings that could be merged.
            Look for rules that express the same preference in different words.

            Output format: [{"queue_id": "<id>", "merge_suggestions": [{"source_ids": [...], "merged_rule": "...", "confidence": 0.8}, ...]}, ...]
            """
        }
    }

    private func buildGeminiSchema(for type: AnalysisType) -> [String: Any] {
        // All schemas return arrays with queue_id for per-item mapping
        switch type {
        case .workflow:
            return [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "queue_id": ["type": "string"],
                        "action": ["type": "string"],
                        "artifact": ["type": "string"],
                        "domains": ["type": "array", "items": ["type": "string"]],
                        "confidence": ["type": "number"],
                        "reasoning": ["type": "string"]
                    ],
                    "required": ["queue_id", "action", "confidence"]
                ]
            ]

        case .learning:
            return [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "queue_id": ["type": "string"],
                        "learnings": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "type": ["type": "string"],
                                    "rule": ["type": "string"],
                                    "confidence": ["type": "number"],
                                    "pattern": ["type": "string"]
                                ],
                                "required": ["type", "rule", "confidence"]
                            ]
                        ]
                    ],
                    "required": ["queue_id", "learnings"]
                ]
            ]

        case .summary:
            return [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "queue_id": ["type": "string"],
                        "suggested_title": ["type": "string"],
                        "suggested_summary": ["type": "string"],
                        "confidence": ["type": "number"]
                    ],
                    "required": ["queue_id", "suggested_title", "confidence"]
                ]
            ]

        case .dedupe:
            return [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "queue_id": ["type": "string"],
                        "merge_suggestions": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "source_ids": ["type": "array", "items": ["type": "string"]],
                                    "merged_rule": ["type": "string"],
                                    "confidence": ["type": "number"],
                                    "reasoning": ["type": "string"]
                                ],
                                "required": ["source_ids", "merged_rule", "confidence"]
                            ]
                        ]
                    ],
                    "required": ["queue_id", "merge_suggestions"]
                ]
            ]
        }
    }

    private func getModelName(for backend: Backend) -> String {
        switch backend {
        case .claudeCode: return "claude-sonnet-4-5-20250929"
        case .codex: return "codex-latest"
        case .gemini: return "gemini-2.0-flash"
        case .none: return "none"
        }
    }

    // MARK: - Dedupe Analysis (Learnings-Based)

    /// Lightweight learning data for dedupe analysis
    struct LearningData: Codable {
        let id: String
        var rule: String
        let type: String
        let confidence: Float
    }

    /// Redact sensitive data from learning rules before sending to CLI
    /// Uses same patterns as CLILLMService.redactSensitiveData for conversation data
    private func redactLearningData(_ learnings: [LearningData]) -> [LearningData] {
        learnings.map { learning in
            var redacted = learning
            redacted.rule = learning.rule
                // Email addresses
                .replacingOccurrences(of: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b"#, with: "[EMAIL]", options: .regularExpression)
                // Phone numbers
                .replacingOccurrences(of: #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#, with: "[PHONE]", options: .regularExpression)
                // OpenAI API keys
                .replacingOccurrences(of: #"sk-[a-zA-Z0-9]{20,}"#, with: "[API_KEY]", options: .regularExpression)
                // GitHub tokens
                .replacingOccurrences(of: #"ghp_[a-zA-Z0-9]{36}"#, with: "[GITHUB_TOKEN]", options: .regularExpression)
                // AWS access keys
                .replacingOccurrences(of: #"AKIA[A-Z0-9]{16}"#, with: "[AWS_ACCESS_KEY]", options: .regularExpression)
                // SSH private keys
                .replacingOccurrences(of: #"-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"#, with: "[SSH_KEY_REDACTED]", options: .regularExpression)
                // Generic passwords in common patterns
                .replacingOccurrences(of: #"(?i)(password|passwd|pwd)\s*[:=]\s*\S+"#, with: "[PASSWORD_REDACTED]", options: .regularExpression)
            return redacted
        }
    }

    /// Run dedupe analysis on existing learnings (not conversation-based)
    /// Returns merge suggestions with real learning IDs
    func runDedupeAnalysis() async throws -> [MergeSuggestion] {
        let backend = await selectBackend()
        guard backend != .none else {
            throw LLMError.noBackendAvailable("No backend available for dedupe analysis")
        }

        let learningRepository = LearningRepository()

        // Fetch all non-rejected learnings
        let learnings = try learningRepository.fetchAll().filter { $0.status != .rejected }

        // Need at least 2 learnings to dedupe
        guard learnings.count >= 2 else {
            return []
        }

        // Convert to lightweight data for LLM
        let learningData = learnings.map { learning in
            LearningData(
                id: learning.id.uuidString,
                rule: learning.extractedRule,
                type: learning.type.rawValue,
                confidence: learning.confidence
            )
        }

        // Build dedupe prompt with actual learning data
        let prompt = buildDedupePrompt(learnings: learningData)

        // Execute based on backend
        let resultJSON: String
        switch backend {
        case .claudeCode, .codex:
            // For CLI, we need to write learnings to a temp file
            resultJSON = try await runCLIDedupeAnalysis(learnings: learningData, backend: backend)

        case .gemini:
            guard let gemini = geminiClient else {
                throw LLMError.noBackendAvailable("Gemini not configured")
            }
            let schema = buildDedupeOnlySchema()
            resultJSON = try await gemini.generateStructuredContent(prompt: prompt, schema: schema)

        case .none:
            throw LLMError.noBackendAvailable("No backend available")
        }

        // Parse response
        guard let jsonData = resultJSON.data(using: .utf8) else {
            throw LLMError.invalidResponse
        }

        let result = try JSONDecoder().decode(DedupeAnalysisResult.self, from: jsonData)
        return result.mergeSuggestions
    }

    /// Run CLI-based dedupe analysis with learning data
    /// Uses secure STDIN input pattern (no file path injection)
    private func runCLIDedupeAnalysis(learnings: [LearningData], backend: Backend) async throws -> String {
        // Only Claude Code supported for alpha (Codex disabled - lacks hard no-tools flag)
        guard backend == .claudeCode else {
            throw LLMError.noBackendAvailable("Codex CLI is disabled for alpha release (security)")
        }

        guard let tool = availableCLITools.first(where: { $0.tool == .claudeCode }) else {
            throw LLMError.toolNotFound
        }

        // Check consent (matches CLILLMService.runAnalysis)
        guard UserDefaults.standard.bool(forKey: "allowCloudAnalysis") else {
            throw LLMError.noBackendAvailable("Cloud analysis consent not granted")
        }

        // Apply redaction to learning rules before encoding (matches CLILLMService policy)
        let redactedLearnings = redactLearningData(learnings)

        // Prepare input data for STDIN (secure - no file path in prompt)
        let inputData = try JSONEncoder().encode(redactedLearnings)

        // Size cap check (matches CLILLMService.maxPayloadSize)
        let maxPayloadSize = 500_000  // 500KB limit for STDIN
        guard inputData.count <= maxPayloadSize else {
            throw LLMError.queueError("Dedupe payload too large: \(inputData.count) bytes (max \(maxPayloadSize))")
        }

        guard let inputJSON = String(data: inputData, encoding: .utf8) else {
            throw LLMError.queueError("Failed to encode learnings")
        }

        let prompt = """
        Analyze the following learning data for duplicates or similar rules.
        Identify learnings that express the same preference in different words.
        Return merge suggestions with the actual learning IDs from the input.

        Output format: {"merge_suggestions": [{"source_ids": ["id1", "id2"], "merged_rule": "...", "confidence": 0.8, "reasoning": "..."}]}

        ---INPUT DATA---
        \(inputJSON)
        """

        // Build secure CLI args (no tools, STDIN input)
        var args = [
            "-p",                           // Non-interactive print mode
            "--tools", "",                  // Disable ALL tools (CRITICAL for security)
            "--output-format", "json",      // Enforce JSON output
            "--input-format", "text"        // STDIN input format
        ]
        // Only add --no-session-persistence if the CLI version supports it
        if tool.capabilities.supportsNoSessionPersistence {
            args += ["--no-session-persistence"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.path)
        process.arguments = args

        // Force non-interactive mode via environment
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_NO_INTERACTIVE"] = "1"
        env["CI"] = "true"
        env["TERM"] = "dumb"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write prompt to stdin and close
        if let data = prompt.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // CRITICAL: Start reading pipes BEFORE waitUntilExit to prevent buffer deadlock
        // If CLI output exceeds ~64KB pipe buffer, process blocks waiting to write,
        // parent blocks in waitUntilExit = deadlock until timeout
        let stdoutReadTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrReadTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // ENFORCE timeout with process termination (300s = 5 min)
        // Use Task.detached to avoid blocking MainActor
        let timeoutSeconds: UInt64 = 300
        let (completed, exitStatus) = await Task.detached { () -> (Bool, Int32) in
            let completionResult = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    process.waitUntilExit()
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                    return false
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
            return (completionResult, process.terminationStatus)
        }.value

        if !completed {
            process.terminate()
            // Hard kill after 5s grace period if terminate is ignored
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // Still await pipe reads to clean up
            _ = await stdoutReadTask.value
            _ = await stderrReadTask.value
            throw LLMError.analysisTimeout
        }

        // Await pipe reads (now safe since process exited)
        let stdoutData = await stdoutReadTask.value
        let stderrData = await stderrReadTask.value

        guard exitStatus == 0 else {
            let errorOutput = String(data: stderrData, encoding: .utf8) ?? ""
            throw LLMError.queueError("CLI dedupe failed with status \(exitStatus): \(errorOutput)")
        }

        guard !stdoutData.isEmpty else {
            throw LLMError.invalidResponse
        }

        // Parse Claude CLI wrapper (--output-format json returns wrapper object)
        guard let wrapper = try? JSONDecoder().decode(CLILLMService.ClaudeCLIWrapper.self, from: stdoutData) else {
            throw LLMError.invalidResponse
        }

        if wrapper.is_error == true {
            throw LLMError.queueError("CLI error: \(wrapper.error ?? "Unknown")")
        }

        guard let resultString = wrapper.result else {
            throw LLMError.invalidResponse
        }

        return resultString
    }

    /// Build dedupe prompt with learning data
    private func buildDedupePrompt(learnings: [LearningData]) -> String {
        let learningsJSON = (try? JSONEncoder().encode(learnings)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return """
        Analyze these learnings for duplicates or similar rules that could be merged.
        Look for rules that express the same preference in different words.

        Learnings:
        \(learningsJSON)

        For each group of similar learnings, provide:
        - source_ids: Array of learning IDs to merge (use the exact IDs from input)
        - merged_rule: The combined/unified rule
        - confidence: How confident the merge is appropriate (0.0-1.0)
        - reasoning: Why these learnings should be merged

        Return: {"merge_suggestions": [...]}
        """
    }

    /// Build schema for dedupe-only analysis (not per-item batch)
    private func buildDedupeOnlySchema() -> [String: Any] {
        return [
            "type": "object",
            "properties": [
                "merge_suggestions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "source_ids": ["type": "array", "items": ["type": "string"]],
                            "merged_rule": ["type": "string"],
                            "confidence": ["type": "number"],
                            "reasoning": ["type": "string"]
                        ],
                        "required": ["source_ids", "merged_rule", "confidence"]
                    ]
                ]
            ],
            "required": ["merge_suggestions"]
        ]
    }

    // MARK: - Convenience Methods

    /// Analyze a single conversation with specified types
    /// Note: Dedupe is excluded from defaults - use runDedupeAnalysis() directly
    func analyzeConversation(_ conversationId: UUID, types: [AnalysisType] = [.workflow, .learning, .summary]) async throws {
        for type in types {
            try await queueAnalysis(conversationId, type: type)
        }
        try await processQueue()
    }

    /// Run a full scan across all conversations and persist results
    /// Uses CLI backend when available (optionally required).
    func runFullScan(
        types: [AnalysisType] = [.learning, .workflow],
        batchSize: Int = 10,
        requireCLI: Bool = false,
        scope: ScanScope = .all
    ) async throws {
        let backend = await selectBackend()
        if requireCLI, backend != .claudeCode {
            throw LLMError.noBackendAvailable("Claude CLI is required for this scan")
        }

        let conversations = try await Task.detached { [conversationRepository] in
            try conversationRepository.fetchAll()
        }.value

        let now = Date()
        let filteredConversations = conversations.filter { conversation in
            if let days = scope.timeWindowDays {
                let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                if conversation.updatedAt < cutoff {
                    return false
                }
            }

            if let projectPath = scope.projectPath {
                if conversation.projectPath != projectPath {
                    return false
                }
            }

            if !scope.providers.isEmpty, !scope.providers.contains(conversation.provider) {
                return false
            }

            return true
        }

        let conversationIds = filteredConversations.map { $0.id }
        guard !conversationIds.isEmpty else { return }

        fullScanActive = true
        fullScanStart = Date()
        totalQueuedItems = conversationIds.count * types.filter { $0 != .dedupe }.count
        processedItems = 0
        analysisProgress = 0
        estimatedTimeRemaining = nil
        isAnalyzing = true

        defer {
            fullScanActive = false
            fullScanStart = nil
            isAnalyzing = false
            analysisProgress = 0
            totalQueuedItems = 0
            processedItems = 0
            estimatedTimeRemaining = nil
        }

        for type in types where type != .dedupe {
            try await queueAnalysis(conversationIds, type: type)
        }

        while try getPendingCount() > 0 {
            try await processQueueBatch(batchSize: batchSize, updateProgress: false)
            updateFullScanProgress(pendingCount: try getPendingCount())
        }
    }

    private func updateFullScanProgress(pendingCount: Int) {
        guard fullScanActive, totalQueuedItems > 0 else { return }
        processedItems = max(0, totalQueuedItems - pendingCount)
        analysisProgress = min(1, Double(processedItems) / Double(totalQueuedItems))

        guard let start = fullScanStart, processedItems > 0 else {
            estimatedTimeRemaining = nil
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        let rate = Double(processedItems) / max(elapsed, 1)
        let remaining = Double(totalQueuedItems - processedItems)
        estimatedTimeRemaining = rate > 0 ? remaining / rate : nil
    }

    /// Get pending queue count
    func getPendingCount() throws -> Int {
        try queueRepository.fetchPending().count
    }

    /// Get analysis status for a conversation
    func getAnalysisStatus(for conversationId: UUID) throws -> [AnalysisQueueItem] {
        try queueRepository.fetchPending().filter { $0.conversationId == conversationId }
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case noBackendAvailable(String)
    case toolNotFound
    case analysisTimeout
    case invalidResponse
    case queueError(String)

    var errorDescription: String? {
        switch self {
        case .noBackendAvailable(let msg): return msg
        case .toolNotFound: return "CLI tool not found"
        case .analysisTimeout: return "Analysis timed out"
        case .invalidResponse: return "Invalid response from LLM"
        case .queueError(let msg): return "Queue error: \(msg)"
        }
    }
}
