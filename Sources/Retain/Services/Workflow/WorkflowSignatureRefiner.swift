import Foundation

enum WorkflowSignatureRefiner {
    private static let topicActions: Set<String> = ["prepare", "organize"]
    private static let genericArtifacts: Set<String> = ["workflow", "plan", "materials"]
    private static let weakArtifactActions: Set<String> = ["fix", "debug"]
    private static let oneOffPhrases: [String] = [
        "one-off",
        "one off",
        "one-time",
        "one time",
        "one time only",
        "single use",
        "single-use",
        "not repeatable",
        "not reusable",
        "one-off fix",
        "one-time fix",
        "quick fix",
        "hotfix",
        "temporary",
        "ad hoc",
        "just once",
        "only once"
    ]
    private static let stopwords: Set<String> = [
        "a", "an", "and", "or", "the", "to", "for", "of", "in", "on", "with", "from", "at", "by", "as",
        "is", "are", "was", "were", "be", "been", "being",
        "i", "you", "we", "they", "he", "she", "it", "my", "our", "your", "their",
        "this", "that", "these", "those", "please", "help",
        "create", "make", "build", "write", "draft", "generate", "compose", "summarize", "summarise",
        "review", "fix", "debug", "analyze", "analyse", "analysis", "workflow", "plan", "planning",
        "organize", "organise", "prepare", "research", "design", "extract", "report", "notes", "summary",
        "proposal", "deck", "spec", "documentation", "docs", "prompt", "post", "message", "messages",
        "request", "requests", "project", "projects", "context", "learning", "extraction",
        "engineering", "product", "marketing", "sales", "meeting", "content", "research", "support", "translation"
    ]

    static func refineArtifact(
        action: String,
        artifact: String?,
        domains: [String],
        context: String
    ) -> String? {
        guard let artifact else { return nil }
        let normalizedAction = normalizeToken(action)
        let normalizedArtifact = normalizeToken(artifact)

        guard topicActions.contains(normalizedAction),
              genericArtifacts.contains(normalizedArtifact) else {
            return artifact
        }

        guard let topic = topicToken(
            from: context,
            domains: domains,
            action: normalizedAction,
            artifact: normalizedArtifact
        ) else {
            return artifact
        }

        return "\(normalizedArtifact)_\(topic)"
    }

    static func deriveArtifactIfNeeded(
        action: String,
        artifact: String?,
        domains: [String],
        context: String,
        snippet: String?
    ) -> String? {
        guard let artifact, !artifact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let combined = [context, snippet].compactMap { $0 }.joined(separator: " ")
            let topic = topicToken(
                from: combined,
                domains: domains,
                action: normalizeToken(action),
                artifact: ""
            )
            return topic
        }
        return artifact
    }

    static func shouldExcludeCandidate(
        action: String,
        artifact: String?,
        domains: [String],
        snippet: String?,
        context: String
    ) -> Bool {
        let normalizedAction = normalizeToken(action)
        let normalizedArtifact = artifact?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if weakArtifactActions.contains(normalizedAction),
           (normalizedArtifact == nil || normalizedArtifact?.isEmpty == true) {
            return true
        }

        let combined = [snippet, context].compactMap { $0 }.joined(separator: " ").lowercased()
        if oneOffPhrases.contains(where: { combined.contains($0) }) {
            return true
        }

        return false
    }

    private static func topicToken(
        from context: String,
        domains: [String],
        action: String,
        artifact: String
    ) -> String? {
        let domainSet = Set(domains.map { normalizeToken($0) })
        for token in tokenize(context) {
            let normalized = normalizeToken(token)
            if normalized.count < 3 {
                continue
            }
            if stopwords.contains(normalized) {
                continue
            }
            if normalized == action || normalized == artifact {
                continue
            }
            if domainSet.contains(normalized) {
                continue
            }
            return normalized
        }
        return nil
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normalizeToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}
