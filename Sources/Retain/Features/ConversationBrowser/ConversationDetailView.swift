import AppKit
import Foundation
import SwiftUI

/// Detail view showing conversation messages
struct ConversationDetailView: View {
    let conversation: Conversation
    @EnvironmentObject private var appState: AppState
    @State private var scrollToBottom = false
    private let maxContentWidth: CGFloat = 760

    // MARK: - Message Search State
    @State private var isSearchVisible = false
    @State private var messageSearchQuery = ""
    @State private var currentMatchIndex = 0
    @FocusState private var isSearchFocused: Bool

    // Cached search results (updated via debounced search)
    @State private var matchingMessageIds: [UUID] = []  // Ordered list for navigation
    @State private var matchingMessageIdSet: Set<UUID> = []  // Set for O(1) lookup
    @State private var searchDebounceTask: Task<Void, Never>?

    /// Current match message ID for scrolling
    private var currentMatchMessageId: UUID? {
        guard !matchingMessageIds.isEmpty,
              currentMatchIndex >= 0,
              currentMatchIndex < matchingMessageIds.count else {
            return nil
        }
        return matchingMessageIds[currentMatchIndex]
    }

    /// Perform search with debouncing
    private func performSearch(query: String) {
        // Cancel previous search
        searchDebounceTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)

        // Clear immediately if empty
        if trimmedQuery.isEmpty {
            matchingMessageIds = []
            matchingMessageIdSet = []
            currentMatchIndex = 0
            return
        }

        // Debounce: wait 150ms before searching
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            let lowercasedQuery = trimmedQuery.lowercased()
            let messages = appState.selectedMessages

            // Run search on background thread for large conversations
            let results: [UUID] = await Task.detached(priority: .userInitiated) {
                messages.compactMap { message in
                    guard message.content.localizedCaseInsensitiveContains(lowercasedQuery) else {
                        return nil
                    }
                    return message.id
                }
            }.value

            guard !Task.isCancelled else { return }

            matchingMessageIds = results
            matchingMessageIdSet = Set(results)
            currentMatchIndex = 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            ConversationHeader(
                conversation: conversation,
                onBackToLearnings: appState.hasLearnings(conversation) ? {
                    appState.sidebarSelection = .learnings
                    appState.activeView = .learnings
                } : nil
            )

            Divider()

            if appState.hasLearnings(conversation) {
                LearningHighlightBanner(
                    count: appState.conversationLearningCounts[conversation.id] ?? 0,
                    onReview: {
                        appState.sidebarSelection = .learnings
                        appState.activeView = .learnings
                    }
                )
                .padding(.horizontal)
                .padding(.vertical, Spacing.sm)

                Divider()
            }

            // Search bar
            if isSearchVisible {
                MessageSearchBar(
                    query: $messageSearchQuery,
                    currentIndex: $currentMatchIndex,
                    totalMatches: matchingMessageIds.count,
                    isFocused: $isSearchFocused,
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSearchVisible = false
                            messageSearchQuery = ""
                            matchingMessageIds = []
                            matchingMessageIdSet = []
                            currentMatchIndex = 0
                        }
                    }
                )
                .padding(.horizontal)
                .padding(.vertical, Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onChange(of: messageSearchQuery) { _, newValue in
                    performSearch(query: newValue)
                }

                Divider()
            }

            // Messages
            if appState.isLoadingMessages {
                Spacer()
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                            ForEach(appState.selectedMessages.filter { shouldDisplayMessage($0) }) { message in
                                // O(1) lookup using Set
                                let isMatch = matchingMessageIdSet.contains(message.id)
                                let isCurrentMatch = currentMatchMessageId == message.id

                                MessageBubble(
                                    message: message,
                                    provider: conversation.provider,
                                    searchHighlight: isMatch ? (isCurrent: isCurrentMatch, query: messageSearchQuery) : nil
                                )
                                    .id(message.id)
                            }
                        }
                        .frame(maxWidth: maxContentWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .onChange(of: appState.selectedMessages.count) { _, _ in
                        if scrollToBottom, let lastMessage = appState.selectedMessages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    // Scroll to current search match
                    .onChange(of: currentMatchMessageId) { _, newValue in
                        if let messageId = newValue {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(messageId, anchor: .center)
                            }
                        }
                    }
                    // Scroll when search results change
                    .onChange(of: matchingMessageIds) { _, _ in
                        if let messageId = currentMatchMessageId {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(messageId, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSearchVisible.toggle()
                        if isSearchVisible {
                            isSearchFocused = true
                        } else {
                            searchDebounceTask?.cancel()
                            messageSearchQuery = ""
                            matchingMessageIds = []
                            matchingMessageIdSet = []
                            currentMatchIndex = 0
                        }
                    }
                } label: {
                    Label("Search", systemImage: isSearchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Search messages (⌘F)")

                Button {
                    exportConversation()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button {
                    copyConversation()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
        // Keyboard shortcuts for search navigation
        .onKeyPress(.escape) {
            if isSearchVisible {
                withAnimation(.easeInOut(duration: 0.2)) {
                    searchDebounceTask?.cancel()
                    isSearchVisible = false
                    messageSearchQuery = ""
                    matchingMessageIds = []
                    matchingMessageIdSet = []
                    currentMatchIndex = 0
                }
                return .handled
            }
            return .ignored
        }
    }

    private func exportConversation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json, .plainText]
        panel.nameFieldStringValue = "\(conversation.displayTitle).json"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let export = ConversationExport(
                    conversation: conversation,
                    messages: appState.selectedMessages
                )
                let data = try JSONEncoder().encode(export)
                try data.write(to: url)
            } catch {
                appState.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func copyConversation() {
        let text = appState.selectedMessages.map { message in
            "[\(message.role.rawValue.capitalized)]: \(message.content)"
        }.joined(separator: "\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func shouldDisplayMessage(_ message: Message) -> Bool {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if conversation.provider == .chatgptWeb, trimmed.isEmpty {
            return false
        }
        return true
    }
}

// MARK: - Conversation Header

struct ConversationHeader: View {
    let conversation: Conversation
    let onBackToLearnings: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.provider.iconName)
                .font(.title2)
                .foregroundColor(conversation.provider.color)
                .frame(width: 40, height: 40)
                .background(conversation.provider.color.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let onBackToLearnings {
                    Button(action: onBackToLearnings) {
                        Label("Back to Learnings", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
                }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Text(conversation.displayTitle)
                        .font(AppFont.title3)
                        .foregroundColor(AppColors.primaryText)
                        .accessibilityAddTraits(.isHeader)

                    Spacer()

                    Label(
                        conversation.createdAt.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "calendar"
                    )
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
                }

                HStack(spacing: 8) {
                    Text(conversation.provider.displayName)
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)

                    if let projectPath = conversation.projectPath {
                        Text("•")
                            .foregroundColor(AppColors.secondaryText)
                        Text(projectPath.components(separatedBy: "/").suffix(2).joined(separator: "/"))
                            .font(AppFont.caption)
                            .foregroundColor(AppColors.secondaryText)
                    }

                    Text("•")
                        .foregroundColor(AppColors.secondaryText)

                    Text("\(conversation.messageCount) messages")
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)

                    if conversation.provider == .claudeCode,
                       let sourceFilePath = conversation.sourceFilePath,
                       FileManager.default.fileExists(atPath: sourceFilePath) {
                        Text("•")
                            .foregroundColor(AppColors.secondaryText)
                        Button {
                            openSourceLog(at: sourceFilePath)
                        } label: {
                            Label("Open log", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(AppColors.secondaryBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func openSourceLog(at path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    let provider: Provider
    /// Search highlight info: (isCurrent: is this the active match, query: search term)
    var searchHighlight: (isCurrent: Bool, query: String)?

    @State private var isExpanded = false
    @State private var isHovering = false

    private let maxPreviewLength = 500

    private var isHighlighted: Bool {
        searchHighlight != nil
    }

    private var isCurrentMatch: Bool {
        searchHighlight?.isCurrent ?? false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Role icon
            roleIcon
                .frame(width: 32, height: 32)
                .background(roleColor.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Text(message.role.displayName)
                        .font(AppFont.subheadline)
                        .fontWeight(.semibold)

                    if let model = message.model {
                        Text("•")
                            .foregroundColor(AppColors.secondaryText)
                        Text(model)
                            .font(AppFont.caption)
                            .foregroundColor(AppColors.secondaryText)
                    }

                    Text("•")
                        .foregroundColor(AppColors.secondaryText)

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)

                    Spacer()

                    // Match indicator
                    if isHighlighted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(isCurrentMatch ? .orange : .secondary)
                            .font(.caption)
                    }

                    if isHovering {
                        CopyButton(text: message.content)
                    }
                }

                // Content
                if message.content.count > maxPreviewLength && !isExpanded {
                    Text(String(message.content.prefix(maxPreviewLength)) + "...")
                        .textSelection(.enabled)
                        .font(.body)

                    Button("Show more") {
                        withAnimation {
                            isExpanded = true
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                } else {
                    StructuredMessageContentView(message: message, provider: provider)
                        .textSelection(.enabled)

                    if message.content.count > maxPreviewLength {
                        Button("Show less") {
                            withAnimation {
                                isExpanded = false
                            }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }

            }
        }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(highlightBackground)
        .cornerRadius(CornerRadius.xl)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrentMatch ? Color.orange : roleColor.opacity(0.35))
                .frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xl)
                .stroke(isCurrentMatch ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 2)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var highlightBackground: Color {
        if isCurrentMatch {
            return Color.orange.opacity(0.15)
        } else if isHighlighted {
            return Color.yellow.opacity(0.08)
        } else {
            return roleColor.opacity(0.08)
        }
    }

    private var roleIcon: some View {
        Image(systemName: message.role.iconName)
            .foregroundColor(roleColor)
    }

    private var roleColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return .orange
        case .system: return .gray
        case .tool: return .purple
        }
    }
}

// MARK: - Message Content View

struct MessageContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseContent(), id: \.self) { block in
                switch block.type {
                case .text:
                    MarkdownTextView(text: block.content)
                case .code:
                    CodeBlockView(code: block.content, language: block.language)
                }
            }
        }
    }

    private func parseContent() -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var currentText = ""
        var inCodeBlock = false
        var codeContent = ""
        var codeLanguage: String?

        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // End code block
                    blocks.append(ContentBlock(type: .code, content: codeContent, language: codeLanguage))
                    codeContent = ""
                    codeLanguage = nil
                    inCodeBlock = false
                } else {
                    // Start code block
                    if !currentText.isEmpty {
                        appendTextBlocks(from: currentText, to: &blocks)
                        currentText = ""
                    }
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if codeLanguage?.isEmpty == true { codeLanguage = nil }
                    inCodeBlock = true
                }
            } else if inCodeBlock {
                if !codeContent.isEmpty { codeContent += "\n" }
                codeContent += line
            } else {
                if !currentText.isEmpty { currentText += "\n" }
                currentText += line
            }
        }

        if !currentText.isEmpty {
            appendTextBlocks(from: currentText, to: &blocks)
        }

        return blocks
    }

    private func appendTextBlocks(from text: String, to blocks: inout [ContentBlock]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.isEmpty {
            blocks.append(ContentBlock(type: .text, content: trimmed, language: nil))
            return
        }

        for paragraph in paragraphs {
            blocks.append(ContentBlock(type: .text, content: paragraph, language: nil))
        }
    }

    struct ContentBlock: Hashable {
        enum BlockType { case text, code }
        let type: BlockType
        let content: String
        var language: String?
    }
}

struct MarkdownTextView: View {
    let text: String

    var body: some View {
        if let attributed = parseMarkdown(text) {
            Text(attributed)
                .lineSpacing(2)
        } else {
            Text(text)
                .lineSpacing(2)
        }
    }

    private func parseMarkdown(_ text: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        return try? AttributedString(markdown: text, options: options)
    }
}

// MARK: - Structured Message Content View

struct StructuredMessageContentView: View {
    let message: Message
    let provider: Provider

    var body: some View {
        if let blocks = structuredBlocks, !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(blocks, id: \.self) { block in
                    switch block {
                    case .text(let text):
                        MessageContentView(content: text)
                    case .thinking(let text):
                        thinkingBlock(content: text)
                    case .code(let code, let language):
                        CodeBlockView(code: code, language: language)
                    case .tool(let name, let content):
                        toolBlock(name: name, content: content)
                    case .image(let url, let title):
                        imageBlock(url: url, title: title)
                    case .unknown(let label, let content):
                        unknownBlock(label: label, content: content)
                    }
                }
            }
        } else if let segments = fallbackThinkingSegments {
            VStack(alignment: .leading, spacing: 12) {
                thinkingBlock(content: segments.thinking)
                MessageContentView(content: segments.answer)
            }
        } else {
            MessageContentView(content: message.content)
        }
    }

    private enum StructuredMessageBlock: Hashable {
        case text(String)
        case thinking(String)
        case code(String, language: String?)
        case tool(name: String?, content: String?)
        case image(url: String?, title: String?)
        case unknown(label: String, content: String?)
    }

    private var structuredBlocks: [StructuredMessageBlock]? {
        guard let payload = message.rawPayload ?? message.metadata else { return nil }
        switch provider {
        case .claudeWeb:
            return claudeBlocks(from: payload)
        case .chatgptWeb:
            return chatgptBlocks(from: payload)
        default:
            return nil
        }
    }

    private func claudeBlocks(from metadata: Data) -> [StructuredMessageBlock]? {
        if let object = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] {
            return claudeBlocks(from: object)
        }

        if let raw = try? JSONDecoder().decode(
            ClaudeWebSync.ConversationDetailResponse.ChatMessage.self,
            from: metadata
        ) {
            return claudeBlocks(from: raw)
        }

        return nil
    }

    private func claudeBlocks(
        from chatMessage: ClaudeWebSync.ConversationDetailResponse.ChatMessage
    ) -> [StructuredMessageBlock] {
        if let content = chatMessage.content {
            return claudeBlocks(from: content)
        }

        let trimmed = chatMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let allowThinking = chatMessage.sender.lowercased() == "assistant"
        return parseClaudeTextBlocks(trimmed, allowThinking: allowThinking)
    }

    private func claudeBlocks(from object: [String: Any]) -> [StructuredMessageBlock] {
        let sender = (object["sender"] as? String)?.lowercased()
        let allowThinking = sender == "assistant"

        var blocks: [StructuredMessageBlock] = []
        if let text = object["text"] as? String {
            blocks.append(contentsOf: parseClaudeTextBlocks(text, allowThinking: allowThinking))
        }

        if let attachments = object["attachments"] as? [[String: Any]] {
            blocks.append(contentsOf: attachmentBlocks(from: attachments))
        }
        if let files = object["files"] as? [[String: Any]] {
            blocks.append(contentsOf: attachmentBlocks(from: files))
        }
        if let filesV2 = object["files_v2"] as? [[String: Any]] {
            blocks.append(contentsOf: attachmentBlocks(from: filesV2))
        }

        return blocks
    }

    private func claudeBlocks(
        from content: ClaudeWebSync.ConversationDetailResponse.ChatMessage.ContentType
    ) -> [StructuredMessageBlock] {
        switch content {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(trimmed)]
        case .array(let blocks):
            return blocks.flatMap { claudeBlocks(from: $0) }
        }
    }

    private func claudeBlocks(
        from block: ClaudeWebSync.ConversationDetailResponse.ChatMessage.ContentBlock
    ) -> [StructuredMessageBlock] {
        let type = block.type?.lowercased()
        let text = rawText(from: block)

        switch type {
        case "thinking", "analysis":
            if let text, !text.isEmpty {
                return [.thinking(text)]
            }
            return []
        case "code":
            if let text, !text.isEmpty {
                return [.code(text, language: block.language)]
            }
            return []
        case "tool_use", "tool_result":
            return [.tool(name: block.name ?? block.title ?? type, content: text)]
        case "image", "image_url":
            return [.image(url: block.url, title: block.title ?? block.name)]
        case "text", nil:
            if let text, !text.isEmpty {
                return [.text(text)]
            }
            if let nested = block.content {
                return claudeBlocks(from: nested)
            }
            return []
        default:
            if let nested = block.content {
                let nestedBlocks = claudeBlocks(from: nested)
                if !nestedBlocks.isEmpty {
                    return nestedBlocks
                }
            }
            if let text, !text.isEmpty {
                return [.text(text)]
            }
            return [.unknown(label: type ?? "unknown", content: nil)]
        }
    }

    private func rawText(
        from content: ClaudeWebSync.ConversationDetailResponse.ChatMessage.ContentType
    ) -> String? {
        switch content {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .array(let blocks):
            let texts = blocks.compactMap { rawText(from: $0) }
            return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
        }
    }

    private func rawText(
        from block: ClaudeWebSync.ConversationDetailResponse.ChatMessage.ContentBlock
    ) -> String? {
        if let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        if let nested = block.content, let nestedText = rawText(from: nested), !nestedText.isEmpty {
            return nestedText
        }

        if let title = block.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        if let name = block.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        return nil
    }

    private let claudeUnsupportedBlockPlaceholder = "this block is not supported on your current device yet."

    private func parseClaudeTextBlocks(
        _ text: String,
        allowThinking: Bool
    ) -> [StructuredMessageBlock] {
        var blocks: [StructuredMessageBlock] = []
        var currentText = ""
        var inCodeBlock = false
        var codeContent = ""
        var codeLanguage: String?

        let lines = text.components(separatedBy: "\n")

        func flushTextBlock() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                currentText = ""
                return
            }

            blocks.append(contentsOf: splitClaudeTextBlock(trimmed, allowThinking: allowThinking && blocks.isEmpty))
            currentText = ""
        }

        func appendCodeBlock() {
            let trimmed = codeContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUnsupportedClaudePlaceholder(trimmed) {
                blocks.append(.unknown(label: "Unsupported block", content: nil))
            } else if !trimmed.isEmpty {
                blocks.append(.code(trimmed, language: codeLanguage))
            }
            codeContent = ""
            codeLanguage = nil
        }

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeBlock {
                    appendCodeBlock()
                    inCodeBlock = false
                } else {
                    flushTextBlock()
                    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                if !codeContent.isEmpty { codeContent += "\n" }
                codeContent += line
                continue
            }

            if isUnsupportedClaudePlaceholder(line) {
                flushTextBlock()
                blocks.append(.unknown(label: "Unsupported block", content: nil))
                continue
            }

            if !currentText.isEmpty { currentText += "\n" }
            currentText += line
        }

        if inCodeBlock {
            appendCodeBlock()
        }

        flushTextBlock()
        return blocks
    }

    private func splitClaudeTextBlock(
        _ text: String,
        allowThinking: Bool
    ) -> [StructuredMessageBlock] {
        if allowThinking, let segments = extractThinkingSegments(from: text) {
            return [.thinking(segments.thinking), .text(segments.answer)]
        }
        return [.text(text)]
    }

    private func isUnsupportedClaudePlaceholder(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == claudeUnsupportedBlockPlaceholder
    }

    private func attachmentBlocks(from attachments: [[String: Any]]) -> [StructuredMessageBlock] {
        attachments.compactMap { attachment in
            let name = attachment["file_name"] as? String
            let type = attachment["file_type"] as? String
            let size = attachment["file_size"] as? Int
            let extracted = attachment["extracted_content"] as? String

            var lines: [String] = []
            if let name, !name.isEmpty {
                lines.append("File: \(name)")
            }
            if let type, !type.isEmpty {
                lines.append("Type: \(type)")
            }
            if let size {
                lines.append("Size: \(size) bytes")
            }
            if let extracted, !extracted.isEmpty {
                lines.append(extracted)
            }

            let content = lines.isEmpty ? nil : lines.joined(separator: "\n")
            return .tool(name: "Attachment", content: content)
        }
    }

    private func chatgptBlocks(from metadata: Data) -> [StructuredMessageBlock]? {
        guard let raw = try? JSONDecoder().decode(
            ChatGPTWebSync.ConversationDetailResponse.MappingNode.MessageContent.self,
            from: metadata
        ) else {
            return nil
        }
        return chatgptBlocks(from: raw)
    }

    private func chatgptBlocks(
        from message: ChatGPTWebSync.ConversationDetailResponse.MappingNode.MessageContent
    ) -> [StructuredMessageBlock] {
        if message.author.role == "tool" {
            return chatgptToolBlocks(from: message)
        }
        return chatgptBlocks(from: message.content)
    }

    private func chatgptBlocks(
        from content: ChatGPTWebSync.ConversationDetailResponse.MappingNode.MessageContent.Content
    ) -> [StructuredMessageBlock] {
        let contentType = content.content_type.lowercased()
        if contentType.contains("code") || contentType.contains("execution_output"), let text = content.text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let language = detectCodeLanguage(trimmed, hint: contentType)
            return [.code(trimmed, language: language)]
        }
        if let parts = content.parts, !parts.isEmpty {
            return chatgptBlocks(fromParts: parts, contentType: content.content_type)
        }

        if let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return mergeAdjacentTextBlocks(chatgptAnnotatedBlocks(from: text))
        }

        let label = content.content_type.isEmpty ? "content" : content.content_type
        return [.unknown(label: label, content: nil)]
    }

    private func chatgptBlocks(
        fromParts parts: [ChatGPTWebSync.ConversationDetailResponse.MappingNode.MessageContent.Content.StringOrArray],
        contentType: String
    ) -> [StructuredMessageBlock] {
        var blocks: [StructuredMessageBlock] = []
        let normalizedType = contentType.lowercased()
        let treatAsCode = normalizedType.contains("code")
            || normalizedType.contains("json")
            || normalizedType.contains("execution_output")

        for part in parts {
            switch part {
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if treatAsCode {
                    let language = detectCodeLanguage(trimmed, hint: normalizedType)
                    blocks.append(.code(trimmed, language: language))
                } else {
                    blocks.append(contentsOf: chatgptAnnotatedBlocks(from: text))
                }
            case .object(let object):
                blocks.append(contentsOf: chatgptBlocks(from: object, contentType: contentType))
            }
        }

        return mergeAdjacentTextBlocks(blocks)
    }

    private func chatgptBlocks(
        from object: [String: ChatGPTWebSync.AnyCodable],
        contentType: String
    ) -> [StructuredMessageBlock] {
        let type = (object["type"]?.stringValue ?? object["content_type"]?.stringValue)?.lowercased()
        let text = object["text"]?.stringValue

        if let type, type.contains("code") {
            let code = text ?? object["code"]?.stringValue ?? ""
            let language = object["language"]?.stringValue
            if !code.isEmpty {
                return [.code(code, language: language)]
            }
        }

        if let type, type.contains("image") {
            let url = object["url"]?.stringValue
                ?? object["image_url"]?.stringValue
                ?? object["asset_pointer"]?.stringValue
            return [.image(url: url, title: type)]
        }

        if let type, type.contains("tool") {
            let name = object["name"]?.stringValue ?? type
            let content = text ?? prettyPrintedJSON(object)
            return [.tool(name: name, content: content)]
        }

        if let text, !text.isEmpty {
            return [.text(text)]
        }

        let label = type ?? contentType
        return [.unknown(label: label, content: prettyPrintedJSON(object))]
    }

    private func chatgptToolBlocks(
        from message: ChatGPTWebSync.ConversationDetailResponse.MappingNode.MessageContent
    ) -> [StructuredMessageBlock] {
        let toolName = message.author.name ?? "Tool"
        let content = message.content
        var outputs: [String] = []

        if let parts = content.parts, !parts.isEmpty {
            for part in parts {
                switch part {
                case .string(let text):
                    if let formatted = formatToolContent(text) {
                        outputs.append(formatted)
                    }
                case .object(let object):
                    if let formatted = formatToolObject(object) {
                        outputs.append(formatted)
                    }
                }
            }
        } else if let text = content.text, let formatted = formatToolContent(text) {
            outputs.append(formatted)
        }

        let combined = outputs.joined(separator: "\n\n")
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [.tool(name: toolName, content: combined)]
    }

    private func formatToolContent(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let prettyJSON = prettyPrintedJSON(from: trimmed) {
            return "```json\n\(prettyJSON)\n```"
        }
        return trimmed
    }

    private func formatToolObject(_ object: [String: ChatGPTWebSync.AnyCodable]) -> String? {
        if let contentType = object["content_type"]?.stringValue?.lowercased(),
           contentType.contains("image"),
           let pointer = object["asset_pointer"]?.stringValue {
            let width = object["width"]?.intValue
            let height = object["height"]?.intValue
            let size = object["size_bytes"]?.intValue
            var lines = ["Image asset pointer: \(pointer)"]
            if let width, let height {
                lines.append("Size: \(width)x\(height)")
            }
            if let size {
                lines.append("Bytes: \(size)")
            }
            return lines.joined(separator: "\n")
        }

        if let prettyJSON = prettyPrintedJSON(object) {
            return "```json\n\(prettyJSON)\n```"
        }
        return nil
    }

    private func prettyPrintedJSON(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
              let output = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectCodeLanguage(_ text: String, hint: String) -> String? {
        if hint.contains("json") { return "json" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return "json"
        }
        return nil
    }

    private func chatgptAnnotatedBlocks(from text: String) -> [StructuredMessageBlock] {
        let annotationRegex = Self.chatgptAnnotationRegex
        guard let annotationRegex else {
            return [.text(text)]
        }

        let nsText = text as NSString
        var blocks: [StructuredMessageBlock] = []
        var buffer = ""
        var lastIndex = 0

        let matches = annotationRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let range = match.range(at: 0)
            if range.location > lastIndex {
                let chunk = nsText.substring(with: NSRange(location: lastIndex, length: range.location - lastIndex))
                buffer.append(chunk)
            }

            let type = nsText.substring(with: match.range(at: 1)).lowercased()
            let payload = nsText.substring(with: match.range(at: 2))

            if let replacement = chatgptAnnotationReplacement(type: type, payload: payload) {
                buffer.append(replacement)
            } else if let toolBlock = chatgptAnnotationToolBlock(type: type, payload: payload) {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    blocks.append(.text(collapseWhitespace(trimmed)))
                }
                buffer = ""
                blocks.append(toolBlock)
            }

            lastIndex = range.location + range.length
        }

        if lastIndex < nsText.length {
            buffer.append(nsText.substring(from: lastIndex))
        }

        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(.text(collapseWhitespace(trimmed)))
        }

        return blocks.isEmpty ? [.text(text)] : blocks
    }

    private func chatgptAnnotationReplacement(type: String, payload: String) -> String? {
        if type == "entity" {
            if let array = parseChatGPTAnnotationPayload(payload) as? [Any] {
                if array.count > 1, let value = array[1] as? String {
                    return value
                }
                if let value = array.first as? String {
                    return value
                }
            }
            if let dict = parseChatGPTAnnotationPayload(payload) as? [String: Any] {
                if let value = dict["text"] as? String {
                    return value
                }
                if let value = dict["name"] as? String {
                    return value
                }
            }
        }
        return nil
    }

    private func chatgptAnnotationToolBlock(type: String, payload: String) -> StructuredMessageBlock? {
        let normalized = type.replacingOccurrences(of: "_", with: " ")
        guard normalized.contains("image") else { return nil }

        if let dict = parseChatGPTAnnotationPayload(payload) as? [String: Any] {
            if let queries = dict["query"] as? [String], !queries.isEmpty {
                let content = queries.joined(separator: "\n")
                return .tool(name: "Image group", content: content)
            }
        }

        if let array = parseChatGPTAnnotationPayload(payload) as? [String], !array.isEmpty {
            let content = array.joined(separator: "\n")
            return .tool(name: "Image group", content: content)
        }

        return .tool(name: "Image group", content: payload)
    }

    private func parseChatGPTAnnotationPayload(_ payload: String) -> Any? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func mergeAdjacentTextBlocks(_ blocks: [StructuredMessageBlock]) -> [StructuredMessageBlock] {
        var merged: [StructuredMessageBlock] = []
        var textBuffer: String?

        for block in blocks {
            switch block {
            case .text(let text):
                if let buffer = textBuffer {
                    textBuffer = buffer + "\n\n" + text
                } else {
                    textBuffer = text
                }
            default:
                if let buffer = textBuffer {
                    merged.append(.text(buffer))
                    textBuffer = nil
                }
                merged.append(block)
            }
        }

        if let buffer = textBuffer {
            merged.append(.text(buffer))
        }

        return merged
    }

    private func collapseWhitespace(_ text: String) -> String {
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }

    private static let chatgptAnnotationRegex = try? NSRegularExpression(
        pattern: "\\u{E200}(.*?)\\u{E202}(.*?)\\u{E201}",
        options: [.dotMatchesLineSeparators]
    )

    @ViewBuilder
    private func thinkingBlock(content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Thinking", systemImage: "brain")
                .font(.caption)
                .foregroundColor(.secondary)

            MessageContentView(content: content)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(CornerRadius.lg)
    }

    @ViewBuilder
    private func toolBlock(name: String?, content: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name ?? "Tool", systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundColor(.secondary)

            if let content, !content.isEmpty {
                MessageContentView(content: content)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(CornerRadius.lg)
    }

    @ViewBuilder
    private func imageBlock(url: String?, title: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title ?? "Image", systemImage: "photo")
                .font(.caption)
                .foregroundColor(.secondary)

            if let urlString = url,
               !urlString.isEmpty,
               let imageURL = URL(string: urlString),
               imageURL.scheme == "https" || imageURL.scheme == "http" {
                // Render actual image for http/https URLs
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: 300, maxHeight: 200)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 300, maxHeight: 200)
                            .cornerRadius(6)
                    case .failure:
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("Failed to load image")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: 300, maxHeight: 100)
                    @unknown default:
                        EmptyView()
                    }
                }

                // Show URL as secondary info
                Text(urlString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let url, !url.isEmpty {
                // Non-http URL (asset pointer, etc.) - show as text
                Text(url)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Image content")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(CornerRadius.lg)
    }

    @ViewBuilder
    private func unknownBlock(label: String, content: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label.capitalized, systemImage: "questionmark.square")
                .font(.caption)
                .foregroundColor(.secondary)

            if let content, !content.isEmpty {
                MessageContentView(content: content)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(CornerRadius.lg)
    }

    private func prettyPrintedJSON(_ object: [String: ChatGPTWebSync.AnyCodable]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private var fallbackThinkingSegments: MessageSegments? {
        guard provider == .claudeWeb, message.role == .assistant else { return nil }
        return extractThinkingSegments(from: message.content)
    }

    private struct MessageSegments {
        let thinking: String
        let answer: String
    }

    private func extractThinkingSegments(from content: String) -> MessageSegments? {
        let paragraphs = content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard paragraphs.count >= 2 else { return nil }

        var thinking: [String] = []
        var answerStartIndex: Int?

        for (index, paragraph) in paragraphs.enumerated() {
            if thinking.isEmpty {
                if isThinkingParagraph(paragraph) {
                    thinking.append(paragraph)
                } else {
                    return nil
                }
            } else if isThinkingContinuation(paragraph) {
                thinking.append(paragraph)
            } else {
                answerStartIndex = index
                break
            }
        }

        guard let start = answerStartIndex else { return nil }
        let answer = paragraphs[start...].joined(separator: "\n\n")
        let thinkingText = thinking.joined(separator: "\n\n")
        guard !answer.isEmpty, !thinkingText.isEmpty else { return nil }

        return MessageSegments(thinking: thinkingText, answer: answer)
    }

    private func isThinkingParagraph(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Negative indicators - these suggest the paragraph is an actual response, not thinking
        let answerPrefixes = [
            "i'll help you",
            "i'd be happy to",
            "i can help",
            "here's how",
            "here is how",
            "sure!",
            "absolutely!",
            "of course!",
            "yes,",
            "no,",
            "here's the",
            "here is the",
            "to do this",
            "you can",
            "you should",
            "the answer is",
            "the solution is"
        ]

        // If starts with answer prefix, not thinking
        if answerPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return false
        }

        // Strong thinking indicators (score 2 each)
        let strongIndicators = [
            "the user ",
            "the user is",
            "user wants",
            "user is asking",
            "i should",
            "i need to",
            "my plan",
            "here's my plan",
            "here is my plan",
            "plan:",
            "approach:",
            "analysis:",
            "let me think",
            "let me analyze"
        ]

        // Weak thinking indicators (score 1 each)
        let weakIndicators = [
            "i will",
            "i can",
            "i'll",
            "key points",
            "considerations",
            "draft:"
        ]

        var score = 0

        for indicator in strongIndicators {
            if lower.hasPrefix(indicator) {
                score += 2
            }
        }

        for indicator in weakIndicators {
            if lower.hasPrefix(indicator) {
                score += 1
            }
        }

        // "Let me..." ending with colon is thinking
        if lower.hasPrefix("let me") && trimmed.hasSuffix(":") {
            score += 2
        }

        // Label-like paragraph ending with colon containing thinking keywords
        if trimmed.hasSuffix(":") && (lower.contains("key points") || lower.contains("considerations") || lower.contains("steps")) {
            score += 1
        }

        // Require score >= 2 to be classified as thinking
        return score >= 2
    }

    private func isThinkingContinuation(_ paragraph: String) -> Bool {
        if isThinkingParagraph(paragraph) { return true }
        if isListParagraph(paragraph) { return true }
        if isLabelParagraph(paragraph) { return true }
        return false
    }

    private func isListParagraph(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("•") {
            return true
        }

        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let remainder = trimmed.dropFirst(digits.count)
            if remainder.hasPrefix(".") || remainder.hasPrefix(")") {
                return true
            }
        }

        return false
    }

    private func isLabelParagraph(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count < 120 && trimmed.hasSuffix(":")
    }
}

// MARK: - Learning Highlight Banner

struct LearningHighlightBanner: View {
    let count: Int
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Learnings detected")
                    .font(AppFont.headline)
                    .foregroundColor(AppColors.primaryText)

                if count > 0 {
                    Text("\(count) pending review from this conversation")
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                } else {
                    Text("Review learnings captured from this conversation")
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                }
            }

            Spacer()

            Button("Review") {
                onReview()
            }
            .buttonStyle(.bordered)
        }
        .padding(Spacing.md)
        .background(AppColors.secondaryBackground)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .stroke(AppColors.separator, lineWidth: 1)
        )
        .cornerRadius(CornerRadius.lg)
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                if let language = language {
                    Text(language)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isHovering {
                    CopyButton(text: code)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            // Code
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(CornerRadius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Role Extensions

extension Role {
    var displayName: String {
        switch self {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .system: return "System"
        case .tool: return "Tool"
        }
    }

    var iconName: String {
        switch self {
        case .user: return "person.fill"
        case .assistant: return "brain.head.profile"
        case .system: return "gearshape.fill"
        case .tool: return "wrench.fill"
        }
    }
}

// MARK: - Message Search Bar

struct MessageSearchBar: View {
    @Binding var query: String
    @Binding var currentIndex: Int
    let totalMatches: Int
    var isFocused: FocusState<Bool>.Binding
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Search icon
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 14))

            // Search field
            TextField("Search messages...", text: $query)
                .textFieldStyle(.plain)
                .font(AppFont.body)
                .focused(isFocused)
                .onSubmit {
                    // Enter key goes to next match
                    goToNextMatch()
                }

            // Match count and navigation
            if !query.isEmpty {
                if totalMatches > 0 {
                    Text("\(currentIndex + 1) of \(totalMatches)")
                        .font(AppFont.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()

                    // Previous match
                    Button {
                        goToPreviousMatch()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .disabled(totalMatches == 0)
                    .help("Previous match (⇧↩)")

                    // Next match
                    Button {
                        goToNextMatch()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .disabled(totalMatches == 0)
                    .help("Next match (↩)")
                } else {
                    Text("No matches")
                        .font(AppFont.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Dismiss button
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(AppColors.secondaryBackground)
        .cornerRadius(CornerRadius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .stroke(AppColors.separator, lineWidth: 1)
        )
    }

    private func goToNextMatch() {
        guard totalMatches > 0 else { return }
        currentIndex = (currentIndex + 1) % totalMatches
    }

    private func goToPreviousMatch() {
        guard totalMatches > 0 else { return }
        currentIndex = currentIndex > 0 ? currentIndex - 1 : totalMatches - 1
    }
}

// MARK: - Export Model

struct ConversationExport: Codable {
    let conversation: Conversation
    let messages: [Message]
}

// MARK: - Copy Button with Feedback

struct CopyButton: View {
    let text: String
    var font: Font = .caption

    @State private var didCopy = false
    @State private var copyTask: Task<Void, Never>?

    var body: some View {
        Button {
            copyToClipboard()
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(font)
                .foregroundColor(didCopy ? .green : .primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onDisappear {
            copyTask?.cancel()
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Show checkmark
        withAnimation {
            didCopy = true
        }

        // Reset after 2 seconds
        copyTask?.cancel()
        copyTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    didCopy = false
                }
            }
        }
    }
}

#Preview {
    ConversationDetailView(conversation: Conversation(
        id: UUID(),
        provider: .claudeCode,
        sourceType: .cli,
        title: "Test Conversation",
        createdAt: Date(),
        updatedAt: Date(),
        messageCount: 5
    ))
    .environmentObject(AppState())
}
