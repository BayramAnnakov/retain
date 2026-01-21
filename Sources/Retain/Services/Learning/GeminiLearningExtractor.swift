import Foundation

/// Gemini-backed learning extraction from conversation transcripts.
/// Sends the last 10 messages to Gemini for intelligent preference extraction.
actor GeminiLearningExtractor {
    struct Configuration {
        var minConfidence: Float = 0.7
        var maxLearnings: Int = 5
        var maxMessages: Int = 10
    }

    struct Candidate {
        let rule: String
        let type: LearningType
        let confidence: Float
        let pattern: String
        let context: String
        let messageId: UUID?
        let messageTimestamp: Date?
    }

    private var client: GeminiClient?
    private var config: Configuration

    init(configuration: Configuration = Configuration()) {
        self.config = configuration
    }

    /// Initialize with a pre-configured client (for testing)
    init(client: GeminiClient, configuration: Configuration = Configuration()) {
        self.client = client
        self.config = configuration
    }

    func updateConfiguration(apiKey: String, model: String, minConfidence: Float) {
        if !apiKey.isEmpty {
            let clientConfig = GeminiClient.Configuration(apiKey: apiKey, model: model)
            self.client = GeminiClient(configuration: clientConfig)
        } else {
            self.client = nil
        }
        self.config.minConfidence = minConfidence
    }

    /// Update configuration with pre-configured client (for testing)
    func updateConfiguration(client: GeminiClient?, minConfidence: Float) {
        self.client = client
        self.config.minConfidence = minConfidence
    }

    var isAvailable: Bool {
        client != nil
    }

    func extractLearnings(from conversation: Conversation, messages: [Message]) async -> [Candidate] {
        guard let client = client else { return [] }

        let filteredMessages = messages.filter { $0.role == .user || $0.role == .assistant }
        guard !filteredMessages.isEmpty else { return [] }

        let window = filteredMessages.suffix(config.maxMessages)
        let transcript = formatTranscript(window)

        let prompt = buildPrompt(transcript: transcript)
        let schema = buildSchema()

        do {
            let text = try await client.generateStructuredContent(prompt: prompt, schema: schema)
            let payload = try JSONDecoder().decode(GeminiLearningResponse.self, from: Data(text.utf8))

            let lastUserMessage = filteredMessages.last(where: { $0.role == .user })
            let timestamp = lastUserMessage?.timestamp ?? conversation.updatedAt

            return payload.learnings.prefix(config.maxLearnings).compactMap { item in
                let rule = item.rule.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rule.isEmpty else { return nil }
                guard LearningRuleNormalizer.isActionable(rule) else { return nil }

                let confidence = min(max(item.confidence, 0.0), 1.0)
                guard confidence >= config.minConfidence else { return nil }

                return Candidate(
                    rule: rule,
                    type: item.type,
                    confidence: confidence,
                    pattern: "gemini",
                    context: transcript,
                    messageId: lastUserMessage?.id,
                    messageTimestamp: timestamp
                )
            }
        } catch {
            return []
        }
    }

    private func formatTranscript(_ messages: ArraySlice<Message>) -> String {
        messages.map { message in
            let role = message.role == .assistant ? "Assistant" : "User"
            let trimmed = message.content.replacingOccurrences(of: "\n", with: " ")
            let preview = String(trimmed.prefix(500))
            return "\(role): \(preview)"
        }.joined(separator: "\n")
    }

    private func buildPrompt(transcript: String) -> String {
        """
        You are extracting reusable user preferences from a conversation between a user and an AI assistant.

        Focus on:
        - CORRECTIONS: When the user corrects the assistant (e.g., "No, use X instead", "That's wrong")
        - PREFERENCES: Explicit style/tool preferences (e.g., "I prefer concise responses", "Always use TypeScript")
        - POSITIVE/IMPLICIT: Only when the user explicitly asks to repeat or keep a behavior (do NOT infer from praise alone)

        Rules:
        - Only extract portable, reusable preferences that apply across conversations
        - Ignore task-specific instructions (e.g., "Add a login button" is task-specific)
        - Ignore transient requests (e.g., "Can you explain this?" is not a preference)
        - Each rule should be a clear, reusable instruction for future AI assistants
        - If the rule mentions a specific file path, ticket ID, or URL, do not extract it

        Return at most \(config.maxLearnings) learnings. If no learnings are found, return an empty array.

        Conversation:
        \(transcript)
        """
    }

    private func buildSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "learnings": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "rule": [
                                "type": "string",
                                "description": "The extracted preference or rule, written as an instruction"
                            ],
                            "type": [
                                "type": "string",
                                "enum": ["correction", "positive", "implicit"],
                                "description": "correction=user corrected assistant, positive=user praised something, implicit=inferred preference"
                            ],
                            "confidence": [
                                "type": "number",
                                "description": "Confidence score 0.0-1.0"
                            ],
                            "evidence": [
                                "type": "string",
                                "description": "Brief quote from conversation supporting this learning"
                            ]
                        ],
                        "required": ["rule", "type", "confidence", "evidence"]
                    ]
                ]
            ],
            "required": ["learnings"]
        ]
    }
}

private struct GeminiLearningResponse: Decodable {
    let learnings: [GeminiLearningItem]
}

private struct GeminiLearningItem: Decodable {
    let rule: String
    let type: LearningType
    let confidence: Float
    let evidence: String

    enum CodingKeys: String, CodingKey {
        case rule, type, confidence, evidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rule = try container.decode(String.self, forKey: .rule)
        evidence = (try? container.decode(String.self, forKey: .evidence)) ?? ""

        // Handle type as string
        let typeString = try container.decode(String.self, forKey: .type)
        let normalized = typeString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        type = LearningType(rawValue: normalized) ?? .implicit

        // Handle confidence flexibly
        if let value = try? container.decode(Float.self, forKey: .confidence) {
            confidence = value
        } else if let value = try? container.decode(Double.self, forKey: .confidence) {
            confidence = Float(value)
        } else {
            confidence = 0.7
        }
    }
}
