import SwiftUI

struct AutomationView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedCluster: WorkflowCluster?
    @State private var isRefreshing = false
    @State private var showCloudAnalysisAlert = false
    @State private var pendingFullScan = false
    @State private var showResetAlert = false
    @State private var showHowItWorks = false
    @AppStorage("allowCloudAnalysis") private var allowCloudAnalysis = false
    @AppStorage("scanScopeDays") private var scanScopeDays = 0
    @AppStorage("scanScopeProjectOnly") private var scanScopeProjectOnly = false
    @AppStorage("scanScopeProviders") private var scanScopeProviders = ""
    @State private var showScopeSheet = false
    @State private var selectedProviders: Set<Provider> = []

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
            sidebar
            detail
        }
        .frame(minWidth: 900, minHeight: 500)
        .onAppear {
            refreshWorkflows(fullScan: false)
            if selectedCluster == nil {
                selectedCluster = appState.workflowClusters.first ?? appState.workflowPrimingClusters.first
            }
        }
        .onChange(of: appState.workflowClusters) { _, newValue in
            if let selectedCluster, newValue.contains(selectedCluster) {
                return
            }
            selectedCluster = newValue.first ?? appState.workflowPrimingClusters.first
        }
        .onChange(of: appState.workflowPrimingClusters) { _, newValue in
            if let selectedCluster,
               appState.workflowClusters.contains(selectedCluster) || newValue.contains(selectedCluster) {
                return
            }
            selectedCluster = appState.workflowClusters.first ?? newValue.first
        }
        .alert("Cloud Analysis", isPresented: $showCloudAnalysisAlert) {
            Button("Cancel", role: .cancel) {
                pendingFullScan = false
            }
            Button("Continue") {
                performRefresh(fullScan: pendingFullScan, resetExisting: false)
                pendingFullScan = false
            }
        } message: {
            Text("This will send conversation data to Claude for workflow analysis. Your data is processed according to Anthropic's privacy policy.")
        }
        .alert("Reset automation candidates?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset & Scan", role: .destructive) {
                performRefresh(fullScan: true, resetExisting: true)
            }
        } message: {
            Text("This clears existing automation candidates and rebuilds them from current conversations.")
        }
        .sheet(isPresented: $showHowItWorks) {
            HowAutomationWorksView()
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            AutomationHeader(
                count: appState.workflowClusters.count,
                primingCount: appState.workflowPrimingClusters.count,
                isRefreshing: isRefreshing,
                onRefresh: { refreshWorkflows(fullScan: true) },
                onReset: { showResetAlert = true },
                scopeSummary: scopeSummary,
                scanProgressText: scanProgressText,
                scanProgress: appState.llmOrchestrator.analysisProgress,
                scanErrorText: scanErrorText,
                onScopeTapped: { showScopeSheet = true },
                onInfoTapped: { showHowItWorks = true }
            )

            Divider()

            if appState.workflowClusters.isEmpty && appState.workflowPrimingClusters.isEmpty {
                if isRefreshing {
                    // Show skeleton loading state
                    SkeletonList(rowCount: 6)
                        .padding(.top, Spacing.md)
                } else {
                    AutomationEmptyState(
                        isRefreshing: isRefreshing,
                        onScan: { refreshWorkflows(fullScan: true) }
                    )
                }
            } else {
                List(selection: $selectedCluster) {
                    Section("Automation Candidates") {
                        ForEach(appState.workflowClusters) { cluster in
                            AutomationClusterRow(cluster: cluster)
                                .tag(cluster)
                        }
                    }

                    if !appState.workflowPrimingClusters.isEmpty {
                        Section {
                            Text("Setup prompts like “review docs” or “familiarize yourself” are excluded from automation candidates.")
                                .font(AppFont.caption2)
                                .foregroundColor(AppColors.secondaryText)
                                .listRowSeparator(.hidden)
                            ForEach(appState.workflowPrimingClusters) { cluster in
                                AutomationClusterRow(cluster: cluster)
                                    .tag(cluster)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Context Priming (excluded)")
                                Text("Initial setup messages that load context, not repeatable tasks.")
                                    .font(AppFont.caption2)
                                    .foregroundColor(AppColors.secondaryText)
                            }
                            .textCase(nil)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 450)
    }

    private var detail: some View {
        Group {
            if let cluster = selectedCluster {
                AutomationDetailView(cluster: cluster)
            } else {
                UnifiedEmptyState.noSelection(entityName: "Workflow")
            }
        }
    }

    private func refreshWorkflows(fullScan: Bool, resetExisting: Bool = false) {
        guard !isRefreshing else { return }

        // Show disclosure for full scans when cloud analysis is enabled
        if fullScan && allowCloudAnalysis && appState.llmOrchestrator.activeBackend == .claudeCode {
            pendingFullScan = true
            showCloudAnalysisAlert = true
            return
        }

        performRefresh(fullScan: fullScan, resetExisting: resetExisting)
    }

    private func performRefresh(fullScan: Bool, resetExisting: Bool) {
        isRefreshing = true
        Task {
            if resetExisting {
                if fullScan && allowCloudAnalysis && appState.llmOrchestrator.activeBackend == .claudeCode {
                    await appState.clearWorkflowSignatures()
                } else {
                    await appState.resetWorkflowInsights()
                    isRefreshing = false
                    return
                }
            }

            if fullScan && allowCloudAnalysis && appState.llmOrchestrator.activeBackend == .claudeCode {
                await appState.runFullCLIScan(types: [.workflow], scope: scanScope)
            } else {
                await appState.refreshWorkflowInsights(fullScan: fullScan)
            }
            isRefreshing = false
        }
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

private struct AutomationHeader: View {
    let count: Int
    let primingCount: Int
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onReset: () -> Void
    let scopeSummary: String
    let scanProgressText: String?
    let scanProgress: Double
    let scanErrorText: String?
    let onScopeTapped: () -> Void
    var onInfoTapped: (() -> Void)? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: 8) {
                    Text("Automation")
                        .font(AppFont.title2)
                        .accessibilityAddTraits(.isHeader)
                    if let onInfoTapped {
                        Button(action: onInfoTapped) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("How automation detection works")
                    }
                }
                Text(summaryText)
                    .font(AppFont.caption)
                    .foregroundColor(.secondary)

                Text("Automation candidates are repeated workflows (3+ similar requests) you can templatize.")
                    .font(AppFont.caption2)
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

            Spacer()

            HStack(spacing: 8) {
                Button("Reset") {
                    onReset()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)

                Button {
                    onRefresh()
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("Scan", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isRefreshing)
            }
        }
        .padding(Spacing.md)
        .background(AppColors.secondaryBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var summaryText: String {
        let total = count + primingCount
        if total == 0 {
            return "No workflows detected"
        }
        if primingCount > 0 {
            return "\(count) candidates • \(primingCount) context priming"
        }
        return "\(count) workflow\(count == 1 ? "" : "s") detected"
    }
}

private struct AutomationEmptyState: View {
    let isRefreshing: Bool
    let onScan: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.blue.opacity(0.6))

            Text("No Patterns Yet")
                .font(AppFont.title3)

            VStack(alignment: .leading, spacing: 12) {
                Text("Retain detects repeating workflows from your conversations.")
                    .font(AppFont.body)
                    .foregroundColor(AppColors.secondaryText)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Examples:")
                        .font(AppFont.caption.bold())
                        .foregroundColor(AppColors.secondaryText)

                    AutomationExampleRow(
                        pattern: "Review this PR",
                        frequency: "Code review workflow"
                    )
                    AutomationExampleRow(
                        pattern: "Explain this error",
                        frequency: "Debugging pattern"
                    )
                    AutomationExampleRow(
                        pattern: "Write tests for...",
                        frequency: "Test generation workflow"
                    )
                }
                .padding()
                .background(Color(.controlBackgroundColor))
                .cornerRadius(CornerRadius.lg)
            }
            .frame(maxWidth: 320)

            if !isRefreshing {
                Button("Scan Conversations") {
                    onScan()
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Workflows with 3+ runs become automation candidates")
                .font(AppFont.caption)
                .foregroundColor(AppColors.tertiaryText)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AutomationExampleRow: View {
    let pattern: String
    let frequency: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\"\(pattern)\"")
                .font(AppFont.caption)
                .foregroundColor(AppColors.primaryText)
                .italic()
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(AppColors.tertiaryText)
            Text(frequency)
                .font(AppFont.caption)
                .foregroundColor(AppColors.secondaryText)
        }
    }
}

private struct AutomationClusterRow: View {
    let cluster: WorkflowCluster

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cluster.displayTitle)
                .font(AppFont.body)
                .lineLimit(2)

            Text(cluster.automationIdea)
                .font(AppFont.caption)
                .foregroundColor(AppColors.secondaryText)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text("\(cluster.count) runs")
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
                Text("\(cluster.distinctProjects) projects")
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
            }

            HStack(spacing: 8) {
                Label(cluster.action, systemImage: "bolt.fill")
                    .font(AppFont.caption)
                Label(cluster.artifact, systemImage: "doc.text")
                    .font(AppFont.caption)
            }
            .foregroundColor(AppColors.secondaryText)
        }
        .padding(.vertical, Spacing.xs)
    }
}

private struct AutomationDetailView: View {
    let cluster: WorkflowCluster

    private var projectPaths: [String] {
        let unique = Set(cluster.samples.compactMap { $0.projectPath }.filter { !$0.isEmpty })
        return Array(unique).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(cluster.displayTitle)
                        .font(AppFont.title)

                    Text(cluster.displaySignature)
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)

                    Text("\(cluster.count) runs across \(cluster.distinctProjects) projects")
                        .font(AppFont.callout)
                        .foregroundColor(AppColors.secondaryText)
                }

                GroupBox("Automation idea") {
                    Text("Create a reusable prompt or script to \(cluster.displayTitle.lowercased()).")
                        .font(AppFont.callout)
                        .foregroundColor(AppColors.primaryText)
                }

                if cluster.action == "prime" {
                    Text("Context priming is a setup request (e.g., “read the docs first”). It prepares the assistant, but isn’t a repeatable task, so it’s excluded from automation candidates.")
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                }

                HStack(spacing: Spacing.md) {
                    Label(cluster.action, systemImage: "bolt.fill")
                        .font(AppFont.caption)
                    Label(cluster.artifact, systemImage: "doc.text")
                        .font(AppFont.caption)
                    if !cluster.domains.isEmpty {
                        Text(cluster.domains.joined(separator: ", "))
                            .font(AppFont.caption)
                            .foregroundColor(AppColors.secondaryText)
                    }
                }

                if !projectPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Distinct projects")
                            .font(AppFont.headline)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(projectPaths.prefix(6), id: \.self) { path in
                            Text(path)
                                .font(AppFont.caption)
                                .foregroundColor(AppColors.secondaryText)
                        }
                    }
                }

                if !cluster.samples.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Example prompts")
                            .font(AppFont.headline)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(cluster.samples) { sample in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sample.snippet)
                                    .font(AppFont.body)
                                HStack(spacing: 8) {
                                    Text(sample.projectPath?.isEmpty == false ? sample.projectPath! : "n/a")
                                        .font(AppFont.caption2)
                                        .foregroundColor(AppColors.secondaryText)
                                    Text(sample.sourceType)
                                        .font(AppFont.caption2)
                                        .foregroundColor(AppColors.secondaryText)
                                }
                            }
                            .padding(Spacing.sm)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(CornerRadius.md)
                        }
                    }
                }
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - How Automation Works Explainer

private struct HowAutomationWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("How Automation Works")
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
                    Text("Retain analyzes your conversations to detect:")
                        .font(.subheadline)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "repeat")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text("Repeating Patterns").font(.subheadline.bold())
                            Text("Same task requested 3+ times").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading) {
                            Text("Cross-Project Usage").font(.subheadline.bold())
                            Text("Similar workflows across different projects").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.purple)
                        VStack(alignment: .leading) {
                            Text("Action + Artifact").font(.subheadline.bold())
                            Text("What you ask (review, explain, write) + what you work on").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Detection", systemImage: "magnifyingglass")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Workflows are grouped by:")
                        .font(.subheadline)
                    HStack(spacing: 8) {
                        Label("Action", systemImage: "bolt.fill")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.1))
                            .cornerRadius(CornerRadius.lg)
                        Text("e.g., review, explain, write, fix")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Label("Artifact", systemImage: "doc.text")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(CornerRadius.lg)
                        Text("e.g., code, tests, docs, PR")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label("Grouping", systemImage: "rectangle.3.group")
            }

            Text("Context priming patterns (like CLAUDE.md reads) are automatically excluded.")
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
        .frame(width: 450, height: 520)
    }
}

#Preview {
    AutomationView()
        .environmentObject(AppState())
}
