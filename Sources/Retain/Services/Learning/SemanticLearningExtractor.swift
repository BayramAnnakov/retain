import Foundation

actor SemanticLearningExtractor {
    struct Configuration {
        var model: String = "llama3.1:8b"
        var minConfidence: Float = 0.7
        var maxLearnings: Int = 5
        var maxMessages: Int = 12
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

    private let ollama: OllamaService
    private var config: Configuration

    init(ollama: OllamaService, configuration: Configuration = Configuration()) {
        self.ollama = ollama
        self.config = configuration
    }

    func updateConfiguration(model: String, minConfidence: Float) {
        config.model = model
        config.minConfidence = minConfidence
    }

    func extractLearnings(from conversation: Conversation, messages: [Message]) async -> [Candidate] {
        let filteredMessages = messages.filter { $0.role == .user || $0.role == .assistant }
        guard !filteredMessages.isEmpty else { return [] }

        let window = filteredMessages.suffix(config.maxMessages)
        let transcript = formatTranscript(window)

        guard await ollama.isModelAvailable(config.model) else {
            return []
        }

        let prompt = buildPrompt(transcript: transcript)

        do {
            let response = try await ollama.generate(
                prompt: prompt,
                model: config.model,
                options: .init(temperature: 0.2, num_predict: 200)
            )
            let json = extractJSON(from: response)
            guard let jsonString = json else { return [] }
            let decoded = decodeLearnings(from: jsonString)
            guard !decoded.isEmpty else { return [] }

            let lastUserMessage = filteredMessages.last(where: { $0.role == .user })
            let timestamp = lastUserMessage?.timestamp ?? conversation.updatedAt

            return decoded.prefix(config.maxLearnings).compactMap { item in
                let rule = item.rule.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !rule.isEmpty else { return nil }
                guard LearningRuleNormalizer.isActionable(rule) else { return nil }

                let confidence = min(max(item.confidence ?? 0.7, 0.0), 1.0)
                guard confidence >= config.minConfidence else { return nil }

                return Candidate(
                    rule: rule,
                    type: item.type ?? .implicit,
                    confidence: confidence,
                    pattern: "semantic",
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
        You are extracting reusable user preferences from a conversation.
        Only output portable rules about style, tools, constraints, or communication.
        Ignore task-specific requests, questions, or transient goals.
        Return at most \(config.maxLearnings) learnings.

        Return JSON only in this exact format:
        {"learnings":[{"rule":"...","type":"correction|positive|implicit","confidence":0.0}]}
        Do not wrap the JSON in markdown or code fences.

        Conversation:
        \(transcript)
        """
    }

    private func extractJSON(from response: String) -> String? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}") else {
            return nil
        }
        return String(response[start...end])
    }

    private func decodeLearnings(from json: String) -> [LLMItem] {
        guard let data = json.data(using: .utf8) else { return [] }

        if let response = try? JSONDecoder().decode(LLMResponse.self, from: data) {
            return response.learnings
        }

        if let items = try? JSONDecoder().decode([LLMItem].self, from: data) {
            return items
        }

        return []
    }
}

private struct LLMResponse: Decodable {
    let learnings: [LLMItem]
}

private struct LLMItem: Decodable {
    let rule: String
    let type: LearningType?
    let confidence: Float?

    enum CodingKeys: String, CodingKey {
        case rule
        case type
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rule = (try? container.decode(String.self, forKey: .rule)) ?? ""

        if let typeString = try? container.decode(String.self, forKey: .type) {
            let normalized = typeString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            type = LearningType(rawValue: normalized)
        } else {
            type = try? container.decode(LearningType.self, forKey: .type)
        }

        if let confidenceValue = try? container.decode(Float.self, forKey: .confidence) {
            confidence = confidenceValue
        } else if let confidenceDouble = try? container.decode(Double.self, forKey: .confidence) {
            confidence = Float(confidenceDouble)
        } else if let confidenceString = try? container.decode(String.self, forKey: .confidence),
                  let parsed = Float(confidenceString) {
            confidence = parsed
        } else {
            confidence = nil
        }
    }
}
