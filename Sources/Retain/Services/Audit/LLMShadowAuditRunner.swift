import Foundation
import GRDB

/// Shadow audit runner to compare deterministic vs CLI LLM extraction quality.
enum LLMShadowAuditRunner {
    private static let auditFlag = "--audit-llm"
    private static let dbFlag = "--db"
    private static let sampleFlag = "--sample"
    private static let seedFlag = "--seed"
    private static let outputFlag = "--output-dir"
    private static let allowCloudFlag = "--allow-cloud"
    private static let auditMaxPayloadBytes = 250_000

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains(auditFlag) else { return false }

        let dbURL = resolveDatabaseURL(from: arguments)
        let sampleSize = parseIntFlag(sampleFlag, arguments: arguments, defaultValue: 30)
        let seed = parseIntFlag(seedFlag, arguments: arguments, defaultValue: 42)
        let outputDir = resolveOutputDir(from: arguments)
        let allowCloud = arguments.contains(allowCloudFlag)

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                try await runAudit(
                    dbURL: dbURL,
                    sampleSize: sampleSize,
                    seed: UInt64(seed),
                    outputDir: outputDir,
                    allowCloud: allowCloud
                )
                semaphore.signal()
            } catch {
                fputs("LLM shadow audit failed: \(error)\n", stderr)
                exit(1)
            }
        }
        semaphore.wait()
        return true
    }

    private static func resolveDatabaseURL(from arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: dbFlag), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1])
        }

        let fileManager = FileManager.default
        let appSupportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let directoryURL = appSupportURL?.appendingPathComponent("Retain", isDirectory: true)
        return directoryURL?.appendingPathComponent("retain.sqlite")
            ?? URL(fileURLWithPath: "retain.sqlite")
    }

    private static func resolveOutputDir(from arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: outputFlag), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        return URL(fileURLWithPath: "reports/llm_shadow/\(stamp)", isDirectory: true)
    }

    private static func parseIntFlag(_ flag: String, arguments: [String], defaultValue: Int) -> Int {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return defaultValue
        }
        return Int(arguments[index + 1]) ?? defaultValue
    }

    private struct ConversationBundle {
        let conversation: Conversation
        let messages: [Message]
    }

    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed == 0 ? 0x4d595df4d0f33173 : seed
        }

        mutating func next() -> UInt64 {
            state = 6364136223846793005 &* state &+ 1
            return state
        }
    }

    private struct LearningAuditRow: Codable {
        let variant: String
        let payloadMode: String
        let conversationId: String
        let type: String
        let rule: String
        let normalizedRule: String
        let confidence: Double
        let actionable: Bool
        let taskSpecific: Bool
    }

    private struct WorkflowAuditRow: Codable {
        let variant: String
        let payloadMode: String
        let conversationId: String
        let signature: String
        let action: String
        let artifact: String
        let domains: [String]
        let confidence: Double?
        let isPriming: Bool
    }

    private struct AuditSummary: Codable {
        let sampleSize: Int
        let seed: UInt64
        let providers: [String: Int]
        let deterministic: VariantSummary
        let llmMinimized: VariantSummary
        let llmExpanded: VariantSummary
    }

    private struct VariantSummary: Codable {
        let learnings: LearningSummary
        let automations: AutomationSummary
        let droppedQueueItems: Int
    }

    private struct LearningSummary: Codable {
        let total: Int
        let byType: [String: Int]
        let actionablePct: Double
        let taskSpecificPct: Double
        let uniqueRuleCount: Int
        let duplicationPct: Double
    }

    private struct AutomationSummary: Codable {
        let total: Int
        let uniqueSignatures: Int
        let avgRecurrence: Double
        let primingPct: Double
    }

    private static func runAudit(
        dbURL: URL,
        sampleSize: Int,
        seed: UInt64,
        outputDir: URL,
        allowCloud: Bool
    ) async throws {
        let database = try AppDatabase.open(path: dbURL)
        let repository = ConversationRepository(database: database)
        let conversations = try repository.fetchAll()

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let bundles = try sampleConversations(
            conversations: conversations,
            repository: repository,
            sampleSize: sampleSize,
            seed: seed
        )

        let sampleIds = bundles.map { $0.conversation.id.uuidString }
        try writeJSON(sampleIds, to: outputDir.appendingPathComponent("sample_conversation_ids.json"))

        let providerCounts = bundles.reduce(into: [String: Int]()) { result, bundle in
            let key = bundle.conversation.provider.rawValue
            result[key, default: 0] += 1
        }

        let deterministicResults = runDeterministic(bundles: bundles)
        try writeJSON(deterministicResults.learnings, to: outputDir.appendingPathComponent("learnings_deterministic.json"))
        try writeJSON(deterministicResults.workflows, to: outputDir.appendingPathComponent("automations_deterministic.json"))

        let cliService = CLILLMService()
        await cliService.detectCapabilities()

        let originalConsent = UserDefaults.standard.bool(forKey: "allowCloudAnalysis")
        if allowCloud {
            UserDefaults.standard.set(true, forKey: "allowCloudAnalysis")
        }
        defer {
            if allowCloud {
                UserDefaults.standard.set(originalConsent, forKey: "allowCloudAnalysis")
            }
        }

        let llmMin = try await runLLM(
            bundles: bundles,
            cliService: cliService,
            payloadMode: .minimized
        )
        try writeJSON(llmMin.learnings, to: outputDir.appendingPathComponent("learnings_llm_minimized.json"))
        try writeJSON(llmMin.workflows, to: outputDir.appendingPathComponent("automations_llm_minimized.json"))

        let llmExpanded = try await runLLM(
            bundles: bundles,
            cliService: cliService,
            payloadMode: .expanded
        )
        try writeJSON(llmExpanded.learnings, to: outputDir.appendingPathComponent("learnings_llm_expanded.json"))
        try writeJSON(llmExpanded.workflows, to: outputDir.appendingPathComponent("automations_llm_expanded.json"))

        let summary = AuditSummary(
            sampleSize: bundles.count,
            seed: seed,
            providers: providerCounts,
            deterministic: summarizeVariant(deterministicResults, dropped: deterministicResults.droppedQueueIds.count),
            llmMinimized: summarizeVariant(llmMin, dropped: llmMin.droppedQueueIds.count),
            llmExpanded: summarizeVariant(llmExpanded, dropped: llmExpanded.droppedQueueIds.count)
        )

        try writeJSON(summary, to: outputDir.appendingPathComponent("summary.json"))
    }

    private static func sampleConversations(
        conversations: [Conversation],
        repository: ConversationRepository,
        sampleSize: Int,
        seed: UInt64
    ) throws -> [ConversationBundle] {
        guard sampleSize > 0 else { return [] }

        var rng = SeededGenerator(seed: seed)
        let shuffled = conversations.shuffled(using: &rng)
        var bundles: [ConversationBundle] = []

        for conversation in shuffled {
            if bundles.count >= sampleSize {
                break
            }
            guard let messages = try? repository.fetchMessages(conversationId: conversation.id),
                  messages.contains(where: { $0.isUserMessage }) else {
                continue
            }
            if ConversationContentFilter.isMeta(conversation: conversation, messages: messages) {
                continue
            }

            bundles.append(ConversationBundle(conversation: conversation, messages: messages))
        }

        return bundles
    }

    private static func runDeterministic(bundles: [ConversationBundle]) -> (learnings: [LearningAuditRow], workflows: [WorkflowAuditRow], droppedQueueIds: Set<String>) {
        let detector = CorrectionDetector(configuration: .init(minConfidence: 0.8, enablePositiveFeedback: false))
        let workflowExtractor = WorkflowSignatureExtractor()

        var learningRows: [LearningAuditRow] = []
        var workflowRows: [WorkflowAuditRow] = []

        for bundle in bundles {
            let conversation = bundle.conversation
            let messages = bundle.messages

            let detections = detector.analyzeConversation(conversation, messages: messages)
            for detection in detections {
                let rule = detection.extractedRule
                if LearningRuleNormalizer.shouldDropRule(rule) {
                    continue
                }
                let normalized = LearningRuleNormalizer.normalize(rule)
                let actionable = LearningRuleNormalizer.isActionable(rule)
                let taskSpecific = LearningRuleNormalizer.isTaskSpecific(rule)

                learningRows.append(
                    LearningAuditRow(
                        variant: "deterministic",
                        payloadMode: "deterministic",
                        conversationId: conversation.id.uuidString,
                        type: detection.type.rawValue,
                        rule: rule,
                        normalizedRule: normalized,
                        confidence: Double(detection.confidence),
                        actionable: actionable,
                        taskSpecific: taskSpecific
                    )
                )
            }

            if let candidate = workflowExtractor.extractSignature(conversation: conversation, messages: messages) {
                workflowRows.append(
                    WorkflowAuditRow(
                        variant: "deterministic",
                        payloadMode: "deterministic",
                        conversationId: conversation.id.uuidString,
                        signature: candidate.signature,
                        action: candidate.action,
                        artifact: candidate.artifact,
                        domains: candidate.domains,
                        confidence: candidate.confidence,
                        isPriming: candidate.isPriming
                    )
                )
            }
        }

        return (learningRows, workflowRows, [])
    }

    private static func runLLM(
        bundles: [ConversationBundle],
        cliService: CLILLMService,
        payloadMode: CLILLMService.PayloadMode
    ) async throws -> (learnings: [LearningAuditRow], workflows: [WorkflowAuditRow], droppedQueueIds: Set<String>) {
        let conversationData = bundles.map { bundle in
            ConversationData(
                id: bundle.conversation.id.uuidString,
                title: bundle.conversation.title,
                messages: bundle.messages.map { MessageData(id: $0.id.uuidString, role: $0.role.rawValue, content: $0.content) }
            )
        }
        let messageMap = Dictionary(uniqueKeysWithValues: bundles.map { ($0.conversation.id.uuidString, $0.messages) })

        let learningQueueItems = bundles.map {
            AnalysisQueueItem(conversationId: $0.conversation.id, analysisType: AnalysisType.learning.rawValue)
        }
        let workflowQueueItems = bundles.map {
            AnalysisQueueItem(conversationId: $0.conversation.id, analysisType: AnalysisType.workflow.rawValue)
        }

        let learningResults: BatchRunResult<LearningBatchResult> = try await runLLMInBatches(
            cliService: cliService,
            queueItems: learningQueueItems,
            conversations: conversationData,
            analysisType: .learning,
            payloadMode: payloadMode,
            maxPayloadBytes: auditMaxPayloadBytes
        )

        let workflowResults: BatchRunResult<WorkflowBatchResult> = try await runLLMInBatches(
            cliService: cliService,
            queueItems: workflowQueueItems,
            conversations: conversationData,
            analysisType: .workflow,
            payloadMode: payloadMode,
            maxPayloadBytes: auditMaxPayloadBytes
        )

        let learningRows = buildLearningRows(
            batchResults: learningResults.results,
            queueMap: learningResults.queueMap,
            payloadMode: payloadMode,
            messageMap: messageMap
        )

        let workflowRows = buildWorkflowRows(
            batchResults: workflowResults.results,
            queueMap: workflowResults.queueMap,
            payloadMode: payloadMode
        )

        let dropped = learningResults.droppedQueueIds.union(workflowResults.droppedQueueIds)

        return (learningRows, workflowRows, dropped)
    }

    private static func buildLearningRows(
        batchResults: [LearningBatchResult],
        queueMap: [String: String],
        payloadMode: CLILLMService.PayloadMode,
        messageMap: [String: [Message]]
    ) -> [LearningAuditRow] {
        var rows: [LearningAuditRow] = []

        for batch in batchResults {
            guard let convoId = queueMap[batch.queueId] else { continue }
            for learning in batch.learnings {
                let rule = learning.rule
                let learningType = LearningType(rawValue: learning.type) ?? .implicit
                if !LearningRuleNormalizer.shouldStoreLearning(
                    rule: rule,
                    type: learningType,
                    confidence: learning.confidence
                ) {
                    continue
                }
                if !evidenceIsValid(learning: learning, messages: messageMap[convoId] ?? []) {
                    continue
                }
                let normalized = LearningRuleNormalizer.normalize(rule)
                let actionable = LearningRuleNormalizer.isActionable(rule)
                let taskSpecific = LearningRuleNormalizer.isTaskSpecific(rule)

                rows.append(
                    LearningAuditRow(
                        variant: "llm",
                        payloadMode: payloadMode.rawValue,
                        conversationId: convoId,
                        type: learningType.rawValue,
                        rule: rule,
                        normalizedRule: normalized,
                        confidence: Double(learning.confidence),
                        actionable: actionable,
                        taskSpecific: taskSpecific
                    )
                )
            }
        }

        return rows
    }

    private static func evidenceIsValid(
        learning: LearningAnalysisResult.ExtractedLearning,
        messages: [Message]
    ) -> Bool {
        guard let evidence = learning.evidence?.trimmingCharacters(in: .whitespacesAndNewlines),
              !evidence.isEmpty else {
            return false
        }

        if evidence.count < 8 || evidence.count > 260 {
            return false
        }

        if let msgId = learning.messageId.flatMap({ UUID(uuidString: $0) }),
           let match = messages.first(where: { $0.id == msgId }) {
            return match.content.localizedCaseInsensitiveContains(evidence)
        }

        return messages.contains(where: { $0.content.localizedCaseInsensitiveContains(evidence) })
    }

    private static func buildWorkflowRows(
        batchResults: [WorkflowBatchResult],
        queueMap: [String: String],
        payloadMode: CLILLMService.PayloadMode
    ) -> [WorkflowAuditRow] {
        var rows: [WorkflowAuditRow] = []

        for batch in batchResults {
            guard let convoId = queueMap[batch.queueId] else { continue }
            guard let sanitized = WorkflowTaxonomy.sanitize(
                action: batch.action,
                artifact: batch.artifact,
                domains: batch.domains,
                confidence: batch.confidence
            ) else {
                continue
            }
            let domains = sanitized.domains
            let artifact = sanitized.artifact ?? ""
            let signature = "\(sanitized.action)|\(artifact)|\(domains.joined(separator: ","))".lowercased()
            let isPriming = sanitized.action == "prime"
            rows.append(
                WorkflowAuditRow(
                    variant: "llm",
                    payloadMode: payloadMode.rawValue,
                    conversationId: convoId,
                    signature: signature,
                    action: sanitized.action,
                    artifact: artifact,
                    domains: domains,
                    confidence: Double(batch.confidence),
                    isPriming: isPriming
                )
            )
        }

        return rows
    }

    private struct BatchRunResult<T: Decodable> {
        let results: [T]
        let queueMap: [String: String]
        let droppedQueueIds: Set<String>
    }

    private static func runLLMInBatches<T: Decodable>(
        cliService: CLILLMService,
        queueItems: [AnalysisQueueItem],
        conversations: [ConversationData],
        analysisType: AnalysisType,
        payloadMode: CLILLMService.PayloadMode,
        maxPayloadBytes: Int
    ) async throws -> BatchRunResult<T> {
        let queueMap = Dictionary(uniqueKeysWithValues: queueItems.map { ($0.id, $0.conversationId.uuidString) })
        let convoMap = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })

        var results: [T] = []
        var dropped: Set<String> = []

        func runBatch(items: [AnalysisQueueItem]) async throws {
            let convos = items.compactMap { convoMap[$0.conversationId.uuidString] }
            do {
                let result = try await cliService.runAnalysis(
                    tool: .claudeCode,
                    queueItems: items,
                    conversations: convos,
                    analysisType: analysisType,
                    payloadMode: payloadMode,
                    maxPayloadBytes: maxPayloadBytes
                )
                dropped.formUnion(result.droppedQueueIds)
                let data = Data(result.jsonOutput.utf8)
                let decoded = try JSONDecoder().decode([T].self, from: data)
                results.append(contentsOf: decoded)
            } catch let error as CLILLMService.CLIError {
                switch error {
                case .payloadTooLarge:
                    guard items.count > 1 else { throw error }
                    let mid = items.count / 2
                    let first = Array(items.prefix(mid))
                    let second = Array(items.suffix(from: mid))
                    try await runBatch(items: first)
                    try await runBatch(items: second)
                default:
                    throw error
                }
            }
        }

        try await runBatch(items: queueItems)

        return BatchRunResult(results: results, queueMap: queueMap, droppedQueueIds: dropped)
    }

    private static func summarizeVariant(
        _ variant: (learnings: [LearningAuditRow], workflows: [WorkflowAuditRow], droppedQueueIds: Set<String>),
        dropped: Int
    ) -> VariantSummary {
        let learningSummary = summarizeLearnings(variant.learnings)
        let workflowSummary = summarizeWorkflows(variant.workflows)
        return VariantSummary(
            learnings: learningSummary,
            automations: workflowSummary,
            droppedQueueItems: dropped
        )
    }

    private static func summarizeLearnings(_ rows: [LearningAuditRow]) -> LearningSummary {
        let total = rows.count
        var byType: [String: Int] = [:]
        var actionableCount = 0
        var taskSpecificCount = 0
        var uniqueRules = Set<String>()

        for row in rows {
            byType[row.type, default: 0] += 1
            if row.actionable { actionableCount += 1 }
            if row.taskSpecific { taskSpecificCount += 1 }
            uniqueRules.insert(row.normalizedRule.lowercased())
        }

        let actionablePct = total == 0 ? 0 : Double(actionableCount) / Double(total) * 100
        let taskSpecificPct = total == 0 ? 0 : Double(taskSpecificCount) / Double(total) * 100
        let duplicationPct = total == 0 ? 0 : Double(total - uniqueRules.count) / Double(total) * 100

        return LearningSummary(
            total: total,
            byType: byType,
            actionablePct: round(actionablePct * 10) / 10,
            taskSpecificPct: round(taskSpecificPct * 10) / 10,
            uniqueRuleCount: uniqueRules.count,
            duplicationPct: round(duplicationPct * 10) / 10
        )
    }

    private static func summarizeWorkflows(_ rows: [WorkflowAuditRow]) -> AutomationSummary {
        let total = rows.count
        let uniqueSignatures = Set(rows.map { $0.signature }).count
        let primingCount = rows.filter { $0.isPriming }.count
        let avgRecurrence = uniqueSignatures == 0 ? 0 : Double(total) / Double(uniqueSignatures)
        let primingPct = total == 0 ? 0 : Double(primingCount) / Double(total) * 100

        return AutomationSummary(
            total: total,
            uniqueSignatures: uniqueSignatures,
            avgRecurrence: round(avgRecurrence * 100) / 100,
            primingPct: round(primingPct * 10) / 10
        )
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }
}
