import SwiftUI

/// Learning review queue interface
struct LearningReviewView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedLearning: Learning?
    @State private var editedRule: String = ""
    @State private var selectedScope: LearningScope = .global
    @State private var showingExportSheet = false
    @State private var selectedSuggestion: AnalysisSuggestion?

    var body: some View {
        LearningReviewContentView(
            learningQueue: appState.learningQueue,
            pendingSuggestions: appState.pendingSuggestions,
            selectedLearning: $selectedLearning,
            selectedSuggestion: $selectedSuggestion,
            editedRule: $editedRule,
            selectedScope: $selectedScope,
            showingExportSheet: $showingExportSheet
        )
    }
}

struct LearningReviewContentView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var learningQueue: LearningQueue
    let pendingSuggestions: [AnalysisSuggestion]
    @Binding var selectedLearning: Learning?
    @Binding var selectedSuggestion: AnalysisSuggestion?
    @Binding var editedRule: String
    @Binding var selectedScope: LearningScope
    @Binding var showingExportSheet: Bool

    @State private var showCloudAnalysisAlert = false
    @State private var showHowItWorks = false
    @AppStorage("allowCloudAnalysis") private var allowCloudAnalysis = false
    @AppStorage("scanScopeDays") private var scanScopeDays = 0
    @AppStorage("scanScopeProjectOnly") private var scanScopeProjectOnly = false
    @AppStorage("scanScopeProviders") private var scanScopeProviders = ""
    @State private var showScopeSheet = false
    @State private var selectedProviders: Set<Provider> = []

    private var visibleLearnings: [Learning] {
        guard let selectedConversation = appState.selectedConversation else {
            return learningQueue.pendingLearnings
        }
        return learningQueue.pendingLearnings.filter { $0.conversationId == selectedConversation.id }
    }

    private var isFilteringByConversation: Bool {
        appState.selectedConversation != nil
    }

    private var filterLabel: String? {
        appState.selectedConversation?.title
    }

    private var currentProjectPath: String? {
        appState.selectedConversation?.projectPath
    }

    private var scanScope: ScanScope {
        let days = scanScopeDays > 0 ? scanScopeDays : nil
        let projectPath = scanScopeProjectOnly ? currentProjectPath : nil
        return ScanScope(timeWindowDays: days, projectPath: projectPath, providers: selectedProviders)
    }

    private var scopeSummary: String {
        var parts: [String] = []
        if scanScopeDays > 0 {
            parts.append("Last \(scanScopeDays) days")
        } else {
            parts.append("All time")
        }
        if scanScopeProjectOnly, let path = currentProjectPath, !path.isEmpty {
            let shortPath = path.split(separator: "/").suffix(2).joined(separator: "/")
            parts.append("Project: \(shortPath)")
        }
        if !selectedProviders.isEmpty {
            let names = selectedProviders.map { $0.displayName }.sorted().joined(separator: ", ")
            parts.append("Providers: \(names)")
        } else {
            parts.append("All providers")
        }
        return parts.joined(separator: " • ")
    }

    private var scanProgressText: String? {
        let orchestrator = appState.llmOrchestrator
        guard orchestrator.isAnalyzing, orchestrator.totalQueuedItems > 0 else { return nil }
        let percent = Int(orchestrator.analysisProgress * 100)
        let processed = orchestrator.processedItems
        let total = orchestrator.totalQueuedItems
        let eta = formatETA(orchestrator.estimatedTimeRemaining)
        var parts = ["\(percent)%", "\(processed)/\(total)"]
        if let eta {
            parts.append("ETA \(eta)")
        }
        return "CLI scan: " + parts.joined(separator: " • ")
    }

    private var scanErrorText: String? {
        let rawError = appState.llmOrchestrator.lastAnalysisError ?? appState.errorMessage
        guard let message = rawError?.lowercased() else { return nil }
        if message.contains("not logged in") || message.contains("authentication") {
            return "Claude CLI not logged in. Run `claude login` and retry."
        }
        return nil
    }

    var body: some View {
        HSplitView {
            // Left: Queue list
            VStack(spacing: 0) {
                QueueHeader(
                    pendingCount: visibleLearnings.count,
                    totalCount: learningQueue.pendingLearnings.count,
                    suggestionsCount: pendingSuggestions.count,
                    filterLabel: filterLabel,
                    scopeSummary: scopeSummary,
                    scanProgressText: scanProgressText,
                    scanProgress: appState.llmOrchestrator.analysisProgress,
                    scanErrorText: scanErrorText,
                    onClearFilter: isFilteringByConversation ? { appState.clearSelection() } : nil,
                    onScanAll: {
                        // Show disclosure when cloud analysis is enabled
                        if allowCloudAnalysis && appState.llmOrchestrator.activeBackend == .claudeCode {
                            showCloudAnalysisAlert = true
                        } else {
                            Task {
                                await learningQueue.scanAllConversations()
                            }
                        }
                    },
                    onScopeTapped: { showScopeSheet = true },
                    isProcessing: learningQueue.isProcessing,
                    onInfoTapped: { showHowItWorks = true }
                )

                Divider()

                // Pending Suggestions Section (if any)
                if !pendingSuggestions.isEmpty {
                    SuggestionsSection(
                        suggestions: pendingSuggestions,
                        selectedSuggestion: $selectedSuggestion,
                        onApprove: { suggestion in
                            Task { await appState.approveSuggestion(suggestion) }
                        },
                        onReject: { suggestion in
                            appState.rejectSuggestion(suggestion)
                        }
                    )
                    Divider()
                }

                if visibleLearnings.isEmpty && pendingSuggestions.isEmpty {
                    if learningQueue.isProcessing {
                        // Show skeleton loading state
                        SkeletonList(rowCount: 5)
                            .padding(.top, Spacing.md)
                    } else {
                        EmptyQueueView(
                            isFiltered: isFilteringByConversation,
                            totalPending: learningQueue.pendingLearnings.count
                        )
                    }
                } else if !visibleLearnings.isEmpty {
                    List(visibleLearnings, selection: $selectedLearning) { learning in
                        LearningQueueRow(learning: learning)
                            .tag(learning)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 300)

            // Right: Detail/Review
            if let learning = selectedLearning {
                LearningDetailView(
                    learning: learning,
                    editedRule: $editedRule,
                    selectedScope: $selectedScope,
                    onApprove: {
                        Task {
                            await learningQueue.approve(
                                learning,
                                scope: selectedScope,
                                editedRule: editedRule.isEmpty ? nil : editedRule
                            )
                            selectNextLearning()
                        }
                    },
                    onReject: {
                        Task {
                            await learningQueue.reject(learning)
                            selectNextLearning()
                        }
                    },
                    onSkip: {
                        learningQueue.skip(learning)
                        selectNextLearning()
                    },
                    onOpenConversation: {
                        appState.openConversation(for: learning)
                    }
                )
                .onAppear {
                    editedRule = learning.extractedRule
                    selectedScope = learning.scope
                }
                .onChange(of: selectedLearning) { _, newValue in
                    if let newLearning = newValue {
                        editedRule = newLearning.extractedRule
                        selectedScope = newLearning.scope
                    }
                }
            } else {
                Text("Select a learning to review")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.sidebarSelection = .automation
                    appState.activeView = .automation
                } label: {
                    Label("Automation Candidates", systemImage: "flowchart")
                }

                Button {
                    showingExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(learningQueue.approvedLearnings.isEmpty)
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportLearningsSheet(learnings: learningQueue.approvedLearnings)
        }
        .sheet(isPresented: $showHowItWorks) {
            HowLearningsWorkView()
        }
        .onAppear {
            if selectedLearning == nil {
                selectedLearning = visibleLearnings.first
            }
        }
        .onChange(of: appState.selectedConversation?.id) { _, _ in
            if let selectedLearning, !visibleLearnings.contains(selectedLearning) {
                self.selectedLearning = visibleLearnings.first
            }
        }
        .onChange(of: learningQueue.pendingLearnings) { _, _ in
            if let selectedLearning, !visibleLearnings.contains(selectedLearning) {
                self.selectedLearning = visibleLearnings.first
            } else if selectedLearning == nil {
                selectedLearning = visibleLearnings.first
            }
        }
        .alert("Cloud Analysis", isPresented: $showCloudAnalysisAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Continue") {
                Task {
                    await appState.runFullCLIScan(types: [.learning], scope: scanScope)
                }
            }
        } message: {
            Text("This will send conversation data to Claude for learning extraction. Your data is processed according to Anthropic's privacy policy.")
        }
        .sheet(isPresented: $showScopeSheet) {
            ScanScopeSheet(
                title: "Scan Scope",
                timeWindowDays: $scanScopeDays,
                projectOnly: $scanScopeProjectOnly,
                projectPath: currentProjectPath,
                selectedProviders: $selectedProviders,
                availableProviders: availableProviders()
            )
        }
        .onAppear {
            selectedProviders = ScanScopeStorage.decodeProviders(scanScopeProviders)
        }
        .onChange(of: selectedProviders) { _, newValue in
            scanScopeProviders = ScanScopeStorage.encodeProviders(newValue)
        }
    }

    private func selectNextLearning() {
        selectedLearning = visibleLearnings.first
    }

    private func availableProviders() -> [Provider] {
        let providers = Set(appState.conversations.map { $0.provider })
        if providers.isEmpty {
            return Provider.allCases
        }
        return providers.sorted { $0.displayName < $1.displayName }
    }

    private func formatETA(_ interval: TimeInterval?) -> String? {
        guard let interval, interval.isFinite else { return nil }
        let seconds = max(0, Int(interval))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 {
            return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
        }
        let hours = minutes / 60
        let minutesRemainder = minutes % 60
        return minutesRemainder > 0 ? "\(hours)h \(minutesRemainder)m" : "\(hours)h"
    }
}

// MARK: - Queue Header

struct QueueHeader: View {
    let pendingCount: Int
    let totalCount: Int
    let suggestionsCount: Int
    let filterLabel: String?
    let scopeSummary: String
    let scanProgressText: String?
    let scanProgress: Double
    let scanErrorText: String?
    let onClearFilter: (() -> Void)?
    let onScanAll: () -> Void
    let onScopeTapped: () -> Void
    let isProcessing: Bool
    var onInfoTapped: (() -> Void)? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 8) {
                    Text("Learning Queue")
                        .font(AppFont.title3)
                        .accessibilityAddTraits(.isHeader)

                    if let onInfoTapped {
                        Button(action: onInfoTapped) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("How learnings are extracted")
                    }

                    if suggestionsCount > 0 {
                        Text("\(suggestionsCount)")
                            .font(AppFont.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .cornerRadius(CornerRadius.capsule)
                            .accessibilityLabel("\(suggestionsCount) pending suggestions")
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(pendingSummary)
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                    HStack(spacing: 6) {
                        Text(scopeSummary)
                            .font(AppFont.caption2)
                            .foregroundColor(AppColors.tertiaryText)
                            .lineLimit(1)
                        Button("Scope") {
                            onScopeTapped()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if let filterLabel {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                            Text(filterLabel)
                                .font(AppFont.caption2)
                                .foregroundColor(AppColors.primaryText)
                                .lineLimit(1)
                            if let onClearFilter {
                                Button {
                                    onClearFilter()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(AppColors.secondaryText)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear filter")
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(CornerRadius.capsule)
                    }
                    if let scanProgressText {
                        ProgressView(value: scanProgress)
                            .frame(maxWidth: 180)
                        Text(scanProgressText)
                            .font(AppFont.caption)
                            .foregroundColor(AppColors.secondaryText)
                    }
                    if let scanErrorText {
                        Text(scanErrorText)
                            .font(AppFont.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            Button {
                onScanAll()
            } label: {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Label("Scan", systemImage: "magnifyingglass")
                }
            }
            .disabled(isProcessing)
        }
        .padding()
    }

    private var pendingSummary: String {
        if totalCount == pendingCount {
            return "\(pendingCount) pending review"
        }
        return "\(pendingCount) of \(totalCount) pending review"
    }
}

// MARK: - Empty Queue View

struct EmptyQueueView: View {
    let isFiltered: Bool
    let totalPending: Int

    var body: some View {
        if isFiltered && totalPending > 0 {
            UnifiedEmptyState(
                style: .noResults,
                title: "No learnings for this conversation",
                subtitle: "Clear the filter to review \(totalPending) other learnings"
            )
        } else {
            VStack(spacing: 16) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 48))
                    .foregroundColor(.orange.opacity(0.6))

                Text("No Learnings Yet")
                    .font(AppFont.title3)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Retain extracts your preferences and corrections from AI conversations.")
                        .font(AppFont.body)
                        .foregroundColor(AppColors.secondaryText)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Examples:")
                            .font(AppFont.caption.bold())
                            .foregroundColor(AppColors.secondaryText)

                        LearningExampleRow(
                            quote: "Use async/await instead",
                            result: "Code style preference"
                        )
                        LearningExampleRow(
                            quote: "Make it more concise",
                            result: "Writing style preference"
                        )
                        LearningExampleRow(
                            quote: "Always use GRDB",
                            result: "Technology choice"
                        )
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
                }
                .frame(maxWidth: 320)

                Text("Click \"Scan\" to extract learnings from your conversations")
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.tertiaryText)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Learning Example Row

struct LearningExampleRow: View {
    let quote: String
    let result: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\"\(quote)\"")
                .font(AppFont.caption)
                .foregroundColor(AppColors.primaryText)
                .italic()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(AppColors.tertiaryText)
            Text(result)
                .font(AppFont.caption)
                .foregroundColor(AppColors.secondaryText)
        }
    }
}

// MARK: - Suggestions Section

struct SuggestionsSection: View {
    let suggestions: [AnalysisSuggestion]
    @Binding var selectedSuggestion: AnalysisSuggestion?
    let onApprove: (AnalysisSuggestion) -> Void
    let onReject: (AnalysisSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Pending Suggestions")
                    .font(AppFont.headline)
                Spacer()
                Text("\(suggestions.count)")
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.1))

            ForEach(suggestions, id: \.id) { suggestion in
                SuggestionRow(
                    suggestion: suggestion,
                    isSelected: selectedSuggestion?.id == suggestion.id,
                    onApprove: { onApprove(suggestion) },
                    onReject: { onReject(suggestion) }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedSuggestion = suggestion
                }

                if suggestion.id != suggestions.last?.id {
                    Divider()
                        .padding(.leading, 40)
                }
            }
        }
    }
}

// MARK: - Suggestion Row

struct SuggestionRow: View {
    let suggestion: AnalysisSuggestion
    let isSelected: Bool
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestionIcon)
                .foregroundColor(suggestionColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(suggestionTitle)
                    .font(AppFont.body)
                    .lineLimit(1)

                if let value = suggestion.suggestedValue {
                    Text(value)
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                        .lineLimit(2)
                }

                if let confidence = suggestion.confidence {
                    Text("\(Int(confidence * 100))% confidence")
                        .font(AppFont.caption2)
                        .foregroundColor(AppColors.tertiaryText)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    onReject()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reject suggestion")

                Button {
                    onApprove()
                } label: {
                    Image(systemName: "checkmark")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Approve suggestion")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    private var suggestionIcon: String {
        switch suggestion.suggestionType {
        case "title":
            return "textformat"
        case "summary":
            return "doc.text"
        case "merge_learnings":
            return "arrow.triangle.merge"
        default:
            return "lightbulb"
        }
    }

    private var suggestionColor: Color {
        switch suggestion.suggestionType {
        case "title":
            return .blue
        case "summary":
            return .purple
        case "merge_learnings":
            return .orange
        default:
            return .gray
        }
    }

    private var suggestionTitle: String {
        switch suggestion.suggestionType {
        case "title":
            return "Title Suggestion"
        case "summary":
            return "Summary Suggestion"
        case "merge_learnings":
            return "Merge Learnings"
        default:
            return "Suggestion"
        }
    }
}

// MARK: - Learning Queue Row

struct LearningQueueRow: View {
    let learning: Learning

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: learning.type.iconName)
                    .foregroundColor(learning.type.color)

                Text(learning.extractedRule)
                    .lineLimit(2)
                    .font(AppFont.body)
            }

            HStack {
                Text("\(Int(learning.confidence * 100))% confidence")
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)

                if learning.evidenceCount > 1 {
                    Text("\(learning.evidenceCount)x signals")
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                }

                Spacer()

                Text((learning.lastDetectedAt ?? learning.createdAt).formatted(.relative(presentation: .named)))
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Learning Detail View

struct LearningDetailView: View {
    let learning: Learning
    @Binding var editedRule: String
    @Binding var selectedScope: LearningScope
    let onApprove: () -> Void
    let onReject: () -> Void
    let onSkip: () -> Void
    let onOpenConversation: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Image(systemName: learning.type.iconName)
                        .font(.title)
                        .foregroundColor(learning.type.color)

                    VStack(alignment: .leading) {
                        Text(learning.type.displayName)
                            .font(AppFont.title3)
                        Text("Detected pattern: \"\(learning.pattern)\"")
                            .font(AppFont.caption)
                            .foregroundColor(AppColors.secondaryText)
                    }

                    Spacer()

                    ConfidenceBadge(confidence: learning.confidence)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)

                Button("Open Conversation") {
                    onOpenConversation()
                }
                .buttonStyle(.bordered)
                .help("Open the conversation that triggered this learning")

                // Extracted Rule Editor
                VStack(alignment: .leading, spacing: 8) {
                    Text("Extracted Rule")
                        .font(AppFont.headline)
                        .accessibilityAddTraits(.isHeader)

                    TextEditor(text: $editedRule)
                        .font(.body)
                        .frame(minHeight: 80)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    Text("Edit the rule above to refine what should be learned")
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                }

                if let evidence = learning.evidence, !evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Supporting Quote")
                            .font(AppFont.headline)
                            .accessibilityAddTraits(.isHeader)

                        Text("“\(evidence)”")
                            .font(AppFont.callout)
                            .foregroundColor(AppColors.primaryText)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }

                // Scope Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scope")
                        .font(AppFont.headline)
                        .accessibilityAddTraits(.isHeader)

                    Picker("Scope", selection: $selectedScope) {
                        ForEach(LearningScope.allCases, id: \.self) { scope in
                            HStack {
                                Image(systemName: scope.iconName)
                                Text(scope.displayName)
                            }
                            .tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(selectedScope.description)
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                }

                if let context = learning.context, !context.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context")
                            .font(AppFont.headline)
                            .accessibilityAddTraits(.isHeader)

                        ScrollView {
                            Text(context)
                                .font(AppFont.callout)
                                .lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                }

                // Action Buttons
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        onReject()
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("r", modifiers: [])

                    Button {
                        onSkip()
                    } label: {
                        Label("Skip", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.rightArrow, modifiers: [])

                    Button {
                        onApprove()
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

// MARK: - Confidence Badge

struct ConfidenceBadge: View {
    let confidence: Float

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: confidenceIcon)
            Text("\(Int(confidence * 100))%")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(confidenceColor.opacity(0.1))
        .foregroundColor(confidenceColor)
        .cornerRadius(12)
    }

    private var confidenceColor: Color {
        switch confidence {
        case 0.9...1.0: return .green
        case 0.8..<0.9: return .blue
        case 0.7..<0.8: return .orange
        default: return .red
        }
    }

    private var confidenceIcon: String {
        switch confidence {
        case 0.9...1.0: return "checkmark.circle.fill"
        case 0.8..<0.9: return "checkmark.circle"
        default: return "questionmark.circle"
        }
    }
}

// MARK: - Export Sheet

struct ExportLearningsSheet: View {
    let learnings: [Learning]
    @Environment(\.dismiss) private var dismiss
    @State private var exportOptions = CLAUDEMDExporter.ExportOptions()
    @State private var exportPath: URL?

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Learnings")
                .font(.title2)

            Form {
                Section {
                    Toggle("Include header", isOn: $exportOptions.includeHeader)
                    Toggle("Include timestamps", isOn: $exportOptions.includeTimestamps)
                    Toggle("Include confidence scores", isOn: $exportOptions.includeConfidence)
                    Toggle("Group by category", isOn: $exportOptions.groupByCategory)
                }
            }

            // Preview
            GroupBox("Preview") {
                ScrollView {
                    Text(generatePreview())
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 200)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Export to CLAUDE.md...") {
                    exportToFile()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 500, height: 500)
    }

    private func generatePreview() -> String {
        let exporter = CLAUDEMDExporter()
        return exporter.export(learnings: learnings, options: exportOptions)
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "CLAUDE.md"

        if panel.runModal() == .OK, let url = panel.url {
            let exporter = CLAUDEMDExporter()
            do {
                try exporter.exportToFile(learnings: learnings, url: url, options: exportOptions)
                dismiss()
            } catch {
                print("Export failed: \(error)")
            }
        }
    }
}

// MARK: - Extensions

extension LearningType {
    var iconName: String {
        switch self {
        case .correction: return "exclamationmark.triangle"
        case .positive: return "hand.thumbsup"
        case .implicit: return "lightbulb"
        }
    }

    var color: Color {
        switch self {
        case .correction: return .orange
        case .positive: return .green
        case .implicit: return .blue
        }
    }

    var displayName: String {
        switch self {
        case .correction: return "Correction"
        case .positive: return "Positive Feedback"
        case .implicit: return "Implicit Learning"
        }
    }
}

// MARK: - How Learnings Work Explainer

struct HowLearningsWorkView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("How Learnings Work")
                    .font(.title2.bold())
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Retain scans your AI conversations for:")
                        .font(.subheadline)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading) {
                            Text("Corrections").font(.subheadline.bold())
                            Text("\"Use X instead of Y\"").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading) {
                            Text("Positive Feedback").font(.subheadline.bold())
                            Text("\"Great, keep doing X\"").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text("Implicit Preferences").font(.subheadline.bold())
                            Text("\"I prefer X over Y\"").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Detection", systemImage: "magnifyingglass")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Pattern Matching") {
                        Text("Local regex rules, fast")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    LabeledContent("AI Analysis") {
                        Text("Uses CLI LLM for deeper understanding")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    LabeledContent("Hybrid") {
                        Text("Both methods for best results")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Extraction Modes", systemImage: "gearshape.2")
            }

            Text("Configure extraction mode in Settings → AI Analysis")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button("Got It") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 420, height: 480)
    }
}

#Preview {
    LearningReviewView()
        .environmentObject(AppState())
}
