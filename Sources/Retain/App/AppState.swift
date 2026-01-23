import SwiftUI
import Combine
import ServiceManagement

/// Global application state
@MainActor
final class AppState: ObservableObject {
    // MARK: - Settings

    @AppStorage("autoExtractLearnings") var autoExtractLearnings: Bool = true
    @AppStorage("learningConfidenceThreshold") var learningConfidenceThreshold: Double = 0.8
    @AppStorage("learningExtractionMode") var learningExtractionMode: LearningExtractionMode = .semantic
    @AppStorage("includeImplicitLearnings") var includeImplicitLearnings: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("syncOnLaunch") var syncOnLaunch: Bool = true
    @AppStorage("autoSyncEnabled") var autoSyncEnabled: Bool = true
    @AppStorage("autoSyncInterval") var autoSyncInterval: Int = 300 // 5 minutes
    @AppStorage("semanticSearchEnabled") var semanticSearchEnabled: Bool = true
    @AppStorage("ollamaModel") var ollamaModel: String = "nomic-embed-text"
    @AppStorage("ollamaEndpoint") var ollamaEndpoint: String = "http://localhost:11434"
    @AppStorage("claudeCodeEnabled") var claudeCodeEnabled: Bool = true
    @AppStorage("codexEnabled") var codexEnabled: Bool = true
    @AppStorage("opencodeEnabled") var opencodeEnabled: Bool = false
    @AppStorage("geminiCLIEnabled") var geminiCLIEnabled: Bool = false
    @AppStorage("copilotEnabled") var copilotEnabled: Bool = false
    @AppStorage("cursorEnabled") var cursorEnabled: Bool = false
    @AppStorage("geminiWorkflowEnabled") var geminiWorkflowEnabled: Bool = false
    @AppStorage("geminiWorkflowModel") var geminiWorkflowModel: String = "gemini-3-flash-preview"

    /// Gemini API key (stored in Keychain for security)
    @Published private(set) var geminiApiKey: String = ""

    /// Update Gemini API key (saves to Keychain)
    func setGeminiApiKey(_ key: String) {
        geminiApiKey = key
        KeychainHelper.geminiApiKey = key
        updateGeminiConfiguration()
    }
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false

    // MARK: - Published State

    /// All conversations
    @Published var conversations: [Conversation] = []

    /// Currently selected conversation
    @Published var selectedConversation: Conversation?

    /// Messages for selected conversation
    @Published var selectedMessages: [Message] = []

    /// Whether messages are currently loading (for async fetch)
    @Published private(set) var isLoadingMessages: Bool = false

    /// Current search query
    @Published var searchQuery: String = ""

    /// Search results
    @Published var searchResults: [SearchResult] = []

    /// Pending learnings count
    @Published var pendingLearningsCount: Int = 0

    /// Provider stats
    @Published var providerStats: [Provider: Int] = [:]

    /// Error message to display
    @Published var errorMessage: String?

    /// Focus search field
    @Published var shouldFocusSearch: Bool = false
    @Published var searchMessagesOnly: Bool = false

    // MARK: - Sync State (New Architecture)

    /// Observable sync state for UI binding
    let syncState = SyncState()

    /// Last completed sync stats (for toast display)
    @Published var lastSyncStats: SyncStats?

    /// Whether to show sync complete toast
    @Published var showSyncCompleteToast: Bool = false

    /// Whether to show sync error banner
    @Published var showSyncErrorBanner: Bool = false
    @Published var syncErrorMessage: String = ""

    // MARK: - Undo Delete State

    /// Recently deleted conversation (for undo functionality)
    @Published var recentlyDeletedConversation: Conversation?

    /// Whether to show the undo delete toast
    @Published var showUndoDeleteToast: Bool = false

    /// Timer task for auto-dismissing undo toast
    private var undoToastDismissTask: Task<Void, Never>?

    // MARK: - Legacy sync properties (for backward compatibility)
    // TODO: Remove these after migrating all views to use syncState

    /// Is currently syncing (computed from syncState)
    var isSyncing: Bool { syncState.isSyncing }

    /// Sync progress (computed from syncState)
    var syncProgress: Double { syncState.overallProgress }

    /// Last sync date (computed from syncState)
    var lastSyncDate: Date? { syncState.lastSyncDate }

    // MARK: - UI State

    /// Active view in the detail pane
    enum ActiveView {
        case conversationList
        case learnings
        case analytics
        case automation
    }

    /// Currently active view (detail pane)
    @Published var activeView: ActiveView = .conversationList

    /// Sidebar selection
    @Published var sidebarSelection: SidebarItem?

    /// Currently active filter name (for display)
    @Published var activeFilter: String?

    /// Currently filtered provider (if filtering by provider)
    @Published var selectedFilterProvider: Provider?

    /// Providers that have been synced at least once
    @Published var syncedProviders: Set<Provider> = []

    /// Filtered conversations based on current selection
    @Published var filteredConversations: [Conversation] = []

    /// Set of starred conversation IDs
    @Published var starredConversationIds: Set<UUID> = []

    /// Set of conversation IDs with learnings
    @Published var conversationIdsWithLearnings: Set<UUID> = []

    /// Pending learnings count per conversation
    @Published var conversationLearningCounts: [UUID: Int] = [:]

    /// Pending analysis suggestions (title, summary, merge)
    @Published var pendingSuggestions: [AnalysisSuggestion] = []

    /// Analysis result processor for handling suggestions
    private lazy var analysisResultProcessor = AnalysisResultProcessor()

    /// Workflow automation candidates
    @Published var workflowClusters: [WorkflowCluster] = []
    /// Context priming clusters (excluded from automation)
    @Published var workflowPrimingClusters: [WorkflowCluster] = []

    // MARK: - Keychain Prompt State

    /// Shows an explanation before browser keychain access
    @Published var showingKeychainExplanation: Bool = false
    /// Context for the pending keychain access
    @Published var pendingKeychainContext: BrowserCookieKeychainPromptContext?

    /// Currently syncing providers (computed from syncState)
    var syncingProviders: Set<Provider> {
        Set(syncState.providerProgress.keys)
    }

    /// Provider-specific errors (computed from syncState)
    var providerErrors: [Provider: String] {
        syncState.errors
    }

    // MARK: - Computed Properties

    /// Starred conversations
    var starredConversations: [Conversation] {
        conversations.filter { starredConversationIds.contains($0.id) }
    }

    /// Conversations with learnings
    var conversationsWithLearnings: [Conversation] {
        conversations.filter { conversationIdsWithLearnings.contains($0.id) }
    }

    // MARK: - Services

    private let repository = ConversationRepository()
    private let learningRepository = LearningRepository()
    private let fileWatcher = FileWatcher()

    /// Background sync service (runs off main thread)
    private let syncService: SyncService

    /// Web sync engine for claude.ai and chatgpt.com
    /// Lazy to defer keychain access until after onboarding
    private var _webSyncEngine: WebSyncEngine?
    var webSyncEngine: WebSyncEngine {
        if _webSyncEngine == nil {
            // Skip initial session check and defer keychain persistence during onboarding
            // Session check will be triggered after user clicks "Connect" or after onboarding
            _webSyncEngine = WebSyncEngine(
                skipInitialSessionCheck: !hasCompletedOnboarding,
                deferKeychainPersistence: !hasCompletedOnboarding
            )
        }
        return _webSyncEngine!
    }

    /// Ollama service for semantic embeddings
    let ollamaService = OllamaService()

    /// Learning queue for extraction and review
    lazy var learningQueue = LearningQueue()

    /// Workflow signature detection + aggregation
    private let workflowSignatureService = WorkflowSignatureService()

    /// Hybrid search service (FTS + semantic)
    lazy var semanticSearch = SemanticSearch(ollama: ollamaService, repository: repository)

    /// CLI LLM orchestrator for AI analysis
    let llmOrchestrator = LLMOrchestrator()

    /// Stale claims reaper for queue maintenance
    private let staleClaimsReaper = StaleClaimsReaper()

    private var cancellables = Set<AnyCancellable>()
    private var webSyncCancellable: AnyCancellable?
    private var webSyncSessionExpiredCancellable: AnyCancellable?
    private var syncStateCancellable: AnyCancellable?
    private var syncTask: Task<Void, Never>?

    /// Pending providers to sync after current sync completes
    /// Used when user enables a provider while a sync is already running
    private var pendingSyncProviders: Set<Provider> = []

    /// Pending file URLs for debounced incremental sync
    private var pendingFileChanges: Set<URL> = []
    private var fileChangeDebounceTask: Task<Void, Never>?
    /// Maximum pending file changes before forcing immediate sync (prevents unbounded memory growth)
    private let maxPendingFileChanges = 100

    /// Auto-sync timer task
    private var autoSyncTask: Task<Void, Never>?

    // MARK: - Search Result

    struct SearchResult: Identifiable {
        let id = UUID()
        let conversation: Conversation
        let message: Message?
        let matchedText: String
    }

    // MARK: - Initialization

    init(syncService: SyncService = SyncService()) {
        self.syncService = syncService

        // DEFER keychain access until after onboarding to avoid prompts on first launch
        // Keychain migration and gemini key load happens in activateAfterOnboarding()

        setupKeychainPromptHandler()
        setupSearchDebounce()
        setupSyncService()
        setupLearningObservers()
        setupCLIPathObservers()
        updateOllamaConfiguration()
        updateLearningConfidenceThreshold()
        updateLearningExtractionMode()
        updateImplicitLearningPreference()
        updateGeminiConfiguration()
        updateCLIConfiguration()
        updateLaunchAtLogin()
        // NOTE: observeWebSyncChanges() is called in activateAfterOnboarding()
        // to defer webSyncEngine initialization until after onboarding
        observeSyncStateChanges()

        if hasCompletedOnboarding {
            activateAfterOnboarding(triggerInitialSync: syncOnLaunch)
        } else {
            resetForOnboarding()
        }

        // Start stale claims reaper for CLI LLM queue maintenance
        Task {
            await staleClaimsReaper.start()
        }

        // Clean up orphaned CLI temp directories from previous sessions/crashes
        Task {
            await llmOrchestrator.cliService.cleanupOrphanedTempDirs()
        }

        // Sync on launch if enabled AND onboarding is complete
        // CRITICAL: Don't sync until user has consented via onboarding
        // NOTE: initial sync handled by activateAfterOnboarding
    }

    private func observeWebSyncChanges() {
        webSyncCancellable = webSyncEngine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        webSyncSessionExpiredCancellable = webSyncEngine.$sessionExpiredNotification
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.syncErrorMessage = "\(notification.provider.displayName) session expired. Please reconnect."
                self?.showSyncErrorBanner = true
                self?.webSyncEngine.clearSessionExpiredNotification()
            }
    }

    private func observeSyncStateChanges() {
        syncStateCancellable = syncState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    /// Set up handler to show in-app explanation before browser keychain access
    private func setupKeychainPromptHandler() {
        BrowserCookieKeychainPromptHandler.handler = { [weak self] context in
            DispatchQueue.main.async {
                self?.pendingKeychainContext = context
                self?.showingKeychainExplanation = true
            }
        }
    }

    /// Configure sync service with state binding
    private func setupSyncService() {
        Task {
            await syncService.setState(syncState)
        }

        // Observe sync state changes to refresh data
        syncState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleSyncStatusChange(status)
            }
            .store(in: &cancellables)
    }

    private func setupLearningObservers() {
        learningQueue.$pendingLearnings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] learnings in
                guard let self else { return }
                guard self.hasCompletedOnboarding else {
                    self.pendingLearningsCount = 0
                    self.conversationIdsWithLearnings = []
                    self.conversationLearningCounts = [:]
                    return
                }
                self.pendingLearningsCount = learnings.count
                self.conversationIdsWithLearnings = Set(learnings.map { $0.conversationId })
                self.conversationLearningCounts = Dictionary(
                    grouping: learnings,
                    by: { $0.conversationId }
                ).mapValues { $0.count }
            }
            .store(in: &cancellables)
    }

    /// Setup auto-sync timer based on settings
    private func setupAutoSync() {
        // Cancel any existing timer
        autoSyncTask?.cancel()

        guard hasCompletedOnboarding else { return }
        guard autoSyncEnabled else { return }

        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                // Wait for the configured interval
                let interval = UInt64(self.autoSyncInterval) * 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)

                guard !Task.isCancelled else { break }

                // Only sync if not already syncing
                if !self.isSyncing {
                    await self.syncWebOnly()
                }
            }
        }
    }

    /// Restart auto-sync timer (call when settings change)
    func restartAutoSync() {
        setupAutoSync()
    }

    /// Update Ollama configuration (call when settings change)
    func updateOllamaConfiguration() {
        Task {
            let config = OllamaService.Configuration(
                endpoint: ollamaEndpoint,
                model: ollamaModel
            )
            await ollamaService.updateConfiguration(config)
        }
    }

    /// Update learning confidence threshold (call when settings change)
    func updateLearningConfidenceThreshold() {
        let threshold = Float(learningConfidenceThreshold)
        learningQueue.updateMinimumConfidence(threshold)
    }

    /// Update learning extraction mode (call when settings change)
    func updateLearningExtractionMode() {
        learningQueue.updateExtractionMode(learningExtractionMode)
    }

    func updateImplicitLearningPreference() {
        learningQueue.updateImplicitLearningsEnabled(includeImplicitLearnings)
    }

    /// Update Gemini configuration for both workflow and learning extraction
    func updateGeminiConfiguration() {
        // Workflow extraction
        workflowSignatureService.updateGeminiConfiguration(
            apiKey: geminiApiKey,
            model: geminiWorkflowModel,
            enabled: geminiWorkflowEnabled
        )

        // Learning extraction (uses same API key, same model, same enabled flag)
        learningQueue.updateGeminiConfiguration(
            apiKey: geminiApiKey,
            model: geminiWorkflowModel,
            enabled: geminiWorkflowEnabled
        )

        // LLM Orchestrator Gemini fallback (for CLI backend)
        if geminiWorkflowEnabled && !geminiApiKey.isEmpty {
            llmOrchestrator.configureGemini(apiKey: geminiApiKey, model: geminiWorkflowModel)
        } else {
            // Clear Gemini when disabled or key is empty
            llmOrchestrator.clearGemini()
        }
    }

    /// Set up observers for custom CLI path changes
    private func setupCLIPathObservers() {
        // Observe UserDefaults changes for custom CLI paths
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateCLIConfiguration()
            }
            .store(in: &cancellables)
    }

    /// Update CLI LLM service configuration with custom paths
    /// NOTE: Codex CLI is disabled for alpha (lacks hard no-tools flag for security)
    func updateCLIConfiguration() {
        let claudePath = UserDefaults.standard.string(forKey: "customClaudePath") ?? ""

        Task {
            await llmOrchestrator.cliService.updateConfig(
                CLILLMService.CLIConfig(
                    customClaudePath: claudePath.isEmpty ? nil : claudePath
                )
            )
            // Re-detect tools after config update
            await llmOrchestrator.refreshToolDetection()
        }
    }

    /// Update launch-at-login setting
    func updateLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Silently fail - this requires code signing and proper entitlements
            // which aren't available when running from command line builds
            print("Launch at login not available: \(error.localizedDescription)")
            // Reset the toggle since it won't work
            launchAtLogin = false
        }
    }

    private func handleSyncStatusChange(_ status: SyncStatus) {
        switch status {
        case .completed(let stats):
            // Refresh data after successful sync
            refreshData()
            lastSyncStats = stats
            showSyncCompleteToast = true

            // Track which providers were successfully synced
            for (provider, progress) in syncState.providerProgress {
                if case .completed = progress.phase {
                    syncedProviders.insert(provider)
                }
            }

            // Extract learnings if enabled
            if autoExtractLearnings {
                Task {
                    await extractLearningsAfterSync(updatedConversationIds: stats.updatedConversationIds)
                }
            } else {
                updateWorkflowSignaturesAfterSync(updatedConversationIds: stats.updatedConversationIds)
            }

            // Auto-index only updated conversations for semantic search (incremental)
            if semanticSearchEnabled && !stats.updatedConversationIds.isEmpty {
                Task {
                    try? await semanticSearch.indexConversations(ids: stats.updatedConversationIds)
                }
            }
        case .failed(let error):
            syncErrorMessage = error
            showSyncErrorBanner = true
        case .cancelled:
            // Refresh data with partial results
            refreshData()
        default:
            break
        }
    }

    /// Extract learnings from all conversations after sync
    private func extractLearningsAfterSync(updatedConversationIds: Set<UUID>) async {
        guard !updatedConversationIds.isEmpty else { return }

        // Fetch conversations on background thread to avoid blocking MainActor
        let conversations = await Task.detached { [repository] in
            updatedConversationIds.compactMap { try? repository.fetch(id: $0) }
        }.value

        for conversation in conversations {
            await learningQueue.scanConversation(conversation)
        }

        await learningQueue.loadPendingLearnings()
        pendingLearningsCount = learningQueue.pendingLearnings.count
        conversationIdsWithLearnings = Set(learningQueue.pendingLearnings.map { $0.conversationId })

        // Load pending analysis suggestions
        fetchPendingSuggestions()

        updateWorkflowSignaturesAfterSync(updatedConversationIds: updatedConversationIds)
    }

    private func updateWorkflowSignaturesAfterSync(updatedConversationIds: Set<UUID>) {
        guard !updatedConversationIds.isEmpty else { return }
        Task.detached { [workflowSignatureService] in
            await workflowSignatureService.scanConversations(ids: updatedConversationIds)
        }
    }

    /// Refresh conversation data from database
    private func refreshData() {
        guard hasCompletedOnboarding else {
            resetForOnboarding()
            return
        }

        // Fetch data on background thread to avoid blocking MainActor
        Task { [repository] in
            do {
                let (convos, stats) = try await Task.detached {
                    let convos = try repository.fetchAll()
                    let stats = try repository.countByProvider()
                    return (convos, stats)
                }.value

                conversations = convos
                applyCurrentFilter()
                providerStats = stats
            } catch {
                errorMessage = "Failed to refresh data: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Setup

    private func setupFileWatchers() {
        fileWatcher.stopAll()
        guard hasCompletedOnboarding else { return }

        let fileChangeHandler: (FileWatcher.FileEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                await self?.handleFileChange(event)
            }
        }

        // Watch Claude Code
        if claudeCodeEnabled {
            fileWatcher.watchClaudeCode(onChange: fileChangeHandler)
        }

        // Watch Codex
        if codexEnabled {
            fileWatcher.watchCodex(onChange: fileChangeHandler)
        }

        // Watch OpenCode
        if opencodeEnabled {
            fileWatcher.watchOpenCode(onChange: fileChangeHandler)
        }

        // Watch Gemini CLI
        if geminiCLIEnabled {
            fileWatcher.watchGeminiCLI(onChange: fileChangeHandler)
        }

        // Watch Copilot CLI
        if copilotEnabled {
            fileWatcher.watchCopilot(onChange: fileChangeHandler)
        }

        // Watch Cursor
        if cursorEnabled {
            fileWatcher.watchCursor(onChange: fileChangeHandler)
        }
    }

    private func loadInitialData() {
        guard hasCompletedOnboarding else {
            resetForOnboarding()
            return
        }

        // Load data on background thread to avoid blocking MainActor
        Task { [repository, learningRepository] in
            do {
                let result = try await Task.detached {
                    let convos = try repository.fetchAll()
                    let stats = try repository.countByProvider()
                    let pendingCount = try learningRepository.countPending()
                    let learnings = try learningRepository.fetchPending()
                    let learningIds = Set(learnings.map { $0.conversationId })
                    return (convos, stats, pendingCount, learningIds)
                }.value

                conversations = result.0
                filteredConversations = result.0
                providerStats = result.1
                pendingLearningsCount = result.2
                conversationIdsWithLearnings = result.3
                starredConversationIds = loadStarredIds()
                // Load pending analysis suggestions
                fetchPendingSuggestions()
            } catch {
                errorMessage = "Failed to load conversations: \(error.localizedDescription)"
            }
        }
    }

    private func setupSearchDebounce() {
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                Task { @MainActor in
                    await self?.performSearch(query)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - File Change Handling

    private func handleFileChange(_ event: FileWatcher.FileEvent) async {
        guard hasCompletedOnboarding else { return }
        guard event.type == .created || event.type == .modified else { return }

        let path = event.url.path
        guard path.contains(".claude/projects") || path.contains(".codex") else { return }
        if path.contains(".claude/projects"), !claudeCodeEnabled { return }
        if path.contains(".codex"), !codexEnabled { return }

        // Add to pending changes
        pendingFileChanges.insert(event.url)

        // If we've hit the limit, process immediately to prevent unbounded memory growth
        if pendingFileChanges.count >= maxPendingFileChanges {
            fileChangeDebounceTask?.cancel()
            let filesToSync = pendingFileChanges
            pendingFileChanges.removeAll()
            Task { [weak self] in
                await self?.syncFilesIncrementally(filesToSync)
            }
            return
        }

        // Cancel existing debounce task
        fileChangeDebounceTask?.cancel()

        // Start new debounce task (500ms delay)
        fileChangeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms

                guard let self = self else { return }

                // Grab pending files and clear
                let filesToSync = self.pendingFileChanges
                self.pendingFileChanges.removeAll()

                guard !filesToSync.isEmpty else { return }

                // Sync each file incrementally (background)
                await self.syncFilesIncrementally(filesToSync)

            } catch is CancellationError {
                // Debounce cancelled, new changes incoming
            } catch {
                // Ignore other errors
            }
        }
    }

    /// Sync files incrementally without blocking UI
    private func syncFilesIncrementally(_ files: Set<URL>) async {
        // Don't show full sync UI for incremental updates
        var updatedConversationIds = Set<UUID>()
        for file in files {
            let updatedIds = await syncService.syncFile(url: file)
            updatedConversationIds.formUnion(updatedIds)
        }

        // Refresh data after incremental sync
        refreshData()

        // Extract learnings for updated conversations only
        if autoExtractLearnings {
            await extractLearningsAfterSync(updatedConversationIds: updatedConversationIds)
        } else {
            updateWorkflowSignaturesAfterSync(updatedConversationIds: updatedConversationIds)
        }
    }

    // MARK: - Workflow Insights

    func refreshWorkflowInsights(fullScan: Bool = false) async {
        guard hasCompletedOnboarding else { return }
        let result = await Task.detached { [workflowSignatureService] in
            if fullScan {
                await workflowSignatureService.scanAllConversations()
            }
            let clusters = await workflowSignatureService.fetchTopClusters(limit: 10)
            let priming = await workflowSignatureService.fetchPrimingClusters(limit: 10)
            return (clusters, priming)
        }.value

        workflowClusters = result.0
        workflowPrimingClusters = result.1
    }

    func resetWorkflowInsights() async {
        guard hasCompletedOnboarding else { return }
        let result = await Task.detached { [workflowSignatureService] in
            await workflowSignatureService.resetAndScanAllConversations()
            let clusters = await workflowSignatureService.fetchTopClusters(limit: 10)
            let priming = await workflowSignatureService.fetchPrimingClusters(limit: 10)
            return (clusters, priming)
        }.value

        workflowClusters = result.0
        workflowPrimingClusters = result.1
    }

    func clearWorkflowSignatures() async {
        guard hasCompletedOnboarding else { return }
        await Task.detached { [workflowSignatureService] in
            await workflowSignatureService.clearAllSignatures()
        }.value
        workflowClusters = []
        workflowPrimingClusters = []
    }

    /// Run a full CLI-powered scan and refresh UI data.
    func runFullCLIScan(types: [AnalysisType], scope: ScanScope, batchSize: Int = 10) async {
        guard hasCompletedOnboarding else { return }
        do {
            try await llmOrchestrator.runFullScan(types: types, batchSize: batchSize, requireCLI: true, scope: scope)
            if types.contains(.learning) {
                await learningQueue.loadPendingLearnings()
                await learningQueue.loadApprovedLearnings()
            }
            if types.contains(.workflow) {
                await refreshWorkflowInsights(fullScan: false)
            }
        } catch {
            errorMessage = "CLI scan failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Sync Operations

    /// Sync all data sources (non-blocking, runs in background)
    /// Uses unified SyncService to coordinate local + web sync
    func syncAll(localProviders: Set<Provider>? = nil, webProviders: Set<Provider>? = nil) async {
        guard hasCompletedOnboarding else { return }

        // If sync is already running and specific providers are requested,
        // queue them to be synced after the current sync completes
        if isSyncing {
            if let providers = localProviders {
                pendingSyncProviders.formUnion(providers)
                #if DEBUG
                print("🟡 Sync in progress, queued providers: \(providers.map { $0.displayName })")
                #endif
            }
            return
        }

        // Reset UI state
        showSyncCompleteToast = false
        showSyncErrorBanner = false
        syncState.reset()
        syncState.setStatus(.syncing)

        let allowedLocalProviders = localProviders ?? enabledLocalProviders
        let targetWebProviders: Set<Provider> = {
            if let webProviders {
                return webProviders
            }
            var providers = Set<Provider>()
            if webSyncEngine.claudeConnectionStatus.isConnected {
                providers.insert(.claudeWeb)
            }
            if webSyncEngine.chatgptConnectionStatus.isConnected {
                providers.insert(.chatgptWeb)
            }
            return providers
        }()

        // Pre-seed web providers so the UI shows they are queued for sync.
        if !targetWebProviders.isEmpty {
            let webWeight: Double = {
                if let webProviders {
                    return webProviders.isEmpty ? 0.1 : (1.0 / Double(webProviders.count))
                }
                return 0.1
            }()
            for provider in targetWebProviders {
                syncState.updateProviderProgress(provider, progress: .discovering(weight: webWeight))
            }
        }

        // Capture web sync engine for closure (to avoid capturing self strongly)
        let webEngine = webSyncEngine
        let state = syncState

        // Start background sync task - use Task.detached to avoid MainActor inheritance
        // This ensures sync work doesn't block the UI
        syncTask = Task.detached { [syncService] in
            do {
                // Unified sync: local + web sources
                // Pass web sync closure so SyncService coordinates everything
                // and only sets .completed when ALL sources finish
                _ = try await syncService.syncAllWithWeb(
                    webSync: { [webEngine, state] in
                        try await Self.performWebSync(webEngine: webEngine, syncState: state, providers: webProviders)
                    },
                    localProviders: allowedLocalProviders
                )
            } catch is CancellationError {
                // User cancelled - state already updated by SyncService
            } catch {
                // Error handled by SyncService state updates
            }
        }

        // Wait for sync to complete, then process any pending providers
        Task { [weak self] in
            await self?.syncTask?.value
            await self?.processPendingSyncProviders()
        }
    }

    /// Process any pending sync providers that were queued during an active sync
    private func processPendingSyncProviders() async {
        guard !pendingSyncProviders.isEmpty else { return }
        let providers = pendingSyncProviders
        pendingSyncProviders.removeAll()
        #if DEBUG
        print("🟢 Processing queued providers: \(providers.map { $0.displayName })")
        #endif
        await syncAll(localProviders: providers)
    }

    /// Force full sync by clearing cache first, then syncing all sources
    /// Use this when user wants to resync everything regardless of modification dates
    func forceFullSync() async {
        guard hasCompletedOnboarding else { return }

        // Clear the file modification cache so all files are processed
        await syncService.clearFileModificationCache()

        // Now perform a normal sync (all files will be processed)
        await syncAll()
    }

    /// Sync web sources (Claude.ai, ChatGPT) - returns stats
    /// This is called by SyncService as part of the unified sync
    private static func performWebSync(webEngine: WebSyncEngine, syncState: SyncState) async throws -> SyncStats {
        try await performWebSync(webEngine: webEngine, syncState: syncState, providers: nil)
    }

    private static func performWebSync(
        webEngine: WebSyncEngine,
        syncState: SyncState,
        providers: Set<Provider>?
    ) async throws -> SyncStats {
        var stats = SyncStats()
        try Task.checkCancellation()

        // Check connection status on MainActor
        let claudeConnected = await MainActor.run { webEngine.claudeConnectionStatus.isConnected }
        let chatgptConnected = await MainActor.run { webEngine.chatgptConnectionStatus.isConnected }
        #if DEBUG
        print("🟢 AppState: web sync providers=\(providers?.map { $0.rawValue } ?? []) claudeConnected=\(claudeConnected) chatgptConnected=\(chatgptConnected)")
        #endif

        // Sync Claude.ai if connected
        let shouldSyncClaude = providers?.contains(.claudeWeb) ?? claudeConnected
        let shouldSyncChatGPT = providers?.contains(.chatgptWeb) ?? chatgptConnected
        let providerWeight: Double = {
            if let providers {
                return providers.isEmpty ? 1.0 : (1.0 / Double(providers.count))
            }
            return 0.1
        }()

        // Sync web sources in parallel
        async let claudeResult: SyncStats? = {
            guard shouldSyncClaude else { return nil }
            guard claudeConnected else {
                await MainActor.run {
                    syncState.setError("Not connected", for: .claudeWeb)
                    syncState.updateProviderProgress(.claudeWeb, progress: ProviderSyncProgress(
                        phase: .failed("Not connected"),
                        progress: 1.0,
                        weight: providerWeight
                    ))
                }
                return nil
            }
            await MainActor.run {
                syncState.updateProviderProgress(.claudeWeb, progress: .discovering(weight: providerWeight))
            }
            do {
                let webStats = try await webEngine.syncClaude()
                await MainActor.run {
                    syncState.updateProviderProgress(.claudeWeb, progress: ProviderSyncProgress(
                        phase: .completed,
                        progress: 1.0,
                        weight: providerWeight
                    ))
                }
                return webStats
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await MainActor.run {
                    syncState.setError(error.localizedDescription, for: .claudeWeb)
                    syncState.updateProviderProgress(.claudeWeb, progress: ProviderSyncProgress(
                        phase: .failed(error.localizedDescription),
                        progress: 1.0,
                        weight: providerWeight
                    ))
                }
                return nil
            }
        }()

        async let chatgptResult: SyncStats? = {
            guard shouldSyncChatGPT else { return nil }
            guard chatgptConnected else {
                await MainActor.run {
                    syncState.setError("Not connected", for: .chatgptWeb)
                    syncState.updateProviderProgress(.chatgptWeb, progress: ProviderSyncProgress(
                        phase: .failed("Not connected"),
                        progress: 1.0,
                        weight: providerWeight
                    ))
                }
                return nil
            }
            await MainActor.run {
                syncState.updateProviderProgress(.chatgptWeb, progress: .discovering(weight: providerWeight))
            }
            do {
                let webStats = try await webEngine.syncChatGPT()
                await MainActor.run {
                    syncState.updateProviderProgress(.chatgptWeb, progress: ProviderSyncProgress(
                        phase: .completed,
                        progress: 1.0,
                        weight: providerWeight
                    ))
                }
                return webStats
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                #if DEBUG
                print("🟢 AppState: ChatGPT sync failed: \(error.localizedDescription)")
                #endif
                await MainActor.run {
                    syncState.setError(error.localizedDescription, for: .chatgptWeb)
                    syncState.updateProviderProgress(.chatgptWeb, progress: ProviderSyncProgress(
                        phase: .failed(error.localizedDescription),
                        progress: 1.0,
                        weight: providerWeight
                    ))
                }
                return nil
            }
        }()

        // Await both web sources together and merge stats
        let (claudeStats, chatgptStats) = try await (claudeResult, chatgptResult)

        if let cs = claudeStats {
            stats.providersCompleted += 1
            stats.conversationsUpdated += cs.conversationsUpdated
            stats.messagesUpdated += cs.messagesUpdated
            stats.errors += cs.errors
            stats.updatedConversationIds.formUnion(cs.updatedConversationIds)
        } else if shouldSyncClaude && claudeConnected {
            stats.errors += 1
        } else if shouldSyncClaude && !claudeConnected {
            stats.errors += 1
        }

        if let gs = chatgptStats {
            stats.providersCompleted += 1
            stats.conversationsUpdated += gs.conversationsUpdated
            stats.messagesUpdated += gs.messagesUpdated
            stats.errors += gs.errors
            stats.updatedConversationIds.formUnion(gs.updatedConversationIds)
        } else if shouldSyncChatGPT && chatgptConnected {
            stats.errors += 1
        } else if shouldSyncChatGPT && !chatgptConnected {
            stats.errors += 1
        }

        return stats
    }

    /// Sync only connected web providers (no local sources)
    func syncWebOnly(providers: Set<Provider>? = nil, force: Bool = false) async {
        guard hasCompletedOnboarding else { return }
        #if DEBUG
        print("🟢 AppState: syncWebOnly requested providers=\(providers?.map { $0.rawValue } ?? []) isSyncing=\(isSyncing) force=\(force)")
        #endif

        // Check if any of the requested providers are already syncing
        let requestedProviders = providers ?? [.claudeWeb, .chatgptWeb]
        let alreadySyncing = requestedProviders.filter { webSyncEngine.isSyncing(provider: $0) }

        if !alreadySyncing.isEmpty {
            // Some requested providers are already syncing
            if !force {
                // Non-forced request while already syncing - skip
                return
            }
            // Force=true but only cancel if ALL requested providers are already syncing
            // (otherwise let the new ones sync while existing ones continue)
            if alreadySyncing.count == requestedProviders.count {
                // All requested providers already syncing - nothing to do
                return
            }
        }

        // Don't reset state if a full sync (syncAll) is already running
        // This prevents wiping progress of local providers during concurrent syncs
        let isFullSyncRunning = syncTask != nil && syncTask?.isCancelled == false && syncState.isSyncing
        if isFullSyncRunning {
            // A full sync is in progress - don't interfere
            // The web providers will be synced as part of the full sync
            #if DEBUG
            print("🟡 AppState: syncWebOnly skipped - full sync already running")
            #endif
            return
        }

        showSyncCompleteToast = false
        showSyncErrorBanner = false
        syncState.reset()
        syncState.setStatus(.syncing)

        let webEngine = webSyncEngine
        let state = syncState
        syncTask = Task.detached {
            do {
                let stats = try await Self.performWebSync(
                    webEngine: webEngine,
                    syncState: state,
                    providers: providers
                )
                try Task.checkCancellation()
                await MainActor.run {
                    state.setStatus(.completed(stats))
                }
            } catch is CancellationError {
                await MainActor.run {
                    state.setStatus(.cancelled)
                }
            } catch {
                await MainActor.run {
                    state.setStatus(.failed(error.localizedDescription))
                }
            }
        }
    }

    func syncWeb(provider: Provider) async {
        guard hasCompletedOnboarding else { return }
        #if DEBUG
        print("🟢 AppState: syncWeb provider=\(provider.rawValue)")
        #endif
        await syncWebOnly(providers: [provider], force: true)
    }

    // MARK: - Onboarding

    func completeOnboarding() {
        hasCompletedOnboarding = true
        activateAfterOnboarding(triggerInitialSync: true)
    }

    func enterOnboarding() {
        if hasCompletedOnboarding {
            hasCompletedOnboarding = false
        }
        resetForOnboarding()
    }

    private func activateAfterOnboarding(triggerInitialSync: Bool) {
        // Now safe to access keychain (user has completed onboarding)

        // FIRST: Clean up any legacy items from login keychain (one-time)
        // This removes old keychain items that could trigger authorization prompts
        KeychainHelper.cleanupLoginKeychain()

        // Migration is disabled - cleanup is used instead
        KeychainHelper.migrateFromLoginKeychain()

        // Enable keychain persistence for web sessions first (persist any cookies stored during onboarding)
        webSyncEngine.enableKeychainPersistence()

        KeychainHelper.migrateFromUserDefaults()
        geminiApiKey = KeychainHelper.geminiApiKey ?? ""

        // Initialize web sync engine and check for existing sessions
        _ = webSyncEngine
        observeWebSyncChanges()

        // Check for existing web sessions (safe now since onboarding is complete)
        Task {
            await webSyncEngine.checkExistingSessionsIfNeeded()
        }

        loadInitialData()
        setupFileWatchers()
        setupAutoSync()

        guard triggerInitialSync else { return }
        Task {
            await syncAll()
        }
    }

    private func resetForOnboarding() {
        fileWatcher.stopAll()
        autoSyncTask?.cancel()
        syncState.reset()
        conversations = []
        filteredConversations = []
        providerStats = [:]
        selectedConversation = nil
        selectedMessages = []
        pendingLearningsCount = 0
        conversationIdsWithLearnings = []
        conversationLearningCounts = [:]
        starredConversationIds = []
        workflowClusters = []
        workflowPrimingClusters = []
        showSyncCompleteToast = false
        showSyncErrorBanner = false
    }

    // MARK: - Reset

    /// Fully reset app state and return to onboarding.
    func resetAppState() async {
        cancelSync()
        await waitForSyncCompletion()

        fileWatcher.stopAll()
        autoSyncTask?.cancel()

        webSyncEngine.disconnect(provider: .claudeWeb)
        webSyncEngine.disconnect(provider: .chatgptWeb)
        webSyncEngine.error = nil

        do {
            try AppDatabase.shared.resetAllData()
        } catch {
            errorMessage = "Failed to reset database: \(error.localizedDescription)"
        }

        // Clear file modification cache so next sync processes all files
        await syncService.clearFileModificationCache()

        UserDefaults.standard.removeObject(forKey: "starredConversationIds")

        try? semanticSearch.clearAllEmbeddings()

        searchQuery = ""
        searchResults = []
        errorMessage = nil
        lastSyncStats = nil
        syncState.lastSyncDate = nil
        activeView = .conversationList
        sidebarSelection = nil
        activeFilter = nil

        hasCompletedOnboarding = false
        resetForOnboarding()

        await learningQueue.loadPendingLearnings()
        await learningQueue.loadApprovedLearnings()
    }

    private var enabledLocalProviders: Set<Provider> {
        var providers = Set<Provider>()
        if claudeCodeEnabled { providers.insert(.claudeCode) }
        if codexEnabled { providers.insert(.codex) }
        if opencodeEnabled { providers.insert(.opencode) }
        if geminiCLIEnabled { providers.insert(.geminiCLI) }
        if copilotEnabled { providers.insert(.copilot) }
        if cursorEnabled { providers.insert(.cursor) }
        return providers
    }

    func updateLocalSourceConfiguration() {
        guard hasCompletedOnboarding else { return }
        setupFileWatchers()
    }

    /// Cancel the current sync operation
    func cancelSync() {
        syncTask?.cancel()
        Task {
            await syncService.cancel()
        }
    }

    private func waitForSyncCompletion(timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isSyncing && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Filtering

    /// Filter by smart folder
    func filterBy(smartFolder: SmartFolder) {
        activeFilter = smartFolder.rawValue
        selectedFilterProvider = nil

        switch smartFolder {
        case .today:
            filteredConversations = conversations.filter {
                Calendar.current.isDateInToday($0.updatedAt)
            }
        case .thisWeek:
            filteredConversations = conversations.filter {
                Calendar.current.isDate($0.updatedAt, equalTo: Date(), toGranularity: .weekOfYear)
            }
        case .withLearnings:
            filteredConversations = conversationsWithLearnings
        }
        reconcileSelection()
    }

    /// Filter by provider
    func filterBy(provider: Provider) {
        activeFilter = provider.displayName
        selectedFilterProvider = provider
        filteredConversations = conversations.filter { $0.provider == provider }
        reconcileSelection()
    }

    /// Clear filter
    func clearFilter() {
        activeFilter = nil
        selectedFilterProvider = nil
        filteredConversations = conversations
        reconcileSelection()
    }

    /// Reapply current filter after data refresh
    private func applyCurrentFilter() {
        guard let filter = activeFilter else {
            filteredConversations = conversations
            reconcileSelection()
            return
        }

        // Try to match to a smart folder
        if let folder = SmartFolder.allCases.first(where: { $0.rawValue == filter }) {
            filterBy(smartFolder: folder)
            return
        }

        // Try to match to a provider
        if let provider = Provider.allCases.first(where: { $0.displayName == filter }) {
            filterBy(provider: provider)
            return
        }

        // No match, show all
        filteredConversations = conversations
        reconcileSelection()
    }

    private func reconcileSelection() {
        guard let selected = selectedConversation else { return }
        let stillVisible = filteredConversations.contains(where: { $0.id == selected.id })
        if !stillVisible {
            clearSelection()
        }
    }

    // MARK: - Selection

    /// Select a conversation and load its messages
    func select(_ conversation: Conversation) {
        #if DEBUG
        NSLog("🔍 select() called for: %@ - %@", conversation.id.uuidString, conversation.title ?? "untitled")
        #endif

        // Only update if different (avoids NSTableView reentrant operation warning)
        if selectedConversation?.id != conversation.id {
            selectedConversation = conversation
            selectedMessages = []  // Clear old messages immediately
            #if DEBUG
            NSLog("   → Updated selectedConversation, cleared old messages")
            #endif
        }

        // Fetch messages on background thread to avoid blocking MainActor
        let conversationId = conversation.id
        isLoadingMessages = true

        Task { [repository] in
            do {
                let messages = try await Task.detached {
                    try repository.fetchMessages(conversationId: conversationId)
                }.value
                #if DEBUG
                NSLog("   → Fetched %d messages for %@", messages.count, conversationId.uuidString)
                #endif

                // Verify we're still on the same conversation
                guard selectedConversation?.id == conversationId else {
                    #if DEBUG
                    NSLog("   → Conversation changed, discarding %d messages", messages.count)
                    #endif
                    isLoadingMessages = false
                    return
                }
                selectedMessages = messages
                isLoadingMessages = false
                #if DEBUG
                NSLog("   → Set selectedMessages to %d items", messages.count)
                #endif
            } catch {
                #if DEBUG
                NSLog("   → ERROR fetching messages: %@", error.localizedDescription)
                #endif
                errorMessage = "Failed to load messages: \(error.localizedDescription)"
                isLoadingMessages = false
            }
        }
    }

    /// Open a conversation associated with a learning
    func openConversation(for learning: Learning) {
        activeView = .conversationList
        sidebarSelection = nil
        clearFilter()

        if let existing = conversations.first(where: { $0.id == learning.conversationId }) {
            select(existing)
            return
        }

        let targetId = learning.conversationId
        Task { [repository] in
            guard let convo = try? await Task.detached(priority: nil, operation: {
                try repository.fetch(id: targetId)
            }).value else { return }
            select(convo)
        }
    }

    /// Clear selection
    func clearSelection() {
        selectedConversation = nil
        selectedMessages = []
    }

    // MARK: - Starring

    /// Toggle star status for a conversation
    func toggleStar(_ conversation: Conversation) {
        if starredConversationIds.contains(conversation.id) {
            starredConversationIds.remove(conversation.id)
        } else {
            starredConversationIds.insert(conversation.id)
        }
        saveStarredIds()
    }

    /// Check if a conversation is starred
    func isStarred(_ conversation: Conversation) -> Bool {
        starredConversationIds.contains(conversation.id)
    }

    /// Load starred IDs from UserDefaults
    private func loadStarredIds() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: "starredConversationIds"),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    /// Save starred IDs to UserDefaults
    private func saveStarredIds() {
        let ids = Array(starredConversationIds)
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: "starredConversationIds")
        }
    }

    // MARK: - Learnings

    /// Check if a conversation has learnings
    func hasLearnings(_ conversation: Conversation) -> Bool {
        conversationIdsWithLearnings.contains(conversation.id)
    }

    private func countPendingLearnings() throws -> Int {
        try learningRepository.countPending()
    }

    private func loadConversationIdsWithLearnings() throws -> Set<UUID> {
        let learnings = try learningRepository.fetchPending()
        return Set(learnings.map { $0.conversationId })
    }

    // MARK: - Analysis Suggestions

    /// Fetch pending suggestions from the database
    func fetchPendingSuggestions() {
        do {
            pendingSuggestions = try analysisResultProcessor.fetchPendingSuggestions()
        } catch {
            #if DEBUG
            print("Failed to fetch pending suggestions: \(error)")
            #endif
            pendingSuggestions = []
        }
    }

    /// Approve a suggestion (applies changes and updates status atomically)
    func approveSuggestion(_ suggestion: AnalysisSuggestion) async {
        do {
            try analysisResultProcessor.applyAndApproveSuggestion(suggestion)
            fetchPendingSuggestions()
            // Refresh conversations if title/summary changed
            if suggestion.suggestionType == "title" || suggestion.suggestionType == "summary" {
                refreshData()
            }
        } catch {
            #if DEBUG
            print("Failed to approve suggestion: \(error)")
            #endif
            errorMessage = "Failed to apply suggestion: \(error.localizedDescription)"
        }
    }

    /// Reject a suggestion (status update only)
    func rejectSuggestion(_ suggestion: AnalysisSuggestion, reason: String? = nil) {
        do {
            try analysisResultProcessor.rejectSuggestion(suggestion, reason: reason)
            fetchPendingSuggestions()
        } catch {
            #if DEBUG
            print("Failed to reject suggestion: \(error)")
            #endif
            errorMessage = "Failed to reject suggestion: \(error.localizedDescription)"
        }
    }

    // MARK: - Search

    /// Focus the search field
    func focusSearch(messagesOnly: Bool = false) {
        searchMessagesOnly = messagesOnly
        shouldFocusSearch = true
    }

    /// Perform search
    private func performSearch(_ query: String) async {
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        do {
            if semanticSearchEnabled {
                let results = try await semanticSearch.search(query: query, messagesOnly: searchMessagesOnly)
                searchResults = results.map { result in
                    SearchResult(
                        conversation: result.conversation,
                        message: result.message,
                        matchedText: result.matchedText
                    )
                }
            } else {
                var results: [SearchResult] = []

                // Search messages
                let messageResults = try repository.searchMessages(query: query)
                for (message, conversation) in messageResults {
                    results.append(SearchResult(
                        conversation: conversation,
                        message: message,
                        matchedText: message.preview(maxLength: 150)
                    ))
                }

                // Search conversation titles (if not messages-only)
                if !searchMessagesOnly {
                    let convResults = try repository.searchConversations(query: query)
                    for conversation in convResults {
                        if !results.contains(where: { $0.conversation.id == conversation.id }) {
                            results.append(SearchResult(
                                conversation: conversation,
                                message: nil,
                                matchedText: conversation.title ?? ""
                            ))
                        }
                    }
                }

                searchResults = results
            }

            updateSelectionForSearchResults()

        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    private func updateSelectionForSearchResults() {
        guard !searchQuery.isEmpty else { return }

        let allowedIds: Set<UUID>? = activeFilter == nil
            ? nil
            : Set(filteredConversations.map { $0.id })
        let visibleIds: Set<UUID> = Set(searchResults.compactMap { result in
            if let allowedIds, !allowedIds.contains(result.conversation.id) {
                return nil
            }
            return result.conversation.id
        })

        if let selectedId = selectedConversation?.id {
            if !visibleIds.contains(selectedId) {
                clearSelection()
            }
        } else if visibleIds.isEmpty {
            clearSelection()
        }
    }

    // MARK: - Delete

    /// Delete a conversation
    func delete(_ conversation: Conversation) {
        do {
            // Soft-delete the conversation
            try repository.delete(id: conversation.id)

            // Update local state
            conversations.removeAll { $0.id == conversation.id }
            filteredConversations.removeAll { $0.id == conversation.id }
            starredConversationIds.remove(conversation.id)
            if selectedConversation?.id == conversation.id {
                clearSelection()
            }

            // Show undo toast
            recentlyDeletedConversation = conversation
            showUndoDeleteToast = true

            // Auto-dismiss toast after 5 seconds
            undoToastDismissTask?.cancel()
            undoToastDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
                guard !Task.isCancelled else { return }
                dismissUndoToast()
            }
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    /// Undo the most recent conversation deletion
    func undoDelete() {
        guard let conversation = recentlyDeletedConversation else { return }

        do {
            // Restore the conversation
            try repository.restore(id: conversation.id)

            // Re-add to local state
            conversations.append(conversation)
            conversations.sort { $0.updatedAt > $1.updatedAt }
            applyCurrentFilter()

            // Clear undo state
            dismissUndoToast()
        } catch {
            errorMessage = "Failed to restore: \(error.localizedDescription)"
        }
    }

    /// Dismiss the undo toast without restoring
    func dismissUndoToast() {
        undoToastDismissTask?.cancel()
        undoToastDismissTask = nil
        showUndoDeleteToast = false
        recentlyDeletedConversation = nil
    }
}
