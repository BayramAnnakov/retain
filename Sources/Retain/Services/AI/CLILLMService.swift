import Foundation
import OSLog

/// Manages CLI-based LLM analysis via Claude Code CLI
/// NOTE: Codex CLI is DISABLED for alpha - lacks hard no-tools flag
actor CLILLMService {

    // MARK: - Types

    enum CLITool: String, CaseIterable {
        case claudeCode = "claude"
        // case codex = "codex"  // DISABLED for alpha - --disable shell_tool is soft, not hard no-tools

        var displayName: String {
            switch self {
            case .claudeCode: return "Claude Code"
            }
        }
    }

    /// CLI capabilities detected at runtime
    struct CLICapabilities: Codable {
        let toolPath: URL?
        let supportsNoTools: Bool              // --tools "" works (runtime-verified)
        let supportsStdin: Bool                // --input-format text works
        let supportsJsonOutput: Bool           // --output-format json works
        let supportsPrintMode: Bool            // -p/--print works
        let supportsNoSessionPersistence: Bool // --no-session-persistence works (optional)

        /// Core capabilities required for security
        var isFullySupported: Bool {
            toolPath != nil && supportsNoTools && supportsStdin && supportsJsonOutput && supportsPrintMode
        }

        static let unsupported = CLICapabilities(
            toolPath: nil,
            supportsNoTools: false,
            supportsStdin: false,
            supportsJsonOutput: false,
            supportsPrintMode: false,
            supportsNoSessionPersistence: false
        )
    }

    /// Claude CLI --output-format json returns a wrapper object, not direct JSON
    /// The model's response is inside the `result` field as a string
    struct ClaudeCLIWrapper: Decodable {
        let result: String?         // Model's raw text response (may contain JSON). Optional—missing on error wrappers.
        let is_error: Bool?         // True if CLI encountered an error
        let error: String?          // Error message if is_error is true
        let type: String?           // Wrapper type, e.g., "result". Guard against future format changes.
    }

    struct CLIConfig {
        var customClaudePath: String?
    }

    struct DetectedTool {
        let tool: CLITool
        let path: String
        let capabilities: CLICapabilities
    }

    enum PayloadMode: String, Codable, CaseIterable {
        case minimized
        case expanded
    }

    // MARK: - Properties

    private var config: CLIConfig
    private let repository: ConversationRepository
    private let logger = Logger(subsystem: "ai.omni.app", category: "CLILLMService")

    /// Cached capabilities from --help (detected at launch)
    private var claudeCapabilities: CLICapabilities?

    /// Runtime-verified --tools "" flag (nil = not yet tested, true/false = cached result)
    /// Only SUCCESS is cached; failures allow retry (auth errors, transient issues)
    private var noToolsRuntimeVerified: Bool?

    /// Robust PATH search for GUI apps (handles Apple Silicon, Homebrew, npm global)
    private let searchPaths: [String] = [
        "/usr/local/bin",           // Intel Homebrew
        "/opt/homebrew/bin",        // Apple Silicon Homebrew
        "/usr/bin",
        NSString(string: "~/.npm-global/bin").expandingTildeInPath,  // npm global
        NSString(string: "~/.local/bin").expandingTildeInPath,       // pipx, cargo
        "/run/current-system/sw/bin" // Nix
    ]

    // MARK: - Init

    init(config: CLIConfig = CLIConfig(), repository: ConversationRepository = ConversationRepository()) {
        self.config = config
        self.repository = repository
    }

    // MARK: - Configuration

    func updateConfig(_ newConfig: CLIConfig) {
        self.config = newConfig
    }

    // MARK: - Capability Detection (--help only, no real calls at launch)

    /// Detect CLI capabilities by parsing --help output (no real API calls)
    /// Call on app launch to check if Claude CLI is available
    func detectCapabilities() async {
        claudeCapabilities = await probeClaudeCapabilities()
    }

    /// Probe Claude CLI by running --help ONLY (no real calls at launch)
    private func probeClaudeCapabilities() async -> CLICapabilities {
        // 1. Find claude binary
        guard let path = findExecutable(.claudeCode) else {
            logger.info("Claude CLI not found in search paths")
            return .unsupported
        }

        // 2. Run `claude --help` and parse for required flags (no real calls)
        guard let helpOutput = await runHelpCommand(path: path) else {
            logger.warning("Failed to run claude --help")
            return .unsupported
        }

        let hasToolsFlag = helpOutput.contains("--tools")
        let hasInputFormat = helpOutput.contains("--input-format")
        let hasOutputFormat = helpOutput.contains("--output-format")
        let hasPrintMode = helpOutput.contains("--print") || helpOutput.contains("-p,")
        let hasNoSessionPersistence = helpOutput.contains("--no-session-persistence")

        // NOTE: Do NOT run real Claude call here—that would send data before consent
        // Runtime verification happens lazily on first analysis attempt (see verifyNoToolsAtRuntime)

        let capabilities = CLICapabilities(
            toolPath: URL(fileURLWithPath: path),
            supportsNoTools: hasToolsFlag,  // From --help; verified lazily at runtime
            supportsStdin: hasInputFormat,
            supportsJsonOutput: hasOutputFormat,
            supportsPrintMode: hasPrintMode,
            supportsNoSessionPersistence: hasNoSessionPersistence
        )

        logger.info("Claude CLI capabilities: noTools=\(hasToolsFlag), stdin=\(hasInputFormat), json=\(hasOutputFormat), print=\(hasPrintMode), noSession=\(hasNoSessionPersistence)")

        return capabilities
    }

    private func runHelpCommand(path: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            logger.error("Failed to run --help: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Tool Detection

    /// Detect available CLI tools with robust PATH search
    func detectAvailableTools() async -> [DetectedTool] {
        var found: [DetectedTool] = []

        // Ensure capabilities are detected
        if claudeCapabilities == nil {
            await detectCapabilities()
        }

        // Only advertise FULLY SUPPORTED tools to avoid UI confusion
        // (green checkmark should mean analysis will actually work)
        if let caps = claudeCapabilities, caps.isFullySupported, let path = caps.toolPath {
            found.append(DetectedTool(tool: .claudeCode, path: path.path, capabilities: caps))
        }

        return found
    }

    private func findExecutable(_ tool: CLITool) -> String? {
        // 1. Check user-configured path first
        if let custom = config.customClaudePath, !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }

        // 2. Search known paths
        for dir in searchPaths {
            let path = (dir as NSString).appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 3. Try `which` as fallback (may not work in GUI app)
        if let whichResult = shell("/usr/bin/which \(tool.rawValue)"),
           !whichResult.isEmpty {
            let path = whichResult.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Runtime Verification (Lazy, After Consent)

    /// Lazily verify --tools "" works at runtime (called on first analysis, after consent)
    private func verifyNoToolsAtRuntime() async throws -> Bool {
        // Return cached SUCCESS only (nil or false allows retry)
        if noToolsRuntimeVerified == true {
            return true
        }

        guard let caps = claudeCapabilities, let toolPath = caps.toolPath else {
            return false  // Don't cache—user may install CLI later
        }

        logger.info("Verifying --tools \"\" works at runtime...")

        // Run minimal test to verify --tools "" actually works
        // We only need to confirm the CLI accepts our flags and runs successfully;
        // we don't validate model output content (models may format responses differently)
        do {
            let result = try await runCLI(
                toolPath: toolPath.path,
                prompt: "Say hello",  // Simple prompt - we don't care about the response content
                capabilities: caps,
                timeout: 30
            )

            // Parse CLI wrapper first (--output-format json returns wrapper)
            guard let wrapper = try? JSONDecoder().decode(ClaudeCLIWrapper.self, from: result) else {
                logger.warning("Runtime verification: failed to parse CLI wrapper")
                return false  // Don't cache—may be transient
            }

            // Check for CLI errors - this indicates a flag/permission problem
            if wrapper.is_error == true {
                logger.warning("Runtime verification: CLI returned error: \(wrapper.error ?? "unknown")")
                return false  // Allow retry
            }

            // SUCCESS: CLI ran with our flags (exit 0) and returned valid non-error wrapper
            // We don't validate inner result content - model output can vary in format
            // What matters is that --tools "" was accepted and the CLI completed successfully
            logger.info("Runtime verification: SUCCESS - CLI accepted required flags")
            noToolsRuntimeVerified = true
            return true
        } catch let error as CLIError {
            switch error {
            case .authenticationRequired:
                logger.info("Runtime verification: auth required - prompt user to login")
                throw error
            case .executionFailed(let message):
                // Check for unsupported flags (cache as permanent failure)
                if message.contains("unknown option") || message.contains("unrecognized") {
                    logger.error("Runtime verification: CLI does not support required flags")
                    noToolsRuntimeVerified = false
                    throw CLIError.unsupportedCLIVersion(reason: "Claude CLI does not support required flags")
                }
            default:
                break
            }
            logger.warning("Runtime verification failed: \(error.localizedDescription)")
            return false  // Unknown error—allow retry
        } catch {
            logger.warning("Runtime verification failed: \(error.localizedDescription)")
            return false  // Transient error—allow retry
        }
    }

    // MARK: - Analysis Execution

    /// Result from CLI analysis including info about dropped items
    struct AnalysisRunResult {
        let jsonOutput: String
        let includedQueueIds: Set<String>
        let droppedQueueIds: Set<String>
    }

    /// Spawn CLI and get schema-validated JSON output via stdout
    /// Uses STDIN for INPUT (conversations), stdout for OUTPUT (schema-validated)
    /// Returns result with info about which queue items were included/dropped due to truncation
    func runAnalysis(
        tool: CLITool,
        queueItems: [AnalysisQueueItem],
        conversations: [ConversationData],
        analysisType: AnalysisType,
        payloadMode: PayloadMode = .minimized,
        maxPayloadBytes: Int = 500_000
    ) async throws -> AnalysisRunResult {
        // 1. Check consent FIRST (required before any verification or analysis)
        guard UserDefaults.standard.bool(forKey: "allowCloudAnalysis") else {
            throw CLIError.consentNotGranted
        }

        // 2. Check basic capabilities from --help
        guard let caps = claudeCapabilities, caps.isFullySupported else {
            throw CLIError.unsupportedCLIVersion(
                reason: "CLI version missing required flags (--tools, --input-format, --output-format, --print)"
            )
        }

        guard let toolPath = caps.toolPath else {
            throw CLIError.toolNotFound(tool)
        }

        // 3. Lazy runtime verification of --tools "" (only on first call, after consent)
        let verified = try await verifyNoToolsAtRuntime()
        guard verified else {
            throw CLIError.unsupportedCLIVersion(
                reason: "--tools \"\" failed at runtime (may need login or update)"
            )
        }

        // Create secure temp directory with restricted permissions (for cleanup tracking only)
        let tempDir = try createSecureTempDir()

        defer {
            cleanupTempDir(tempDir)
        }

        let conversationMap = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let includedItems = queueItems.filter { conversationMap[$0.conversationId.uuidString] != nil }
        let includedQueueIds = Set(includedItems.map { $0.id })
        let droppedQueueIds = Set(queueItems.map { $0.id }).subtracting(includedQueueIds)
        let includedConversations = includedItems.compactMap { conversationMap[$0.conversationId.uuidString] }

        // Apply per-analysis-type data minimization BEFORE redaction
        // This reduces payload size and sends only necessary data for each analysis type
        let minimizedConversations = preparePayload(
            for: analysisType,
            conversations: includedConversations,
            mode: payloadMode
        )

        // Prepare input payload
        let inputPayload = AnalysisInputPayload(
            queueItems: includedItems.map { .init(queueId: $0.id, conversationId: $0.conversationId.uuidString) },
            conversations: redactSensitiveData(minimizedConversations),
            analysisType: analysisType.rawValue,
            schemaVersion: 1
        )

        // Check estimated size BEFORE building prompt
        let payloadData = try JSONEncoder().encode(inputPayload)
        let estimatedSize = payloadData.count
        let maxPayloadSize = maxPayloadBytes

        guard estimatedSize <= maxPayloadSize else {
            throw CLIError.payloadTooLarge(bytes: estimatedSize, maxBytes: maxPayloadSize)
        }

        // Build prompt - data sent via STDIN, not file path
        let prompt = buildPrompt(for: analysisType)

        // Combine prompt and payload for STDIN
        let stdinContent = """
        \(prompt)

        ---INPUT DATA---
        \(String(data: payloadData, encoding: .utf8) ?? "")
        """

        // Run CLI with STDIN input
        let stdoutData = try await runCLI(
            toolPath: toolPath.path,
            prompt: stdinContent,
            capabilities: caps,
            timeout: 300
        )

        // Parse CLI wrapper
        let jsonOutput = try parseOutput(stdoutData)

        return AnalysisRunResult(
            jsonOutput: jsonOutput,
            includedQueueIds: includedQueueIds,
            droppedQueueIds: droppedQueueIds
        )
    }

    // MARK: - CLI Execution (Off Main Actor)

    /// Thread-safe timeout state
    private final class TimeoutState: @unchecked Sendable {
        private let lock = NSLock()
        private var _timedOut = false

        var timedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _timedOut
        }

        func markTimedOut() {
            lock.lock()
            _timedOut = true
            lock.unlock()
        }
    }

    /// Run CLI command off the main actor to avoid UI stalls
    private func runCLI(toolPath: String, prompt: String, capabilities: CLICapabilities, timeout: TimeInterval) async throws -> Data {
        let caps = capabilities
        let path = toolPath
        let promptData = prompt

        // CRITICAL: Run entire CLI execution in Task.detached to avoid blocking MainActor
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)

            // Build safe CLI args
            var args = [
                "-p",                           // Non-interactive print mode
                "--tools", "",                  // Disable ALL tools (CRITICAL for security)
                "--output-format", "json",      // Enforce JSON output
                "--input-format", "text"        // STDIN input format
            ]
            // Only add --no-session-persistence if the CLI version supports it
            if caps.supportsNoSessionPersistence {
                args += ["--no-session-persistence"]  // Don't persist sessions (privacy)
            }
            process.arguments = args

            // Force non-interactive mode via environment
            var env = ProcessInfo.processInfo.environment
            env["CLAUDE_NO_INTERACTIVE"] = "1"
            env["CI"] = "true"
            env["TERM"] = "dumb"
            process.environment = env

            // Set up pipes
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            // Write prompt to stdin and close
            if let data = promptData.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()

            // CRITICAL: Start reading pipes BEFORE waitUntilExit to prevent buffer deadlock
            // If output exceeds ~64KB pipe buffer, process blocks waiting to write,
            // parent blocks in waitUntilExit = deadlock until timeout
            let stdoutReadTask = Task.detached {
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrReadTask = Task.detached {
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }

            // Thread-safe timeout tracking (avoids data race)
            let timeoutState = TimeoutState()
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(timeout))
                if process.isRunning {
                    timeoutState.markTimedOut()
                    process.terminate()

                    // Hard kill after 5s grace period if terminate is ignored
                    try await Task.sleep(for: .seconds(5))
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }

            // Wait for completion (blocks this detached task, not MainActor)
            process.waitUntilExit()
            timeoutTask.cancel()

            // Await pipe reads (now safe since process exited)
            let stdoutData = await stdoutReadTask.value
            let stderrData = await stderrReadTask.value

            // Check timeout flag first (thread-safe read)
            if timeoutState.timedOut {
                throw CLIError.timeout(seconds: Int(timeout))
            }

            guard process.terminationStatus == 0 else {
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                let lowercased = stderrString.lowercased()
                if lowercased.contains("not logged in") || lowercased.contains("authentication") {
                    throw CLIError.authenticationRequired
                }
                throw CLIError.executionFailed(stderrString.isEmpty ? "Exit code: \(process.terminationStatus)" : stderrString)
            }

            return stdoutData
        }.value
    }

    // MARK: - Output Parsing

    /// Parse CLI output with wrapper handling
    private func parseOutput(_ stdout: Data) throws -> String {
        let decoder = JSONDecoder()

        // Step 1: Decode the CLI wrapper
        let wrapper: ClaudeCLIWrapper
        do {
            wrapper = try decoder.decode(ClaudeCLIWrapper.self, from: stdout)
        } catch {
            logger.error("CLI wrapper parse failed: \(error.localizedDescription)")
            throw CLIError.invalidOutput(reason: "Failed to parse CLI wrapper JSON")
        }

        // Step 2: Check for CLI-level errors
        if wrapper.is_error == true {
            let message = wrapper.error ?? "Unknown CLI error"
            let lowercased = message.lowercased()
            if lowercased.contains("not logged in") || lowercased.contains("authentication") {
                throw CLIError.authenticationRequired
            }
            throw CLIError.cliError(message: message)
        }

        // Step 3: Validate wrapper type if present (guard against future format changes)
        if let type = wrapper.type, type != "result" {
            throw CLIError.invalidOutput(reason: "Unexpected wrapper type: \(type)")
        }

        // Step 4: Extract result (optional—missing on error wrappers)
        guard let resultString = wrapper.result else {
            throw CLIError.invalidOutput(reason: "Missing result field in wrapper")
        }

        return normalizeJSONPayload(resultString)
    }

    private func normalizeJSONPayload(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("```") {
            if let firstLineEnd = trimmed.firstIndex(of: "\n"),
               let lastFence = trimmed.range(of: "```", options: .backwards),
               lastFence.lowerBound > firstLineEnd {
                let contentStart = trimmed.index(after: firstLineEnd)
                let content = trimmed[contentStart..<lastFence.lowerBound]
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let firstFence = trimmed.range(of: "```"),
           let lastFence = trimmed.range(of: "```", options: .backwards),
           firstFence.lowerBound != lastFence.lowerBound {
            let content = trimmed[firstFence.upperBound..<lastFence.lowerBound]
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let extracted = extractFirstJSONPayload(from: trimmed) {
            return extracted
        }

        return trimmed
    }

    private func extractFirstJSONPayload(from text: String) -> String? {
        guard let startIndex = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }
        let startChar = text[startIndex]
        let endChar: Character = (startChar == "{") ? "}" : "]"

        var depth = 0
        var index = startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == startChar { depth += 1 }
            if ch == endChar {
                depth -= 1
                if depth == 0 {
                    return String(text[startIndex...index])
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    // MARK: - Prompt Building

    private func buildPrompt(for analysisType: AnalysisType) -> String {
        let baseInstruction = """
        You will receive input data below containing:
        - queueItems: array of {queueId, conversationId} mappings
        - conversations: array of conversation data

        IMPORTANT: For EACH queue item in queueItems, produce a result object with the matching queue_id.
        Return ONLY a JSON ARRAY with one result per queue item.
        No markdown, no code fences, no commentary.
        """

        switch analysisType {
        case .workflow:
            let actionList = WorkflowTaxonomy.allowedActions.sorted().joined(separator: ", ")
            let artifactList = WorkflowTaxonomy.allowedArtifacts.sorted().joined(separator: ", ")
            let domainList = WorkflowTaxonomy.allowedDomains.sorted().joined(separator: ", ")
            return """
            \(baseInstruction)

            Analyze each conversation for automation workflow candidates.
            Look for repetitive patterns that could be automated.

            Choose action from: [\(actionList)]
            Choose artifact from: [\(artifactList)]
            Choose domains from: [\(domainList)]
            If no automation candidate, set action to "none" and leave artifact/domains empty.

            Output format: [{"queue_id": "<queueId>", "action": "...", "artifact": "...", "domains": ["..."], "confidence": 0.8, "reasoning": "..."}, ...]
            """
        case .learning:
            return """
            \(baseInstruction)

            Extract learning patterns and corrections from each conversation.
            Look for user corrections, preferences, and implicit learnings.

            Each learning MUST include:
            - evidence: a short exact quote (5-25 words) from the conversation message that supports the rule
            - message_id: the id of the message containing the evidence (from input)
            If you cannot find a supporting quote, return an empty learnings array for that queue_id.

            Output format: [{"queue_id": "<queueId>", "learnings": [{"type": "...", "rule": "...", "confidence": 0.8, "evidence": "...", "message_id": "..."}, ...]}, ...]
            """
        case .summary:
            return """
            \(baseInstruction)

            Generate a concise title and summary for each conversation.
            Focus on the main topic and key outcomes.

            Output format: [{"queue_id": "<queueId>", "suggested_title": "...", "confidence": 0.8, ...}, ...]
            """
        case .dedupe:
            return """
            \(baseInstruction)

            Identify duplicate or similar learnings that could be merged.
            Look for rules that express the same preference in different words.

            Output format: [{"queue_id": "<queueId>", "merge_suggestions": [{"source_ids": [...], "merged_rule": "...", "confidence": 0.8}, ...]}, ...]
            """
        }
    }

    // MARK: - Data Preparation

    /// Redact sensitive data before sending to CLI
    private func redactSensitiveData(_ convos: [ConversationData]) -> [ConversationData] {
        convos.map { convo in
            var redacted = convo
            redacted.messages = convo.messages.map { msg in
                var m = msg
                // Redact common PII and credential patterns
                m.content = m.content
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
                    // AWS secret keys
                    .replacingOccurrences(of: #"[A-Za-z0-9/+=]{40}"#, with: { match in
                        // Only redact if it looks like a secret key (40 chars base64-like)
                        match.contains("/") || match.contains("+") ? "[AWS_SECRET_KEY]" : match
                    })
                    // SSH private keys
                    .replacingOccurrences(of: #"-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"#, with: "[SSH_KEY_REDACTED]", options: .regularExpression)
                    // Generic passwords in common patterns
                    .replacingOccurrences(of: #"(?i)(password|passwd|pwd)\s*[:=]\s*\S+"#, with: "[PASSWORD_REDACTED]", options: .regularExpression)
                return m
            }
            return redacted
        }
    }

    /// Truncate conversations with deterministic queue_id mapping
    private func truncateForContext(_ convos: [ConversationData], maxTokens: Int) -> [ConversationData] {
        var result: [ConversationData] = []
        var totalTokens = 0
        let tokensPerChar = 0.25

        for convo in convos {
            var truncated = convo
            let convoTokens = Int(Double(convo.estimatedCharCount) * tokensPerChar)

            if totalTokens + convoTokens > maxTokens {
                if convo.messages.count > 10 {
                    truncated.messages = [convo.messages[0]] + Array(convo.messages.suffix(9))
                    truncated.wasTruncated = true
                }
            }

            result.append(truncated)
            totalTokens += Int(Double(truncated.estimatedCharCount) * tokensPerChar)

            if totalTokens >= maxTokens { break }
        }

        return result
    }

    /// Prepare payload with per-analysis-type data minimization
    /// Different analysis types need different levels of detail
    private func preparePayload(
        for analysisType: AnalysisType,
        conversations: [ConversationData],
        mode: PayloadMode
    ) -> [ConversationData] {
        switch (analysisType, mode) {
        case (.summary, _):
            // Summary only needs title + first/last messages to generate a good summary
            return conversations.map { $0.forSummary() }

        case (.workflow, .minimized):
            // Workflow detection needs patterns, but less content per message
            return conversations.map { $0.truncated(maxCharsPerMessage: 300, maxMessages: 10) }

        case (.workflow, .expanded):
            // Expanded payload includes more context for intent disambiguation
            return conversations.map { $0.truncated(maxCharsPerMessage: 800, maxMessages: 25) }

        case (.dedupe, .minimized):
            // Dedupe just needs to compare rules/learnings - minimal content needed
            return conversations.map { $0.truncated(maxCharsPerMessage: 200, maxMessages: 5) }

        case (.dedupe, .expanded):
            return conversations.map { $0.truncated(maxCharsPerMessage: 400, maxMessages: 10) }

        case (.learning, .minimized):
            // Learning extraction needs more context to understand corrections
            return conversations.map { $0.truncated(maxCharsPerMessage: 500, maxMessages: 20) }

        case (.learning, .expanded):
            return conversations.map { $0.truncated(maxCharsPerMessage: 1200, maxMessages: 40) }
        }
    }

    // MARK: - Temp Directory Management

    /// Create secure temp directory with 0700 permissions
    private func createSecureTempDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("omni-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// Clean up temp directory with proper error logging
    private func cleanupTempDir(_ dir: URL) {
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            logger.error("Failed to clean up temp directory \(dir.path): \(error.localizedDescription)")
        }
    }

    /// Clean up orphaned temp directories on startup (older than 1 hour)
    func cleanupOrphanedTempDirs() {
        let base = FileManager.default.temporaryDirectory
        let oneHourAgo = Date().addingTimeInterval(-3600)

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.creationDateKey],
                options: []
            )

            for item in contents {
                guard item.lastPathComponent.hasPrefix("omni-") else { continue }

                if let attrs = try? FileManager.default.attributesOfItem(atPath: item.path),
                   let creationDate = attrs[.creationDate] as? Date,
                   creationDate < oneHourAgo {
                    do {
                        try FileManager.default.removeItem(at: item)
                        logger.info("Cleaned up orphaned temp dir: \(item.lastPathComponent)")
                    } catch {
                        logger.warning("Failed to clean up orphaned temp dir \(item.path): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            logger.warning("Failed to enumerate temp directories: \(error.localizedDescription)")
        }
    }

    // MARK: - Errors

    enum CLIError: LocalizedError {
        case timeout(seconds: Int)
        case executionFailed(String)
        case emptyOutput
        case toolNotFound(CLITool)
        case consentNotGranted
        case unsupportedCLIVersion(reason: String)
        case authenticationRequired
        case payloadTooLarge(bytes: Int, maxBytes: Int)
        case invalidOutput(reason: String)
        case cliError(message: String)

        var errorDescription: String? {
            switch self {
            case .timeout(let seconds):
                return "CLI analysis timed out after \(seconds) seconds"
            case .executionFailed(let message):
                return "CLI execution failed: \(message)"
            case .emptyOutput:
                return "CLI returned empty output"
            case .toolNotFound(let tool):
                return "\(tool.displayName) not found"
            case .consentNotGranted:
                return "Cloud analysis consent not granted. Enable in Settings."
            case .unsupportedCLIVersion(let reason):
                return "CLI version not supported: \(reason)"
            case .authenticationRequired:
                return "Claude CLI not logged in. Run `claude login` and try again."
            case .payloadTooLarge(let bytes, let maxBytes):
                return "Payload too large (\(bytes) bytes, max \(maxBytes) bytes)"
            case .invalidOutput(let reason):
                return "Invalid CLI output: \(reason)"
            case .cliError(let message):
                return "CLI error: \(message)"
            }
        }
    }
}

// MARK: - Supporting Types

/// Input payload for CLI analysis
struct AnalysisInputPayload: Codable {
    let queueItems: [QueueItemRef]
    let conversations: [ConversationData]
    let analysisType: String
    let schemaVersion: Int

    struct QueueItemRef: Codable {
        let queueId: String
        let conversationId: String
    }
}

/// Conversation data for CLI analysis
struct ConversationData: Codable {
    let id: String
    let title: String?
    var messages: [MessageData]
    var wasTruncated: Bool = false

    var estimatedCharCount: Int {
        let titleCount = title?.count ?? 0
        let messageCount = messages.reduce(0) { $0 + $1.content.count }
        return titleCount + messageCount
    }

    /// Estimated JSON size in bytes
    var estimatedJSONSize: Int {
        let titleSize = title?.utf8.count ?? 0
        let messagesSize = messages.reduce(0) { $0 + $1.content.utf8.count + 50 }
        return titleSize + messagesSize + 200
    }

    // MARK: - Data Minimization

    /// Create a truncated copy with limited message content and count
    func truncated(maxCharsPerMessage: Int, maxMessages: Int) -> ConversationData {
        var truncated = self
        var keptMessages: [MessageData] = []

        // Keep first and last messages if we have more than maxMessages
        if messages.count > maxMessages {
            let half = maxMessages / 2
            let firstPart = Array(messages.prefix(half))
            let lastPart = Array(messages.suffix(half))
            keptMessages = firstPart + lastPart
            truncated.wasTruncated = true
        } else {
            keptMessages = messages
        }

        // Truncate each message's content
        truncated.messages = keptMessages.map { msg in
            var truncatedMsg = msg
            if msg.content.count > maxCharsPerMessage {
                let endIndex = msg.content.index(msg.content.startIndex, offsetBy: maxCharsPerMessage)
                truncatedMsg.content = String(msg.content[..<endIndex]) + "..."
                truncated.wasTruncated = true
            }
            return truncatedMsg
        }

        return truncated
    }

    /// Create a metadata-only copy for workflow detection (no message content)
    func metadataOnly(messageCount: Int, timestamps: (first: Date?, last: Date?)) -> ConversationData {
        var copy = self
        copy.messages = [] // Remove all messages
        copy.wasTruncated = true
        return copy
    }

    /// Create a summary-optimized copy (title + first/last messages only)
    func forSummary() -> ConversationData {
        var copy = self
        if messages.count > 2 {
            copy.messages = [messages.first, messages.last].compactMap { $0 }
            copy.wasTruncated = true
        }
        return copy
    }
}

/// Message data for CLI analysis
struct MessageData: Codable {
    let id: String?
    let role: String
    var content: String
}

// MARK: - String Extension for Conditional Replacement

private extension String {
    func replacingOccurrences(of pattern: String, with replacer: (String) -> String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return self
        }
        var result = self
        let matches = regex.matches(in: self, options: [], range: NSRange(self.startIndex..., in: self))
        for match in matches.reversed() {
            if let range = Range(match.range, in: result) {
                let matched = String(result[range])
                result.replaceSubrange(range, with: replacer(matched))
            }
        }
        return result
    }
}
