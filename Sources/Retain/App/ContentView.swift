import SwiftUI

/// Main content view with three-column navigation
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                if appState.activeView == .automation || appState.activeView == .analytics || appState.activeView == .learnings {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        SidebarView()
                            .navigationSplitViewColumnWidth(
                                min: ColumnWidth.sidebarMin,
                                ideal: ColumnWidth.sidebarIdeal,
                                max: ColumnWidth.sidebarMax
                            )
                    } detail: {
                        switch appState.activeView {
                        case .automation:
                            AutomationView()
                        case .analytics:
                            AnalyticsView()
                        case .learnings:
                            LearningReviewView()
                        case .conversationList:
                            if let conversation = appState.selectedConversation {
                                ConversationDetailView(conversation: conversation)
                            } else {
                                EmptyStateView()
                            }
                        }
                    }
                } else {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        // Column 1: Sidebar (smart folders, providers)
                        SidebarView()
                            .navigationSplitViewColumnWidth(
                                min: ColumnWidth.sidebarMin,
                                ideal: ColumnWidth.sidebarIdeal,
                                max: ColumnWidth.sidebarMax
                            )
                    } content: {
                        // Column 2: Conversation list
                        ConversationListView()
                            .navigationSplitViewColumnWidth(
                                min: ColumnWidth.contentMin,
                                ideal: ColumnWidth.contentIdeal,
                                max: ColumnWidth.contentMax
                            )
                    } detail: {
                        // Column 3: Detail view (based on activeView)
                        switch appState.activeView {
                        case .conversationList:
                            if let conversation = appState.selectedConversation {
                                ConversationDetailView(conversation: conversation)
                            } else {
                                EmptyStateView()
                            }
                        case .learnings:
                            LearningReviewView()
                        case .analytics:
                            AnalyticsView()
                        case .automation:
                            AutomationView()
                        }
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 1120, minHeight: 600)  // +60pt for wider content pane
        .accessibilityIdentifier("MainWindow")
        .alert("Error", isPresented: .constant(appState.errorMessage != nil)) {
            Button("OK") {
                appState.errorMessage = nil
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert(
            "Keychain Access Required",
            isPresented: $appState.showingKeychainExplanation,
            presenting: appState.pendingKeychainContext
        ) { _ in
            Button("Continue") {
                appState.showingKeychainExplanation = false
                appState.pendingKeychainContext = nil
            }
            Button("Cancel", role: .cancel) {
                appState.showingKeychainExplanation = false
                appState.pendingKeychainContext = nil
            }
        } message: { context in
            Text(keychainExplanationMessage(for: context))
        }
        .showOnboardingIfNeeded()
        .onChange(of: hasCompletedOnboarding) { _, newValue in
            if !newValue {
                appState.enterOnboarding()
            }
        }
        // Non-blocking sync status bar at the bottom of the content area
        .safeAreaInset(edge: .bottom) {
            if appState.syncState.isSyncing {
                SyncStatusBar(syncState: appState.syncState) {
                    appState.cancelSync()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.syncState.isSyncing)
            }
        }
        .overlay(alignment: .top) {
            // Success toast
            if appState.showSyncCompleteToast, let stats = appState.lastSyncStats {
                SyncCompleteToast(stats: stats) {
                    appState.showSyncCompleteToast = false
                }
                .padding(.top, Spacing.lg)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.showSyncCompleteToast)
            }

            // Error banner
            if appState.showSyncErrorBanner {
                SyncErrorBanner(
                    message: appState.syncErrorMessage,
                    onRetry: {
                        appState.showSyncErrorBanner = false
                        Task {
                            await appState.syncAll()
                        }
                    },
                    onDismiss: {
                        appState.showSyncErrorBanner = false
                    }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.lg)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.showSyncErrorBanner)
            }
        }
    }
}

// MARK: - Sidebar Section Header

/// Apple HIG-compliant sidebar section header with small caps styling
struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.5)
            .foregroundColor(AppColors.tertiaryText.opacity(0.8))
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(title)
    }
}

// MARK: - Sidebar View

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState

    // Core providers always shown in sidebar
    private let coreProviders: Set<Provider> = [.claudeCode, .codex, .claudeWeb, .chatgptWeb]

    // AppStorage bindings for provider enabled state
    @AppStorage("opencodeEnabled") private var opencodeEnabled = false
    @AppStorage("geminiCLIEnabled") private var geminiCLIEnabled = false
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage("cursorEnabled") private var cursorEnabled = false

    /// Providers to show in sidebar: core 4 + enabled non-core providers
    private var visibleProviders: [Provider] {
        Provider.allCases.filter { provider in
            guard provider.isSupported else { return false }
            // Always show core providers
            if coreProviders.contains(provider) { return true }
            // Show non-core only if enabled
            return isProviderEnabled(provider)
        }
    }

    /// Check if a non-core provider is enabled
    private func isProviderEnabled(_ provider: Provider) -> Bool {
        switch provider {
        case .opencode: return opencodeEnabled
        case .geminiCLI: return geminiCLIEnabled
        case .copilot: return copilotEnabled
        case .cursor: return cursorEnabled
        default: return true  // Core providers always enabled
        }
    }

    var body: some View {
        List(selection: $appState.sidebarSelection) {
            // Smart Folders Section
            Section {
                ForEach(SmartFolder.allCases) { folder in
                    SmartFolderRow(
                        folder: folder,
                        count: countForFolder(folder),
                        isSelected: appState.sidebarSelection == .smartFolder(folder)
                    )
                    .tag(SidebarItem.smartFolder(folder))
                }
            } header: {
                SidebarSectionHeader(title: "Smart Folders")
            }

            // Providers Section (core providers + enabled non-core providers)
            Section {
                ForEach(visibleProviders, id: \.self) { provider in
                    ProviderSidebarRow(
                        provider: provider,
                        count: appState.providerStats[provider] ?? 0,
                        isSelected: appState.sidebarSelection == .provider(provider),
                        syncStatus: syncStatus(for: provider),
                        connectionStatus: connectionStatus(for: provider)
                    )
                    .tag(SidebarItem.provider(provider))
                }
            } header: {
                SidebarSectionHeader(title: "Providers")
            }

            // Features Section
            Section {
                NavigationLink(value: SidebarItem.learnings) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: IconSize.lg))
                            .foregroundColor(.yellow)
                            .frame(width: IconSize.xl)

                        Text("Learnings")
                            .font(AppFont.body)

                        Spacer()

                        if appState.pendingLearningsCount > 0 {
                            Text("\(appState.pendingLearningsCount)")
                                .font(AppFont.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, Spacing.xxs)
                                .background(AppColors.pending)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                }
                .accessibilityIdentifier("Sidebar_Learnings")

                NavigationLink(value: SidebarItem.analytics) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: IconSize.lg))
                            .foregroundColor(.blue)
                            .frame(width: IconSize.xl)

                        Text("Analytics")
                            .font(AppFont.body)
                    }
                    .padding(.vertical, Spacing.xs)
                }
                .accessibilityIdentifier("Sidebar_Analytics")

                NavigationLink(value: SidebarItem.automation) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "flowchart")
                            .font(.system(size: IconSize.lg))
                            .foregroundColor(.green)
                            .frame(width: IconSize.xl)

                        Text("Automation")
                            .font(AppFont.body)
                    }
                    .padding(.vertical, Spacing.xs)
                }
                .accessibilityIdentifier("Sidebar_Automation")
            } header: {
                SidebarSectionHeader(title: "Features")
            }

            // Setup Progress Section (for first-time users)
            if !hasCompletedSetup {
                SetupProgressSection(progress: setupProgress, hint: setupHint)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("Sidebar")
        .onChange(of: appState.sidebarSelection) { oldValue, newValue in
            // Defer to avoid NSTableView reentrant operation warning
            DispatchQueue.main.async {
                handleSidebarSelection(newValue)
            }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarFooter()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await appState.syncAll()
                    }
                } label: {
                    Label("Sync", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isSyncing)
                .accessibilityIdentifier("SyncButton")
            }
        }
    }

    private func countForFolder(_ folder: SmartFolder) -> Int {
        switch folder {
        case .today:
            return appState.conversations.filter { Calendar.current.isDateInToday($0.updatedAt) }.count
        case .thisWeek:
            return appState.conversations.filter {
                Calendar.current.isDate($0.updatedAt, equalTo: Date(), toGranularity: .weekOfYear)
            }.count
        case .withLearnings:
            return appState.conversationsWithLearnings.count
        }
    }

    private func syncStatus(for provider: Provider) -> ProviderSidebarRow.SyncStatus {
        if let progress = appState.syncState.providerProgress[provider] {
            switch progress.phase {
            case .completed:
                return .idle
            case .failed:
                return .error
            default:
                return .syncing
            }
        }
        if appState.syncState.errors[provider] != nil {
            return .error
        }
        return .idle
    }

    private func connectionStatus(for provider: Provider) -> ProviderSidebarRow.ConnectionStatus? {
        guard provider == .claudeWeb || provider == .chatgptWeb else {
            return nil
        }
        let state = appState.webSyncEngine.getSessionState(for: provider)
        switch state {
        case .connected:
            return .connected
        case .connecting:
            return .verifying
        case .sessionSaved:
            return .saved
        case .notConnected:
            return .disconnected
        case .error:
            return .error
        }
    }

    private func handleSidebarSelection(_ selection: SidebarItem?) {
        switch selection {
        case .smartFolder(let folder):
            appState.activeView = .conversationList
            appState.filterBy(smartFolder: folder)
        case .provider(let provider):
            appState.activeView = .conversationList
            appState.filterBy(provider: provider)
        case .learnings:
            appState.activeView = .learnings
            appState.clearFilter()
            appState.clearSelection()  // Clear conversation filter so all learnings show
        case .analytics:
            appState.activeView = .analytics
            appState.clearFilter()
            appState.clearSelection()
        case .automation:
            appState.activeView = .automation
            appState.clearFilter()
            appState.clearSelection()
        case .none:
            appState.activeView = .conversationList
            appState.clearFilter()
        }
    }

    // MARK: - Setup Progress

    /// Calculate setup progress based on connected providers
    private var setupProgress: Double {
        var progress = 0.0
        let conversations = appState.conversations
        // Each provider contributes ~33% to setup progress
        if conversations.contains(where: { $0.provider == .claudeCode }) { progress += 1.0 / 3.0 }
        if conversations.contains(where: { $0.provider == .claudeWeb }) { progress += 1.0 / 3.0 }
        if conversations.contains(where: { $0.provider == .chatgptWeb }) { progress += 1.0 / 3.0 }
        return min(progress, 1.0)
    }

    /// Contextual hint for the next setup step
    private var setupHint: String {
        if setupProgress == 0 { return "Click Sync to import conversations" }
        if setupProgress < 1.0 { return "Connect more providers in Settings" }
        return "Setup complete!"
    }

    /// Whether setup is complete (all steps done)
    private var hasCompletedSetup: Bool {
        setupProgress >= 1.0
    }
}

// MARK: - Setup Progress Section

/// Setup progress indicator for first-time users
struct SetupProgressSection: View {
    let progress: Double
    let hint: String

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Setup Progress")
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.tertiaryText)

                ProgressView(value: progress, total: 1.0)
                    .tint(.accentColor)

                Text(hint)
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
            }
            .padding(.vertical, Spacing.xs)
        }
    }
}

// MARK: - Smart Folder Row

struct SmartFolderRow: View {
    let folder: SmartFolder
    let count: Int
    let isSelected: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: folder.iconName)
                .font(.system(size: IconSize.lg))
                .foregroundColor(folder.color)
                .frame(width: IconSize.xl)

            Text(folder.rawValue)
                .font(AppFont.body)
                .foregroundColor(AppColors.primaryText)

            Spacer()

            if count > 0 {
                Text("\(count)")
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.primaryText)
                    .frame(minWidth: 24)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(CornerRadius.md)
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .focusRing(isFocused, cornerRadius: CornerRadius.md)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .focusable()
        .focused($isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("Sidebar_\(folder.rawValue)")
        .accessibilityLabel("\(folder.rawValue), \(count) conversations")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Sidebar Footer

struct SidebarFooter: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingSettingsSheet = false
    @State private var pulseAnimation = false

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Divider()

            HStack(spacing: Spacing.md) {
                // Sync status
                if appState.syncState.isSyncing {
                    HStack(spacing: Spacing.xs) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(syncingText)
                            .font(AppFont.caption)
                            .foregroundColor(AppColors.secondaryText)
                    }
                } else if let lastSync = appState.syncState.lastSyncDate {
                    Text("Last sync: \(lastSync.formatted(.relative(presentation: .named)))")
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                } else {
                    // First-time user - more prominent pulsing indicator
                    HStack(spacing: Spacing.xs) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            .opacity(pulseAnimation ? 0.3 : 1.0)
                            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulseAnimation)

                        Text("Not synced yet")
                            .font(AppFont.caption)
                            .foregroundColor(Color.orange)
                    }
                    .onAppear { pulseAnimation = true }
                }

                Spacer()

                // Settings button
                Button {
                    let bundlePath = Bundle.main.bundleURL.path
                    let isSwiftPMBuild = bundlePath.contains(".build") || bundlePath.contains("swiftpm")
                    if isSwiftPMBuild {
                        showingSettingsSheet = true
                        return
                    }

                    let didOpen = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    if !didOpen {
                        showingSettingsSheet = true
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: IconSize.md))
                        .foregroundColor(AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("SettingsButton")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)
        }
        .background(AppColors.background)
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView(showCloseButton: true)
                .environmentObject(appState)
        }
    }

    private var syncingText: String {
        let progress = Int(appState.syncState.overallProgress * 100)
        return progress > 0 ? "Syncing \(progress)%..." : "Syncing..."
    }
}

// MARK: - Conversation List View

struct ConversationListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sortOrder: SortOrder = .updatedAt
    @FocusState private var isSearchFieldFocused: Bool
    @State private var conversationToDelete: Conversation?
    @State private var showDeleteConfirmation = false

    enum SortOrder: String, CaseIterable {
        case updatedAt = "Recent"
        case createdAt = "Created"
        case messageCount = "Messages"
    }

    /// Check if search is active
    private var isSearchActive: Bool {
        !appState.searchQuery.isEmpty
    }

    /// Custom binding that calls select() when selection changes
    private var selectionBinding: Binding<Conversation?> {
        Binding(
            get: { appState.selectedConversation },
            set: { newValue in
                #if DEBUG
                print("📋 selectionBinding.set called: \(newValue?.title ?? "nil")")
                #endif
                if let conversation = newValue {
                    appState.select(conversation)
                } else {
                    appState.clearSelection()
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search and sort
            ConversationListHeader(
                searchText: $appState.searchQuery,
                sortOrder: $sortOrder,
                resultCount: filteredConversations.count,
                isSearchActive: isSearchActive,
                isSearchFieldFocused: $isSearchFieldFocused
            )
            .onChange(of: appState.shouldFocusSearch) { _, shouldFocus in
                if shouldFocus {
                    isSearchFieldFocused = true
                    appState.shouldFocusSearch = false
                }
            }

            Divider()

            // Conversation list
            if filteredConversations.isEmpty {
                if isSearchActive {
                    EmptySearchResultsView(query: appState.searchQuery)
                } else {
                    EmptyConversationListView(hasFilter: appState.activeFilter != nil)
                }
            } else {
                List(selection: selectionBinding) {
                    ForEach(sortedConversations) { conversation in
                        ConversationListRow(
                            conversation: conversation,
                            searchMatchedText: searchResult(for: conversation)?.matchedText
                        )
                            .tag(conversation)
                            .accessibilityIdentifier("ConversationRow_\(conversation.id.uuidString)")
                            .listRowInsets(EdgeInsets(
                                top: Spacing.xs,
                                leading: Spacing.sm,
                                bottom: Spacing.xs,
                                trailing: Spacing.sm
                            ))
                            .contextMenu {
                                Button {
                                    appState.toggleStar(conversation)
                                } label: {
                                    Label(
                                        appState.isStarred(conversation) ? "Unstar" : "Star",
                                        systemImage: appState.isStarred(conversation) ? "star.slash" : "star"
                                    )
                                }

                                Divider()

                                Button(role: .destructive) {
                                    conversationToDelete = conversation
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("ConversationList")
            }
        }
        .accessibilityIdentifier("ConversationListView")
        .navigationTitle(navigationTitle)
        .navigationSubtitle("\(filteredConversations.count) conversations")
        .onChange(of: appState.activeFilter) { _, _ in
            // Auto-select first conversation when filter changes and none selected
            if appState.selectedConversation == nil,
               let first = sortedConversations.first {
                appState.select(first)
            }
        }
        .alert("Delete Conversation", isPresented: $showDeleteConfirmation, presenting: conversationToDelete) { conversation in
            Button("Cancel", role: .cancel) {
                conversationToDelete = nil
            }
            Button("Delete", role: .destructive) {
                appState.delete(conversation)
                conversationToDelete = nil
            }
        } message: { conversation in
            Text("Are you sure you want to delete \"\(conversation.title ?? "Untitled")\"? This action cannot be undone.")
        }
    }

    private var navigationTitle: String {
        if let filter = appState.activeFilter {
            return filter
        }
        return "All Conversations"
    }

    private var filteredConversations: [Conversation] {
        // If search is active, show search results
        if isSearchActive {
            let allowedIds: Set<UUID>? = appState.activeFilter == nil
                ? nil
                : Set(appState.filteredConversations.map { $0.id })
            // Deduplicate conversations from search results
            var seen = Set<UUID>()
            return appState.searchResults.compactMap { result -> Conversation? in
                if let allowedIds, !allowedIds.contains(result.conversation.id) {
                    return nil
                }
                guard !seen.contains(result.conversation.id) else { return nil }
                seen.insert(result.conversation.id)
                return result.conversation
            }
        }

        // Otherwise show filtered conversations from sidebar selection
        return appState.filteredConversations
    }

    /// Get the search result for a conversation (if showing search results)
    private func searchResult(for conversation: Conversation) -> AppState.SearchResult? {
        guard isSearchActive else { return nil }
        return appState.searchResults.first { $0.conversation.id == conversation.id }
    }

    private var sortedConversations: [Conversation] {
        if isSearchActive {
            return filteredConversations
        }
        switch sortOrder {
        case .updatedAt:
            return filteredConversations.sorted { $0.updatedAt > $1.updatedAt }
        case .createdAt:
            return filteredConversations.sorted { $0.createdAt > $1.createdAt }
        case .messageCount:
            return filteredConversations.sorted { $0.messageCount > $1.messageCount }
        }
    }
}

// MARK: - Conversation List Header

struct ConversationListHeader: View {
    @Binding var searchText: String
    @Binding var sortOrder: ConversationListView.SortOrder
    let resultCount: Int
    var isSearchActive: Bool = false
    var isSearchFieldFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: Spacing.sm) {
            // Search field
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: IconSize.sm))
                    .foregroundColor(isSearchActive ? .accentColor : AppColors.secondaryText)

                TextField("Search conversations...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(AppFont.body)
                    .focused(isSearchFieldFocused)
                    .accessibilityIdentifier("SearchField")

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: IconSize.sm))
                            .foregroundColor(AppColors.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(CornerRadius.md)

            // Sort controls / Search results indicator
            HStack {
                if isSearchActive {
                    // Search result count badge (WCAG AA 4.5:1 contrast)
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: IconSize.xs))
                        Text("\(resultCount) results")
                    }
                    .font(AppFont.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                } else {
                    Text("Sort by")
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.secondaryText)
                }

                Spacer()

                Picker("Sort", selection: $sortOrder) {
                    ForEach(ConversationListView.SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(AppFont.caption)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
}

// MARK: - Conversation List Row

struct ConversationListRow: View {
    let conversation: Conversation
    var searchMatchedText: String? = nil
    @EnvironmentObject private var appState: AppState
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Line 1: Provider badge + Title
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                ProviderBadge(provider: conversation.provider, size: .small)

                Text(conversation.displayTitle)
                    .font(AppFont.bodyMedium)
                    .foregroundColor(AppColors.primaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(conversation.displayTitle)

                Spacer()

                Text(compactRelativeTime(from: conversation.updatedAt))
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
            }

            // Line 2: Project/Source info (if available)
            if let projectPath = conversation.projectPath {
                HStack {
                    Text(projectPath.components(separatedBy: "/").last ?? projectPath)
                        .font(AppFont.caption)
                        .foregroundColor(AppColors.tertiaryText)
                        .lineLimit(1)
                    Spacer()
                }
            }

            // Search match snippet (if showing search results)
            if let matchedText = searchMatchedText, !matchedText.isEmpty {
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: IconSize.xs))
                        .foregroundColor(.accentColor)
                    highlightedText(matchedText, matching: appState.searchQuery)
                        .font(AppFont.callout)
                        .foregroundColor(AppColors.secondaryText)
                        .lineLimit(2)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(CornerRadius.sm)
            }
            // Preview (if available and not showing search match)
            else if let preview = conversation.preview {
                Text(preview)
                    .font(AppFont.callout)
                    .fontWeight(.light)
                    .foregroundColor(AppColors.tertiaryText)
                    .lineLimit(2)
            }

            // Bottom row: Stats + indicators
            HStack(spacing: Spacing.md) {
                // Message count
                Label("\(conversation.messageCount)", systemImage: "bubble.left")
                    .font(AppFont.caption2)
                    .foregroundColor(AppColors.secondaryText)

                Spacer()

                // Learning indicator
                if appState.hasLearnings(conversation) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: IconSize.xs))
                        .foregroundColor(.orange)
                }

                // Star indicator
                if appState.isStarred(conversation) {
                    Image(systemName: "star.fill")
                        .font(.system(size: IconSize.xs))
                        .foregroundColor(.yellow)
                }
            }
        }
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.sm)
        .background(isHovering ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(CornerRadius.md)
        .focusRing(isFocused, cornerRadius: CornerRadius.md)
        .scaleEffect(isHovering ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .focusable()
        .focused($isFocused)
        .accessibilityLabel("\(conversation.displayTitle), \(conversation.provider.displayName)")
        .accessibilityHint("Select to view conversation messages")
        .accessibilityAddTraits(.isButton)
    }

    /// Compact relative time format: "Just now", "5m ago", "2h ago", "Yesterday", "3d ago", or abbreviated date
    private func compactRelativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 172800 { return "Yesterday" }  // 24-48 hours
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Highlights search matches in text with bold + accent color
    private func highlightedText(_ text: String, matching query: String) -> Text {
        guard !query.isEmpty else { return Text(text) }

        let lowercasedText = text.lowercased()
        let lowercasedQuery = query.lowercased()

        var result = Text("")
        var currentIndex = text.startIndex

        while let range = lowercasedText.range(of: lowercasedQuery,
                                                range: currentIndex..<text.endIndex) {
            // Text before match
            if currentIndex < range.lowerBound {
                let beforeRange = currentIndex..<range.lowerBound
                result = result + Text(text[beforeRange])
            }
            // Highlighted match
            let matchRange = range.lowerBound..<range.upperBound
            result = result + Text(text[matchRange])
                .bold()
                .foregroundColor(.accentColor)

            currentIndex = range.upperBound
        }

        // Remaining text
        if currentIndex < text.endIndex {
            result = result + Text(text[currentIndex...])
        }

        return result
    }
}

// MARK: - Keychain Explanation Helper

/// Generates user-friendly explanation for keychain access requests
private func keychainExplanationMessage(for context: BrowserCookieKeychainPromptContext) -> String {
    """
    Retain needs to access "\(context.label)" in your Keychain to decrypt browser cookies.

    This is required to sync your conversations from claude.ai and chatgpt.com. \
    Your browser encrypts cookies using a key stored in the Keychain.

    After clicking Continue, macOS will ask you to allow access. \
    Click "Always Allow" to avoid this prompt in the future.
    """
}

// MARK: - Empty States

/// Empty state view for the detail pane
struct EmptyStateView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.conversations.isEmpty {
            UnifiedEmptyState.welcome {
                Task { await appState.syncAll() }
            }
        } else {
            UnifiedEmptyState.noSelection()
        }
    }
}

/// Empty state for conversation list
struct EmptyConversationListView: View {
    @EnvironmentObject private var appState: AppState
    let hasFilter: Bool
    @State private var showingSettingsSheet = false

    var body: some View {
        Group {
            if let provider = appState.selectedFilterProvider {
                providerEmptyState(for: provider)
            } else if hasFilter {
                UnifiedEmptyState(
                    style: .noResults,
                    title: "No matching conversations",
                    subtitle: "Try adjusting your search or filter"
                )
            } else {
                UnifiedEmptyState.noData(
                    title: "No conversations yet",
                    subtitle: "Sync your Claude Code conversations or connect to claude.ai"
                )
            }
        }
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView(initialTab: .webAccounts, showCloseButton: true)
                .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func providerEmptyState(for provider: Provider) -> some View {
        switch provider {
        case .claudeWeb:
            webProviderEmptyState(
                provider: provider,
                isConnected: appState.webSyncEngine.claudeConnectionStatus.isConnected,
                hasSynced: appState.syncedProviders.contains(.claudeWeb),
                providerName: "claude.ai"
            )
        case .chatgptWeb:
            webProviderEmptyState(
                provider: provider,
                isConnected: appState.webSyncEngine.chatgptConnectionStatus.isConnected,
                hasSynced: appState.syncedProviders.contains(.chatgptWeb),
                providerName: "ChatGPT"
            )
        case .claudeCode, .codex, .gemini, .opencode, .geminiCLI, .copilot, .cursor:
            // CLI providers - always show no data state
            UnifiedEmptyState.noData(
                title: "No \(provider.displayName) conversations",
                subtitle: "Your \(provider.displayName) conversations will appear here after syncing"
            )
        }
    }

    @ViewBuilder
    private func webProviderEmptyState(
        provider: Provider,
        isConnected: Bool,
        hasSynced: Bool,
        providerName: String
    ) -> some View {
        if isProviderSyncing(provider) {
            UnifiedEmptyState.providerSyncing(providerName: providerName)
        } else if !isConnected {
            // Not connected - show connect prompt
            UnifiedEmptyState.providerDisconnected(providerName: providerName) {
                openSettings()
            }
        } else if !hasSynced {
            // Connected but never synced - show sync prompt
            let providersToSync = connectedWebProviders()
            let label = providersToSync.count > 1 ? "Sync All Web" : "Sync Now"
            UnifiedEmptyState.providerNeedsSync(providerName: providerName, actionLabel: label) {
                Task { await appState.syncAll(webProviders: Set(providersToSync)) }
            }
        } else {
            // Connected and synced but empty
            UnifiedEmptyState.providerEmpty(providerName: providerName)
        }
    }

    private func connectedWebProviders() -> [Provider] {
        var providers: [Provider] = []
        if appState.webSyncEngine.claudeConnectionStatus.isConnected {
            providers.append(.claudeWeb)
        }
        if appState.webSyncEngine.chatgptConnectionStatus.isConnected {
            providers.append(.chatgptWeb)
        }
        if providers.isEmpty, let selected = appState.selectedFilterProvider, selected.isWebProvider {
            providers.append(selected)
        }
        return providers
    }

    private func isProviderSyncing(_ provider: Provider) -> Bool {
        guard let progress = appState.syncState.providerProgress[provider] else { return false }
        switch progress.phase {
        case .completed, .failed:
            return false
        default:
            return true
        }
    }

    private func openSettings() {
        showingSettingsSheet = true
    }
}

/// Empty state for search results
struct EmptySearchResultsView: View {
    let query: String

    var body: some View {
        UnifiedEmptyState.noResults(query: query)
    }
}

// MARK: - Sidebar Selection

enum SidebarItem: Hashable {
    case smartFolder(SmartFolder)
    case provider(Provider)
    case learnings
    case analytics
    case automation
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
}
