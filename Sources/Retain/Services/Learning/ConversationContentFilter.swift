import Foundation

enum ConversationContentFilter {
    private static let metaPatterns = [
        #"\baudit\b"#,
        #"\breview\b"#,
        #"\bplan\b"#,
        #"\bplanning\b"#,
        #"\blearning extraction\b"#,
        #"\broadmap\b"#,
        #"\bchangelog\b"#,
        #"\bcommit\b"#,
        #"\bpr\b"#,
        #"\bpull request\b"#,
        #"\bbugfix\b"#,
        #"\bbug fix\b"#,
        #"\brelease notes\b"#,
        #"\bpostmortem\b"#,
        #"\bretrospective\b"#
    ]

    static func isMeta(textParts: [String?]) -> Bool {
        let combined = textParts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        guard !combined.isEmpty else { return false }

        for pattern in metaPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: combined, options: [], range: NSRange(combined.startIndex..., in: combined)) != nil {
                return true
            }
        }

        return false
    }

    static func isMeta(conversation: Conversation, messages: [Message]) -> Bool {
        let firstUser = messages.first(where: { $0.isUserMessage })?.content
        return isMeta(textParts: [
            conversation.title,
            conversation.summary,
            conversation.previewText,
            firstUser
        ])
    }
}
