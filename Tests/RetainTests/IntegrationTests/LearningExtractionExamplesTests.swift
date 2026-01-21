import XCTest
@testable import Retain

final class LearningExtractionExamplesTests: XCTestCase {
    func testExtractDeterministicExamples() async throws {
        let detector = CorrectionDetector()
        let samples: [(Conversation, [Message])]
        if ProcessInfo.processInfo.environment["OMNI_USE_LIVE_CONVERSATIONS"] == "1" {
            let liveSamples = loadSampleConversations(limit: 3)
            samples = liveSamples.isEmpty ? [syntheticConversation()] : liveSamples
        } else {
            samples = [syntheticConversation()]
        }

        var detections: [CorrectionDetector.DetectionResult] = []
        for (conversation, messages) in samples {
            detections.append(contentsOf: detector.analyzeConversation(conversation, messages: messages))
        }

        let examples = dedupedExamples(from: detections, limit: 5)
        guard !examples.isEmpty else {
            throw XCTSkip("No deterministic learnings found in sample conversations")
        }

        print("Deterministic learnings (examples):")
        for example in examples {
            print("- \(example)")
        }
    }

    func testExtractGeminiExamples() async throws {
        // Requires GEMINI_API_KEY environment variable
        let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
        guard let apiKey = apiKey, !apiKey.isEmpty else {
            throw XCTSkip("GEMINI_API_KEY not set - set environment variable to run Gemini integration tests")
        }

        let extractor = await GeminiLearningExtractor(
            configuration: GeminiLearningExtractor.Configuration(
                minConfidence: 0.5,
                maxLearnings: 5,
                maxMessages: 18
            )
        )
        await extractor.updateConfiguration(apiKey: apiKey, model: "gemini-2.0-flash", minConfidence: 0.5)

        let samples = loadSampleConversations(limit: 5)
        var candidates: [GeminiLearningExtractor.Candidate] = []

        for sample in samples {
            candidates = await extractor.extractLearnings(from: sample.0, messages: sample.1)
            if !candidates.isEmpty {
                break
            }
        }

        if candidates.isEmpty {
            let fallback = syntheticConversation()
            candidates = await extractor.extractLearnings(from: fallback.0, messages: fallback.1)
        }

        guard !candidates.isEmpty else {
            throw XCTSkip("Gemini extractor returned no learnings for available conversations")
        }

        print("Gemini learnings:")
        for candidate in candidates.prefix(5) {
            print("- \(candidate.rule) (\(Int(candidate.confidence * 100))%)")
        }
    }

    // Legacy test for Ollama - skipped if not available
    func testExtractSemanticExamples() async throws {
        let ollama = OllamaService(
            configuration: OllamaService.Configuration(timeout: 120)
        )
        guard await ollama.isAvailable() else {
            throw XCTSkip("Ollama not running - use testExtractGeminiExamples for semantic extraction")
        }

        guard let model = await pickSemanticModel(ollama) else {
            throw XCTSkip("No local Ollama model available for semantic extraction")
        }

        let extractor = SemanticLearningExtractor(
            ollama: ollama,
            configuration: SemanticLearningExtractor.Configuration(
                model: model,
                minConfidence: 0.5,
                maxLearnings: 5,
                maxMessages: 18
            )
        )

        let samples = loadSampleConversations(limit: 5)
        var candidates: [SemanticLearningExtractor.Candidate] = []

        for sample in samples {
            candidates = await extractor.extractLearnings(from: sample.0, messages: sample.1)
            if !candidates.isEmpty {
                break
            }
        }

        if candidates.isEmpty {
            let fallback = syntheticConversation()
            candidates = await extractor.extractLearnings(from: fallback.0, messages: fallback.1)
        }

        guard !candidates.isEmpty else {
            throw XCTSkip("Semantic extractor returned no learnings for available conversations")
        }

        print("Semantic learnings (model: \(model)):")
        for candidate in candidates.prefix(5) {
            print("- \(candidate.rule) (\(Int(candidate.confidence * 100))%)")
        }
    }

    private func loadSampleConversations(limit: Int) -> [(Conversation, [Message])] {
        var results: [(Conversation, [Message])] = []

        let claudeParser = ClaudeCodeParser()
        let claudeFiles = claudeParser.discoverConversationFiles().prefix(limit)
        for url in claudeFiles {
            if let parsed = try? claudeParser.parseFile(at: url) {
                results.append(parsed)
            }
        }

        if results.count >= limit {
            return results
        }

        let codexParser = CodexParser()
        if let codexSessions = try? codexParser.parseSessionFiles() {
            results.append(contentsOf: codexSessions.prefix(limit))
        }

        return results
    }

    private func dedupedExamples(
        from detections: [CorrectionDetector.DetectionResult],
        limit: Int
    ) -> [String] {
        var seen = Set<String>()
        var examples: [String] = []

        for detection in detections {
            let normalized = LearningRuleNormalizer.normalize(detection.extractedRule)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            examples.append("\(detection.extractedRule) (\(Int(detection.confidence * 100))%)")
            if examples.count >= limit {
                break
            }
        }

        return examples
    }

    private func pickSemanticModel(_ ollama: OllamaService) async -> String? {
        let preferred = [
            "gemma3:4b",
            "gemma3:1b",
            "llama3.1:8b",
            "gpt-oss:20b"
        ]

        guard let models = try? await ollama.listModels() else {
            return nil
        }

        for name in preferred {
            if models.contains(where: { $0.name.contains(name) }) {
                return name
            }
        }

        return models.first?.name
    }

    private func syntheticConversation() -> (Conversation, [Message]) {
        let conversation = Conversation(
            provider: .codex,
            sourceType: .cli,
            title: "Semantic Extraction Sample",
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 3
        )

        let messages = [
            Message(
                conversationId: conversation.id,
                role: .user,
                content: "Please keep responses concise, use numbered lists, and avoid emojis.",
                timestamp: Date()
            ),
            Message(
                conversationId: conversation.id,
                role: .assistant,
                content: "Understood. I will keep answers concise and structured.",
                timestamp: Date()
            ),
            Message(
                conversationId: conversation.id,
                role: .user,
                content: "Prefer TypeScript examples and include tests when relevant.",
                timestamp: Date()
            )
        ]

        return (conversation, messages)
    }
}
