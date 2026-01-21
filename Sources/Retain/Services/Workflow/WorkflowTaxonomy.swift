import Foundation

enum WorkflowTaxonomy {
    static let allowedActions: Set<String> = [
        "analyze",
        "debug",
        "design",
        "extract",
        "fix",
        "organize",
        "plan",
        "prepare",
        "research",
        "review",
        "summarize",
        "translate",
        "write",
        "none"
    ]

    static let allowedArtifacts: Set<String> = [
        "analysis",
        "checklist",
        "deck",
        "documentation",
        "notes",
        "plan",
        "post",
        "proposal",
        "report",
        "spec",
        "summary",
        "timestamps",
        "transcript",
        "workflow",
        "none"
    ]

    static let allowedDomains: Set<String> = [
        "content",
        "engineering",
        "marketing",
        "meeting",
        "product",
        "research",
        "sales",
        "support",
        "translation"
    ]

    static let minConfidence: Float = 0.65

    struct SanitizedWorkflow {
        let action: String
        let artifact: String?
        let domains: [String]
    }

    static func sanitize(
        action: String,
        artifact: String?,
        domains: [String]?,
        confidence: Float?
    ) -> SanitizedWorkflow? {
        let normalizedAction = canonicalAction(action)
        guard let normalizedAction else { return nil }
        if normalizedAction == "none" {
            return nil
        }

        if let confidence, confidence < minConfidence {
            return nil
        }

        let normalizedArtifact = canonicalArtifact(artifact)
        let normalizedDomains = canonicalDomains(domains)

        if normalizedArtifact == nil && normalizedDomains.isEmpty {
            return nil
        }

        return SanitizedWorkflow(
            action: normalizedAction,
            artifact: normalizedArtifact,
            domains: normalizedDomains
        )
    }

    private static func canonicalAction(_ value: String) -> String? {
        let normalized = normalizeToken(value)
        if normalized.isEmpty {
            return nil
        }

        let aliases: [String: String] = [
            "summarization": "summarize",
            "summary": "summarize",
            "analyse": "analyze",
            "analysis": "analyze",
            "draft": "write",
            "compose": "write",
            "create": "write",
            "generate": "write",
            "prepare": "prepare",
            "prep": "prepare",
            "organise": "organize",
            "transcribe": "extract",
            "extract_information": "extract",
            "skip": "none",
            "candidate": "none"
        ]

        let mapped = aliases[normalized] ?? normalized
        guard allowedActions.contains(mapped) else { return nil }
        return mapped
    }

    private static func canonicalArtifact(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizeToken(value)
        if normalized.isEmpty {
            return nil
        }

        let aliases: [String: String] = [
            "presentation": "deck",
            "slide_deck": "deck",
            "docs": "documentation",
            "doc": "documentation",
            "requirements": "spec",
            "transcripts": "transcript",
            "minutes": "notes",
            "post": "post"
        ]

        let mapped = aliases[normalized] ?? normalized
        if mapped == "none" {
            return nil
        }
        return allowedArtifacts.contains(mapped) ? mapped : nil
    }

    private static func canonicalDomains(_ values: [String]?) -> [String] {
        guard let values else { return [] }
        var output: [String] = []
        for value in values {
            let normalized = normalizeToken(value)
            if normalized.isEmpty {
                continue
            }
            let aliases: [String: String] = [
                "eng": "engineering",
                "dev": "engineering",
                "product_management": "product",
                "bizdev": "sales",
                "customer_support": "support"
            ]
            let mapped = aliases[normalized] ?? normalized
            if allowedDomains.contains(mapped) {
                output.append(mapped)
            }
        }
        return Array(Set(output)).sorted()
    }

    private static func normalizeToken(_ value: String) -> String {
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}
