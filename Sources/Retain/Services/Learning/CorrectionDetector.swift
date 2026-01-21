import Foundation

/// Detects corrections and learning patterns from conversation messages
final class CorrectionDetector {
    // MARK: - Detection Result

    struct DetectionResult {
        let type: LearningType
        let pattern: String
        let extractedRule: String
        let confidence: Float
        let messageId: UUID
        let conversationId: UUID
        let messageTimestamp: Date
        let context: String
        let evidence: String
    }

    // MARK: - Pattern Categories

    /// Patterns that indicate user correcting the AI
    private let correctionPatterns: [(regex: String, weight: Float)] = [
        // Direct corrections
        (#"(?i)no,?\s*(actually|instead|use|it'?s?|that'?s?)"#, 0.95),
        (#"(?i)that'?s?\s*(not|wrong|incorrect)"#, 0.9),
        (#"(?i)you'?re?\s*(wrong|mistaken|incorrect)"#, 0.9),
        (#"(?i)that\s*doesn'?t?\s*(work|compile|run)"#, 0.85),

        // Preference expressions (explicit)
        (#"(?i)i\s*(?:would\s+)?prefer\s+(?:to\s+|that\s+)?"#, 0.85),
        (#"(?i)please\s*(use|don't|always|never)"#, 0.85),
        (#"(?i)(always|never)\s+(use|do|add|include|avoid|keep)"#, 0.9),

        // Style corrections
        (#"(?i)(don't|do\s*not)\s*(add|include|use)\s*(comments|docstrings|type\s*hints)"#, 0.9),
        (#"(?i)keep\s*(it|things|code)\s*(simple|minimal|clean)"#, 0.8),
        (#"(?i)too\s*(verbose|complex|complicated)"#, 0.8),

        // Technical corrections
        (#"(?i)use\s+(\w+)\s+instead\s+of\s+(\w+)"#, 0.95),
        (#"(?i)should\s*(be|use|have)\s+(\w+)"#, 0.85),
        (#"(?i)the\s*(correct|right|proper)\s*(way|approach|method)"#, 0.85),
    ]

    /// Patterns indicating positive feedback (implicit learning)
    private let positivePreferenceKeywords: [(keyword: String, rule: String, weight: Float)] = [
        ("concise", "Keep responses concise", 0.8),
        ("brief", "Keep responses brief", 0.75),
        ("step by step", "Explain step by step", 0.8),
        ("examples", "Include examples", 0.75),
        ("tests", "Include tests when relevant", 0.75),
        ("no comments", "Avoid unnecessary comments", 0.8),
        ("clean", "Keep output clean and uncluttered", 0.7)
    ]

    // MARK: - Exclusion Patterns

    /// Content patterns that indicate system messages or non-user content (should be skipped)
    private let systemMessagePatterns: [String] = [
        // Claude Code system messages
        "Hello! I'm Claude Code",
        "I'm Claude Code, Anthropic's",
        "I'm ready to help",
        "I'm in read-only mode",
        // Session continuation fragments
        "This session is being continued from a previous conversation",
        "The conversation is summarized below",
        "session-continuation",
        "local-command-caveat",
        "Caveat: The messages below were generated",
        // Command messages
        "<command-name>",
        "<command-message>",
        "<command-args>",
        // System reminders
        "<system-reminder>",
        // Analysis sections (often from session summaries)
        "Analysis:\nLet me analyze",
    ]

    /// Content patterns that indicate the message is too generic or system-generated
    private let genericContentPatterns: [String] = [
        // Generic ready messages
        "ready to help you",
        "ready to assist",
        "how can i help",
        "what would you like",
        // Meta-analysis text
        "let me analyze this",
        "i understand you want",
    ]

    // MARK: - Configuration

    struct Configuration {
        var minConfidence: Float = 0.7
        var contextWindowSize: Int = 3 // Messages before/after
        var enableSemanticDetection: Bool = true
        var enablePositiveFeedback: Bool = false
    }

    private var config: Configuration

    // MARK: - Init

    init(configuration: Configuration = Configuration()) {
        self.config = configuration
    }

    var configuration: Configuration {
        config
    }

    func updateMinimumConfidence(_ value: Float) {
        config.minConfidence = value
    }

    func updatePositiveFeedbackEnabled(_ value: Bool) {
        config.enablePositiveFeedback = value
    }

    // MARK: - Content Validation

    /// Check if content should be excluded from learning detection
    private func shouldExcludeContent(_ content: String) -> Bool {
        let lowercased = content.lowercased()

        // Check for system message patterns
        for pattern in systemMessagePatterns {
            if content.contains(pattern) {
                return true
            }
        }

        // Check for generic content patterns
        for pattern in genericContentPatterns {
            if lowercased.contains(pattern) {
                return true
            }
        }

        return false
    }

    /// Check if context contains system messages that invalidate the detection
    private func contextContainsSystemMessages(_ context: String) -> Bool {
        for pattern in systemMessagePatterns {
            if context.contains(pattern) {
                return true
            }
        }
        return false
    }

    // MARK: - Detection

    /// Analyze a conversation for corrections and learnings
    func analyzeConversation(_ conversation: Conversation, messages: [Message]) -> [DetectionResult] {
        var results: [DetectionResult] = []

        // Sort messages by timestamp
        let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }

        // Analyze user messages for corrections
        for (index, message) in sortedMessages.enumerated() {
            guard message.role == .user else { continue }
            let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedContent.count >= 6 else { continue }

            // Skip messages that look like system content
            guard !shouldExcludeContent(message.content) else { continue }

            let hasAssistantContext = sortedMessages.prefix(index).contains { $0.role == .assistant }

            // Check for correction patterns
            if let detection = detectCorrection(
                message: message,
                previousMessages: Array(sortedMessages.prefix(index)),
                conversationId: conversation.id,
                hasAssistantContext: hasAssistantContext
            ) {
                if detection.confidence >= config.minConfidence {
                    results.append(detection)
                }
            }

            // Check for positive feedback patterns
            if config.enablePositiveFeedback,
               let detection = detectPositiveFeedback(
                    message: message,
                    previousMessages: Array(sortedMessages.prefix(index)),
                    conversationId: conversation.id,
                    hasAssistantContext: hasAssistantContext
               ) {
                if detection.confidence >= config.minConfidence {
                    results.append(detection)
                }
            }
        }

        return results
    }

    /// Detect correction pattern in a user message
    private func detectCorrection(
        message: Message,
        previousMessages: [Message],
        conversationId: UUID,
        hasAssistantContext: Bool
    ) -> DetectionResult? {
        let content = message.content
        let allowsStandalone = isStandalonePreference(content)

        guard hasAssistantContext || allowsStandalone else {
            return nil
        }

        // Check each correction pattern
        for (pattern, weight) in correctionPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(
                    in: content,
                    options: [],
                    range: NSRange(content.startIndex..., in: content)
                  ) else {
                continue
            }

            // Extract the matched text
            let matchedRange = Range(match.range, in: content)!
            let matchedText = String(content[matchedRange])

            // Extract context (surrounding text)
            let context = buildContext(previousMessages: previousMessages, currentMessage: message)

            // Skip if context contains system message indicators
            if contextContainsSystemMessages(context) {
                continue
            }

            // Extract the rule from the correction
            guard let extractedRule = extractRule(from: content) else {
                continue
            }

            // Validate extracted rule is meaningful
            guard isValidExtractedRule(extractedRule) else {
                continue
            }

            guard LearningRuleNormalizer.isActionable(extractedRule) else {
                continue
            }

            return DetectionResult(
                type: .correction,
                pattern: matchedText,
                extractedRule: extractedRule,
                confidence: weight,
                messageId: message.id,
                conversationId: conversationId,
                messageTimestamp: message.timestamp,
                context: context,
                evidence: evidenceSnippet(from: message.content)
            )
        }

        return nil
    }

    /// Validate that an extracted rule is meaningful and not garbage
    private func isValidExtractedRule(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)

        // Rule must have minimum length
        guard trimmed.count >= 10 else { return false }

        // Rule must not exceed reasonable length (indicates garbage extraction)
        guard trimmed.count <= 160 else { return false }

        // Rule must not contain multiple sentences (likely extracted wrong content)
        let sentenceCount = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter { !$0.isEmpty }.count
        guard sentenceCount <= 2 else { return false }

        // Rule must not contain XML/HTML-like tags (system content)
        if trimmed.contains("<") && trimmed.contains(">") {
            return false
        }

        // Rule should start with actionable words or recognized patterns
        let validPrefixes = ["use ", "never ", "always ", "keep ", "avoid ", "prefer ", "user prefers"]
        let lowercased = trimmed.lowercased()
        let hasValidPrefix = validPrefixes.contains { lowercased.hasPrefix($0) }

        return hasValidPrefix
    }

    /// Detect positive feedback in a user message
    private func detectPositiveFeedback(
        message: Message,
        previousMessages: [Message],
        conversationId: UUID,
        hasAssistantContext: Bool
    ) -> DetectionResult? {
        guard hasAssistantContext else { return nil }

        let content = message.content
        let lowercased = content.lowercased()

        // Require minimum meaningful content (not just the keyword)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }

        for (keyword, rule, weight) in positivePreferenceKeywords {
            if lowercased.contains(keyword) {
                // Build context and verify it doesn't contain system messages
                let context = buildContext(previousMessages: previousMessages, currentMessage: message)

                // Skip if context contains system message indicators
                if contextContainsSystemMessages(context) {
                    continue
                }

                return DetectionResult(
                    type: .positive,
                    pattern: keyword,
                    extractedRule: rule,
                    confidence: weight,
                    messageId: message.id,
                    conversationId: conversationId,
                    messageTimestamp: message.timestamp,
                    context: context,
                    evidence: evidenceSnippet(from: message.content)
                )
            }
        }

        return nil
    }

    // MARK: - Rule Extraction

    /// Extract the actionable rule from a correction
    private func extractRule(from content: String) -> String? {
        // Try to extract "use X instead of Y" pattern
        if let useInsteadMatch = try? NSRegularExpression(pattern: #"use\s+(.+?)\s+instead\s+of\s+(.+?)(?:\.|$)"#, options: .caseInsensitive)
            .firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)) {

            if let range1 = Range(useInsteadMatch.range(at: 1), in: content),
               let range2 = Range(useInsteadMatch.range(at: 2), in: content) {
                let preferred = String(content[range1])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;"))
                let avoid = String(content[range2])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;"))
                return sanitizeRule("Use '\(preferred)' instead of '\(avoid)'")
            }
        }

        // Try to extract "use X instead" or "instead use X" pattern
        if let useInsteadMatch = try? NSRegularExpression(pattern: #"use\s+(.+?)\s+instead(?:\.|$)"#, options: .caseInsensitive)
            .firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)) {
            if let range = Range(useInsteadMatch.range(at: 1), in: content) {
                let preferred = String(content[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;"))
                return sanitizeRule("Use '\(preferred)' instead")
            }
        }

        if let useInsteadMatch = try? NSRegularExpression(pattern: #"instead\s+use\s+(.+?)(?:\.|$)"#, options: .caseInsensitive)
            .firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)) {
            if let range = Range(useInsteadMatch.range(at: 1), in: content) {
                let preferred = String(content[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;"))
                return sanitizeRule("Use '\(preferred)' instead")
            }
        }

        // Try to extract "don't/never X" pattern
        if let dontMatch = try? NSRegularExpression(pattern: #"(?:don't|do not|never)\s+(.+?)(?:\.|$)"#, options: .caseInsensitive)
            .firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)) {

            if let range = Range(dontMatch.range(at: 1), in: content) {
                let action = String(content[range]).trimmingCharacters(in: .whitespaces)
                return sanitizeRule("Never \(action)")
            }
        }

        // Try to extract "always X" pattern
        if let alwaysMatch = try? NSRegularExpression(pattern: #"always\s+(.+?)(?:\.|$)"#, options: .caseInsensitive)
            .firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)) {

            if let range = Range(alwaysMatch.range(at: 1), in: content) {
                let action = String(content[range]).trimmingCharacters(in: .whitespaces)
                return sanitizeRule("Always \(action)")
            }
        }

        // Try to extract "keep it simple/clean/concise" pattern
        if let keepMatch = try? NSRegularExpression(
            pattern: #"(?:keep|make)\s+(?:it|things|code|responses?)\s+(simple|minimal|clean|shorter?|concise|brief)"#,
            options: .caseInsensitive
        ).firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)) {
            if let range = Range(keepMatch.range(at: 1), in: content) {
                let preference = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let normalized = (preference == "short" || preference == "shorter") ? "concise" : preference
                return sanitizeRule("Keep responses \(normalized)")
            }
        }

        let lowercased = content.lowercased()
        if lowercased.contains("too verbose") || lowercased.contains("keep it shorter") || lowercased.contains("keep it short") {
            return sanitizeRule("Keep responses concise")
        }

        // Try to extract preference pattern
        if let preferMatch = try? NSRegularExpression(pattern: #"(?:i\s+(?:would\s+)?)?prefer\s+(.+?)(?:\.|$)"#, options: .caseInsensitive)
            .firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)) {

            if let range = Range(preferMatch.range(at: 1), in: content) {
                let preference = String(content[range]).trimmingCharacters(in: .whitespaces)
                return sanitizeRule("User prefers \(preference)")
            }
        }

        return nil
    }

    private func sanitizeRule(_ rule: String) -> String? {
        var cleaned = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;\"'"))

        guard !cleaned.isEmpty else { return nil }
        guard !cleaned.contains("\n") else { return nil }
        if cleaned.contains("->") || cleaned.contains("-->") { return nil }

        let openParens = cleaned.filter { $0 == "(" }.count
        let closeParens = cleaned.filter { $0 == ")" }.count
        if openParens != closeParens { return nil }

        let doubleQuotes = cleaned.filter { $0 == "\"" }.count
        if doubleQuotes % 2 != 0 { return nil }

        return cleaned
    }

    private func evidenceSnippet(from content: String, maxLength: Int = 220) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<endIndex]) + "..."
    }

    private func buildContext(previousMessages: [Message], currentMessage: Message) -> String {
        let startIndex = max(0, previousMessages.count - config.contextWindowSize)
        let window = previousMessages[startIndex...]

        var lines: [String] = []
        for message in window {
            let role = roleLabel(for: message.role)
            let preview = String(message.content.prefix(200))
            lines.append("\(role): \(preview)")
        }

        let currentPreview = String(currentMessage.content.prefix(240))
        lines.append("User: \(currentPreview)")

        return lines.joined(separator: "\n")
    }

    private func roleLabel(for role: Role) -> String {
        switch role {
        case .assistant: return "Assistant"
        case .user: return "User"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }

    private func isStandalonePreference(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("always")
            || trimmed.hasPrefix("never")
            || trimmed.hasPrefix("please")
    }
}
