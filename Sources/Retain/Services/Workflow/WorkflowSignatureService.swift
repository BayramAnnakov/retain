import Foundation

/// Background workflow signature processing + aggregation
final class WorkflowSignatureService {
    private let repository: ConversationRepository
    private let workflowRepository: WorkflowSignatureRepository
    private let extractor: WorkflowSignatureExtractor
    private var geminiExtractor: GeminiWorkflowSignatureExtractor?

    init(
        repository: ConversationRepository = ConversationRepository(),
        workflowRepository: WorkflowSignatureRepository = WorkflowSignatureRepository(),
        extractor: WorkflowSignatureExtractor = WorkflowSignatureExtractor()
    ) {
        self.repository = repository
        self.workflowRepository = workflowRepository
        self.extractor = extractor
    }

    func updateGeminiConfiguration(apiKey: String, model: String, enabled: Bool) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !trimmedKey.isEmpty else {
            geminiExtractor = nil
            return
        }
        geminiExtractor = GeminiWorkflowSignatureExtractor(apiKey: trimmedKey, model: model)
    }

    func scanConversation(_ conversation: Conversation) async {
        guard let messages = try? repository.fetchMessages(conversationId: conversation.id) else { return }
        if let geminiExtractor {
            if let candidate = await geminiExtractor.extractSignature(conversation: conversation, messages: messages) {
                await upsert(candidate: candidate, conversation: conversation)
                return
            }
        }

        guard let candidate = extractor.extractSignature(conversation: conversation, messages: messages) else { return }
        await upsert(candidate: candidate, conversation: conversation)
    }

    private func upsert(candidate: WorkflowSignatureCandidate, conversation: Conversation) async {
        let context = [
            conversation.title,
            conversation.summary,
            conversation.previewText,
            candidate.snippet
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        if WorkflowSignatureRefiner.shouldExcludeCandidate(
            action: candidate.action,
            artifact: candidate.artifact,
            domains: candidate.domains,
            snippet: candidate.snippet,
            context: context
        ) {
            return
        }

        let refinedArtifact = WorkflowSignatureRefiner.refineArtifact(
            action: candidate.action,
            artifact: candidate.artifact,
            domains: candidate.domains,
            context: context
        )

        let artifact = refinedArtifact ?? candidate.artifact
        let domains = candidate.domains.sorted()
        let signatureValue = "\(candidate.action)|\(artifact)|\(domains.joined(separator: ","))"

        let signature = WorkflowSignature(
            conversationId: conversation.id,
            signature: signatureValue,
            action: candidate.action,
            artifact: artifact,
            domains: domains.joined(separator: ","),
            snippet: candidate.snippet,
            version: candidate.version,
            createdAt: conversation.createdAt,
            updatedAt: Date(),
            sourceQueueId: nil,
            confidence: candidate.confidence,
            source: candidate.source,
            detectorVersion: candidate.detectorVersion,
            isPriming: candidate.isPriming
        )

        do {
            try await workflowRepository.upsert(signature)
        } catch {
            print("Failed to upsert workflow signature: \(error)")
        }
    }
    
    func scanConversations(ids: Set<UUID>) async {
        for id in ids {
            if let conversation = try? repository.fetch(id: id) {
                await scanConversation(conversation)
            }
        }
    }

    func scanAllConversations() async {
        let conversations = (try? repository.fetchAll()) ?? []
        for conversation in conversations {
            await scanConversation(conversation)
        }
    }

    func resetAndScanAllConversations() async {
        do {
            try await workflowRepository.deleteAll()
        } catch {
            print("Failed to reset workflow signatures: \(error)")
        }
        await scanAllConversations()
    }

    func clearAllSignatures() async {
        do {
            try await workflowRepository.deleteAll()
        } catch {
            print("Failed to clear workflow signatures: \(error)")
        }
    }

    func scanMissingSignatures() async {
        let ids = (try? await workflowRepository.fetchConversationIdsMissingSignature()) ?? []
        for id in ids {
            if let conversation = try? repository.fetch(id: id) {
                await scanConversation(conversation)
            }
        }
    }

    func fetchTopClusters(limit: Int = 10) async -> [WorkflowCluster] {
        do {
            return try await workflowRepository.fetchTopClusters(
                limit: limit,
                excludingActions: ["prime", "other"],
                excludedArtifacts: ["none", "", "unknown"],
                minimumCount: 3
            )
        } catch {
            print("Failed to fetch workflow clusters: \(error)")
            return []
        }
    }

    func fetchPrimingClusters(limit: Int = 10) async -> [WorkflowCluster] {
        do {
            return try await workflowRepository.fetchClusters(action: "prime", limit: limit)
        } catch {
            print("Failed to fetch priming clusters: \(error)")
            return []
        }
    }
}
