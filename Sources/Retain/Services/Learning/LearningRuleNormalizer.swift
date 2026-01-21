import Foundation

enum LearningRuleNormalizer {
    static func normalize(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let collapsed = lowercased.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return collapsed
    }

    static func isActionable(_ rule: String) -> Bool {
        let normalized = normalize(rule)
        guard normalized.count >= 8 else { return false }

        let blockedPrefixes = [
            "i need",
            "i want",
            "i think",
            "can you",
            "could you",
            "what is",
            "how do",
            "explain",
            "please help"
        ]

        if blockedPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return false
        }

        if shouldDropRule(normalized) {
            return false
        }

        return true
    }

    static func shouldStoreLearning(rule: String, type: LearningType, confidence: Float) -> Bool {
        if shouldDropRule(rule) {
            return false
        }

        if !isActionable(rule) {
            return false
        }

        switch type {
        case .correction:
            return true
        case .positive, .implicit:
            if confidence < 0.6 {
                return false
            }
            return hasPreferenceMarker(rule)
        }
    }

    static func hasPreferenceMarker(_ rule: String) -> Bool {
        let normalized = normalize(rule)
        if normalized.hasSuffix("?") {
            return false
        }

        let patterns = [
            #"\bprefer\b"#,
            #"\bpreferred\b"#,
            #"\balways\b"#,
            #"\bnever\b"#,
            #"\bavoid\b"#,
            #"\bdo not\b"#,
            #"\bdon't\b"#,
            #"\bmust\b"#,
            #"\bshould\b"#,
            #"\buse\b.+\binstead\b"#,
            #"\binstead of\b"#,
            #"\bbetter to\b"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: normalized, options: [], range: NSRange(normalized.startIndex..., in: normalized)) != nil {
                return true
            }
        }

        return false
    }

    static func isTaskSpecific(_ rule: String) -> Bool {
        let normalized = normalize(rule)

        let pathOrUriPatterns = [
            #"(?:^|\s)(~?/|\.{1,2}/)[^\s]+"#,                 // Unix-like relative/absolute paths
            #"\b[a-zA-Z]:\\[^\s]+"#,                         // Windows paths
            #"(?:https?://|www\.)\S+"#,                      // URLs
            #"\b[a-z][a-z0-9+.-]*://\S+"#,                   // Any URI scheme (e.g., ui://)
            #"\btemplateuri\b\s*[:=]"#,                      // templateUri key references
            #"#\d{3,}\b"#,                                   // issue/task IDs like #1234
            #"\b[A-Z]{2,}-\d+\b"#,                           // JIRA-style IDs
            #"\bhtml\s*/\s*css\b"#,                          // explicit html/css references
            #"\.(html|css|js|ts|tsx|jsx|swift|py|rb|go|rs|java|kt|json|yaml|yml|toml|md|sql|csv|xml|graphql|sh)\b"#
        ]

        for pattern in pathOrUriPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: normalized, options: [], range: NSRange(normalized.startIndex..., in: normalized)) != nil {
                return true
            }
        }

        let systemPatterns = [
            #"\bsemantic mode\b"#,
            #"\bdeterministic\b"#,
            #"\bfallback\b"#,
            #"\bindex(?:ing)?\b"#,
            #"\bembedding(?:s)?\b"#,
            #"\bsqlite\b"#,
            #"\bschema\b"#,
            #"\bmigration\b"#,
            #"\bsync\b"#,
            #"\bnetwork error\b"#,
            #"\bapi error\b"#,
            #"\bgemini\b"#,
            #"\bclaude\b"#,
            #"\bcodex\b"#
        ]

        for pattern in systemPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: normalized, options: [], range: NSRange(normalized.startIndex..., in: normalized)) != nil {
                return true
            }
        }

        return false
    }

    static func shouldDropRule(_ rule: String) -> Bool {
        let normalized = normalize(rule)
        if isSystemInternal(normalized) {
            return true
        }
        return shouldDropTaskSpecific(normalized)
    }

    static func shouldDropTaskSpecific(_ rule: String) -> Bool {
        let normalized = normalize(rule)
        guard isTaskSpecific(normalized) else { return false }

        let hardPrefixes = ["always ", "never ", "only "]
        let hasHardPrefix = hardPrefixes.contains(where: { normalized.hasPrefix($0) })
        guard hasHardPrefix else { return false }

        let pathOrUriPatterns = [
            #"(?:^|\s)(~?/|\.{1,2}/)[^\s]+"#,
            #"\b[a-zA-Z]:\\[^\s]+"#,
            #"(?:https?://|www\.)\S+"#,
            #"\b[a-z][a-z0-9+.-]*://\S+"#,
            #"\btemplateuri\b\s*[:=]"#,
            #"\bhtml\s*/\s*css\b"#,
            #"\.(html|css|js|ts|tsx|jsx|swift|py|rb|go|rs|java|kt|json|yaml|yml|toml|md|sql|csv|xml|graphql|sh)\b"#
        ]

        for pattern in pathOrUriPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: normalized, options: [], range: NSRange(normalized.startIndex..., in: normalized)) != nil {
                return true
            }
        }

        return false
    }

    private static func isSystemInternal(_ normalized: String) -> Bool {
        let systemPatterns = [
            #"\bgemini\b"#,
            #"\bclaude\b"#,
            #"\bcodex\b"#,
            #"\bsemantic\b"#,
            #"\bdeterministic\b"#,
            #"\bembedding(?:s)?\b"#,
            #"\bindex(?:ing)?\b"#,
            #"\bsqlite\b"#,
            #"\bdatabase\b"#,
            #"\bmigration\b"#,
            #"\bschema\b"#,
            #"\bsync\b"#,
            #"\bapi error\b"#,
            #"\bnetwork error\b"#,
            #"\bsetupcomplete\b"#,
            #"\btooling\b"#,
            #"\bworkflow det\b"#
        ]

        for pattern in systemPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: normalized, options: [], range: NSRange(normalized.startIndex..., in: normalized)) != nil {
                return true
            }
        }

        return false
    }
}
