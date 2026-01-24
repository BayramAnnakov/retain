import Foundation
import Combine

// MARK: - Sync State

/// Observable sync state for UI binding
@MainActor
final class SyncState: ObservableObject {
    /// Overall sync status
    @Published private(set) var status: SyncStatus = .idle

    /// Progress for each provider (0.0 - 1.0)
    @Published private(set) var providerProgress: [Provider: ProviderSyncProgress] = [:]

    /// Overall progress (0.0 - 1.0)
    @Published private(set) var overallProgress: Double = 0.0

    /// Current status message
    @Published private(set) var statusMessage: String = ""

    /// Errors encountered during sync
    @Published private(set) var errors: [Provider: String] = [:]

    /// Last successful sync date
    @Published var lastSyncDate: Date?

    /// Convenience computed properties
    var isSyncing: Bool {
        if case .syncing = status { return true }
        return false
    }

    var canCancel: Bool {
        isSyncing
    }

    // MARK: - State Updates (called from SyncService)

    func setStatus(_ status: SyncStatus) {
        self.status = status
        switch status {
        case .idle:
            statusMessage = ""
        case .syncing:
            statusMessage = "Starting sync..."
        case .completed(let stats):
            statusMessage = "Synced \(stats.conversationsUpdated) conversations"
            lastSyncDate = Date()
        case .cancelled:
            statusMessage = "Sync cancelled"
        case .failed(let error):
            statusMessage = "Sync failed: \(error)"
        }
    }

    func updateProviderProgress(_ provider: Provider, progress: ProviderSyncProgress) {
        providerProgress[provider] = progress
        recalculateOverallProgress()
        updateStatusMessage(for: provider, progress: progress)
    }

    func setError(_ error: String, for provider: Provider) {
        errors[provider] = error
    }

    func reset() {
        status = .idle
        providerProgress = [:]
        overallProgress = 0.0
        statusMessage = ""
        errors = [:]
    }

    private func recalculateOverallProgress() {
        guard !providerProgress.isEmpty else {
            overallProgress = 0.0
            return
        }

        let totalWeight = providerProgress.values.reduce(0.0) { $0 + $1.weight }
        let weightedProgress = providerProgress.values.reduce(0.0) {
            $0 + ($1.progress * $1.weight)
        }

        overallProgress = totalWeight > 0 ? weightedProgress / totalWeight : 0.0
    }

    private func updateStatusMessage(for provider: Provider, progress: ProviderSyncProgress) {
        switch progress.phase {
        case .discovering:
            let noun = provider.isWebProvider ? "conversations" : "files"
            statusMessage = "Discovering \(provider.displayName) \(noun)..."
        case .parsing(let current, let total):
            statusMessage = "Parsing \(provider.displayName): \(current)/\(total)"
        case .saving:
            statusMessage = "Saving \(provider.displayName) data..."
        case .completed:
            if providerProgress.values.allSatisfy({ $0.phase == .completed }) {
                statusMessage = "Sync complete"
            }
        case .failed:
            statusMessage = "Error syncing \(provider.displayName)"
        }
    }
}

// MARK: - Sync Status Enum

enum SyncStatus: Equatable {
    case idle
    case syncing
    case completed(SyncStats)
    case cancelled
    case failed(String)

    static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.syncing, .syncing), (.cancelled, .cancelled):
            return true
        case (.completed(let l), .completed(let r)):
            return l == r
        case (.failed(let l), .failed(let r)):
            return l == r
        default:
            return false
        }
    }
}

// MARK: - Sync Stats

struct SyncStats: Equatable {
    var conversationsUpdated: Int = 0
    var messagesUpdated: Int = 0
    var providersCompleted: Int = 0
    var errors: Int = 0
    var filesSkipped: Int = 0  // Files skipped due to no changes
    var updatedConversationIds: Set<UUID> = []
    var failedConversationIds: [Provider: [String]] = [:]

    /// Total failed conversation count across all providers
    var totalFailedConversations: Int {
        failedConversationIds.values.reduce(0) { $0 + $1.count }
    }

    /// Summary message for sync results
    var summaryMessage: String {
        var parts: [String] = []
        if conversationsUpdated > 0 {
            parts.append("\(conversationsUpdated) updated")
        }
        if filesSkipped > 0 {
            parts.append("\(filesSkipped) unchanged")
        }
        let failed = totalFailedConversations
        if failed > 0 {
            parts.append("\(failed) failed")
        }
        if errors > 0 && failed == 0 {
            parts.append("\(errors) errors")
        }
        if parts.isEmpty {
            return "No changes"
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Provider Sync Progress

struct ProviderSyncProgress: Equatable {
    var phase: SyncPhase
    var progress: Double  // 0.0 - 1.0
    var weight: Double    // Relative weight for overall progress calculation
    var itemsProcessed: Int = 0
    var totalItems: Int = 0

    enum SyncPhase: Equatable {
        case discovering
        case parsing(current: Int, total: Int)
        case saving
        case completed
        case failed(String)
    }

    static func discovering(weight: Double) -> ProviderSyncProgress {
        ProviderSyncProgress(phase: .discovering, progress: 0.0, weight: weight)
    }
}

// MARK: - Sync Service Actor

/// Background sync service that performs all I/O off the main thread
actor SyncService {
    private let claudeCodeParser = ClaudeCodeParser()
    private let codexParser = CodexParser()
    private let repository: ConversationRepository

    /// Weak reference to avoid retain cycles
    private weak var state: SyncState?

    /// Current sync task for cancellation
    private var currentTask: Task<SyncStats, Error>?

    // MARK: - File Modification Tracking

    /// UserDefaults key for file modification dates
    private static let fileModDatesKey = "Retain.SyncService.fileModificationDates"
    /// UserDefaults key for Claude Code parser version (force resync on format changes)
    private static let claudeCodeParserVersionKey = "Retain.SyncService.claudeCodeParserVersion"
    private static let claudeCodeParserVersion = 3  // Bumped: strip XML metadata tags from titles/previews

    /// Cached file modification dates (path -> modification date)
    private var fileModificationDates: [String: Date]?

    /// Track skipped files for stats
    private var skippedFilesCount: Int = 0

    init(repository: ConversationRepository = ConversationRepository()) {
        self.repository = repository
        ensureClaudeCodeParserVersion()
    }

    /// Clear file modification cache when parser version changes (ensures tool calls get re-ingested)
    private func ensureClaudeCodeParserVersion() {
        let storedVersion = UserDefaults.standard.integer(forKey: Self.claudeCodeParserVersionKey)
        guard storedVersion != Self.claudeCodeParserVersion else { return }
        clearFileModificationCache()
        UserDefaults.standard.set(Self.claudeCodeParserVersion, forKey: Self.claudeCodeParserVersionKey)
    }

    /// Load persisted file modification dates from UserDefaults (lazy loading)
    private func getFileModificationDates() -> [String: Date] {
        if let dates = fileModificationDates {
            return dates
        }
        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: Self.fileModDatesKey),
           let dates = try? JSONDecoder().decode([String: Date].self, from: data) {
            fileModificationDates = dates
            return dates
        }
        fileModificationDates = [:]
        return [:]
    }

    /// Save file modification dates to UserDefaults
    private func saveFileModificationDates() {
        guard let dates = fileModificationDates else { return }
        if let data = try? JSONEncoder().encode(dates) {
            UserDefaults.standard.set(data, forKey: Self.fileModDatesKey)
        }
    }

    /// Check if a file needs syncing based on modification date
    private func fileNeedsSync(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attributes[.modificationDate] as? Date else {
            return true // If we can't get attributes, sync it
        }

        let dates = getFileModificationDates()
        let path = url.path
        if let lastSyncedDate = dates[path] {
            // File was synced before - check if modified since
            return modDate > lastSyncedDate
        }

        // Never synced - needs sync
        return true
    }

    /// Mark a file as synced with its current modification date
    private func markFileSynced(_ url: URL) {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            // Ensure we have loaded the dates first
            _ = getFileModificationDates()
            fileModificationDates?[url.path] = modDate
        }
    }

    /// Clear tracked file dates (useful for force refresh)
    func clearFileModificationCache() {
        fileModificationDates = [:]
        UserDefaults.standard.removeObject(forKey: Self.fileModDatesKey)
        clearCodexSessionModificationCache()
    }

    // MARK: - Codex Session Modification Tracking

    /// UserDefaults key for Codex session modification dates
    private static let codexSessionModDatesKey = "Retain.SyncService.codexSessionModificationDates"

    /// Cached Codex session file modification dates (path -> modification date)
    private var codexSessionModDates: [String: Date]?

    /// Load persisted Codex session modification dates from UserDefaults (lazy loading)
    private func getCodexSessionModDates() -> [String: Date] {
        if let dates = codexSessionModDates {
            return dates
        }
        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: Self.codexSessionModDatesKey),
           let dates = try? JSONDecoder().decode([String: Date].self, from: data) {
            codexSessionModDates = dates
            return dates
        }
        codexSessionModDates = [:]
        return [:]
    }

    /// Save Codex session modification dates to UserDefaults
    private func saveCodexSessionModDates() {
        guard let dates = codexSessionModDates else { return }
        if let data = try? JSONEncoder().encode(dates) {
            UserDefaults.standard.set(data, forKey: Self.codexSessionModDatesKey)
        }
    }

    /// Check if a Codex session file needs syncing based on modification date
    private func codexSessionNeedsSync(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attributes[.modificationDate] as? Date else {
            return true // If we can't get attributes, sync it
        }

        let dates = getCodexSessionModDates()
        let path = url.path
        if let lastSyncedDate = dates[path] {
            // File was synced before - check if modified since
            return modDate > lastSyncedDate
        }

        // Never synced - needs sync
        return true
    }

    /// Mark a Codex session file as synced with its current modification date
    private func markCodexSessionSynced(_ url: URL) {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attributes[.modificationDate] as? Date {
            // Ensure we have loaded the dates first
            _ = getCodexSessionModDates()
            codexSessionModDates?[url.path] = modDate
        }
    }

    /// Clear Codex session modification cache
    private func clearCodexSessionModificationCache() {
        codexSessionModDates = [:]
        UserDefaults.standard.removeObject(forKey: Self.codexSessionModDatesKey)
    }

    /// Invalidate cache for deleted Codex sessions (call on full sync)
    private func invalidateDeletedCodexSessions() {
        let dates = getCodexSessionModDates()
        let validPaths = dates.keys.filter { FileManager.default.fileExists(atPath: $0) }
        codexSessionModDates = dates.filter { validPaths.contains($0.key) }
        saveCodexSessionModDates()
    }

    /// Set the state object (must be called from MainActor)
    func setState(_ state: SyncState) {
        self.state = state
    }

    /// Perform full sync of local sources only
    /// Returns stats on completion, throws on failure
    func syncAll(localProviders: Set<Provider>? = nil) async throws -> SyncStats {
        try await syncAllWithWeb(webSync: nil, localProviders: localProviders)
    }

    /// Perform full sync of all sources (local + optional web)
    /// The webSync closure is called to sync web sources (claude.ai, chatgpt)
    /// Returns stats on completion, throws on failure
    ///
    /// Uses ProviderRegistry for dynamic provider support
    func syncAllWithWeb(
        webSync: (() async throws -> SyncStats)?,
        localProviders: Set<Provider>? = nil
    ) async throws -> SyncStats {
        // Cancel any existing sync
        currentTask?.cancel()

        let task = Task { () -> SyncStats in
            var stats = SyncStats()

            await updateStatus(.syncing)

            do {
                try Task.checkCancellation()
                let allowedLocalProviders = localProviders

                // Get enabled CLI providers from registry
                let enabledCLIProviders = ProviderRegistry.cliProviders.filter { config in
                    // If localProviders is specified, use it as a filter
                    // Otherwise, sync all supported CLI providers
                    allowedLocalProviders?.contains(config.provider) ?? config.isSupported
                }

                // Build sync tasks dynamically from registry
                var cliSyncTasks: [Provider: Task<SyncStats?, Error>] = [:]

                for config in enabledCLIProviders {
                    let provider = config.provider
                    cliSyncTasks[provider] = Task {
                        try await self.syncProvider(provider)
                    }
                }

                // Run web sync in parallel
                async let webStatsTask: SyncStats? = webSync != nil ? try await webSync!() : nil

                // Await all CLI provider tasks
                for (provider, task) in cliSyncTasks {
                    do {
                        if let providerStats = try await task.value {
                            stats.conversationsUpdated += providerStats.conversationsUpdated
                            stats.messagesUpdated += providerStats.messagesUpdated
                            stats.filesSkipped += providerStats.filesSkipped
                            stats.providersCompleted += 1
                            stats.updatedConversationIds.formUnion(providerStats.updatedConversationIds)
                        }
                    } catch {
                        #if DEBUG
                        print("⚠️ SyncService: Failed to sync \(provider): \(error)")
                        #endif
                        stats.errors += 1
                    }
                }

                // Merge web stats
                let webStats = try await webStatsTask
                if let ws = webStats {
                    stats.conversationsUpdated += ws.conversationsUpdated
                    stats.messagesUpdated += ws.messagesUpdated
                    stats.errors += ws.errors
                    stats.updatedConversationIds.formUnion(ws.updatedConversationIds)
                    if ws.conversationsUpdated > 0 || ws.errors == 0 {
                        stats.providersCompleted += ws.providersCompleted
                    }
                }

                await updateStatus(.completed(stats))
                return stats

            } catch is CancellationError {
                await updateStatus(.cancelled)
                throw CancellationError()
            } catch {
                await updateStatus(.failed(error.localizedDescription))
                throw error
            }
        }

        currentTask = task
        return try await task.value
    }

    /// Generic provider sync dispatcher
    /// Routes to the appropriate sync method based on provider type
    private func syncProvider(_ provider: Provider) async throws -> SyncStats? {
        switch provider {
        case .claudeCode:
            return try await syncClaudeCode()
        case .codex:
            return try await syncCodex()
        case .opencode:
            return try await syncOpenCode()
        case .geminiCLI:
            return try await syncGeminiCLI()
        case .copilot:
            return try await syncCopilot()
        case .cursor:
            return try await syncCursor()
        case .claudeWeb, .chatgptWeb, .gemini:
            // Web providers are handled separately
            return nil
        }
    }

    /// Cancel the current sync operation
    func cancel() {
        currentTask?.cancel()
    }

    // MARK: - Incremental Sync

    /// Sync a single file (incremental sync for file watcher)
    /// Returns updated conversation IDs
    func syncFile(url: URL) async -> Set<UUID> {
        let path = url.path

        // Determine provider based on path
        if ClaudeCodeParser.isClaudeCodePath(path) && url.pathExtension == "jsonl" {
            // Claude Code file
            do {
                if let (conversation, messages) = try await parseClaudeCodeFile(url) {
                    if let result = await saveToDatabase(conversation, messages: messages),
                       result.didChange {
                        return [result.id]
                    }
                }
            } catch {
                #if DEBUG
                print("Failed to sync Claude Code file \(url.lastPathComponent): \(error)")
                #endif
            }
        } else if path.contains(".codex/sessions/") && url.pathExtension == "jsonl" {
            // Codex session file - parse ONLY this file, not all sessions
            do {
                let result = try await parseCodexSessionFile(url)
                if !result.isEmpty {
                    markCodexSessionSynced(url)
                    saveCodexSessionModDates()
                }
                return result
            } catch {
                #if DEBUG
                print("Failed to sync Codex session file \(url.lastPathComponent): \(error)")
                #endif
            }
        } else if path.contains(".codex") && url.lastPathComponent == "history.jsonl" {
            // history.jsonl changed - check if sessions exist AND are non-empty
            if codexParser.hasSessionFiles() {
                // Sessions authoritative - ignore history.jsonl
                #if DEBUG
                print("🟡 SyncService: Ignoring history.jsonl - sessions are authoritative")
                #endif
                return []
            }
            // No sessions - fall back to history.jsonl
            do {
                let results = try await parseCodexHistoryFile()
                let stats = await saveBatchToDatabase(results)
                return stats.updatedConversationIds
            } catch {
                #if DEBUG
                print("Failed to sync Codex history: \(error)")
                #endif
            }
        }

        return []
    }

    /// Parse a single Codex session file
    /// Uses streaming parser for large files (>5MB) to prevent memory spikes
    private func parseCodexSessionFile(_ url: URL) async throws -> Set<UUID> {
        // Check file size to decide parsing method
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let useStreaming = fileSize > 5 * 1024 * 1024  // 5MB threshold

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [codexParser, repository] in
                do {
                    // Use streaming parser for large files to avoid memory spikes
                    let result: (Conversation, [Message])?
                    if useStreaming {
                        result = try codexParser.streamParseSessionFile(at: url)
                    } else {
                        result = try codexParser.parseSessionFile(at: url)
                    }

                    guard let (conversation, messages) = result else {
                        continuation.resume(returning: [])
                        return
                    }

                    let upsertResult = try repository.upsert(conversation, messages: messages)
                    if upsertResult.didChange {
                        continuation.resume(returning: [upsertResult.id])
                    } else {
                        continuation.resume(returning: [])
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Claude Code Sync

    private func syncClaudeCode() async throws -> SyncStats {
        var stats = SyncStats()
        let provider = Provider.claudeCode
        skippedFilesCount = 0

        // Phase 1: Discovery
        await updateProviderProgress(provider, .discovering(weight: 0.5))

        let files = await discoverClaudeCodeFiles()
        let totalFiles = files.count

        guard totalFiles > 0 else {
            await updateProviderProgress(provider, ProviderSyncProgress(
                phase: .completed,
                progress: 1.0,
                weight: 0.5
            ))
            return stats
        }

        // Filter to only files that need syncing (modified since last sync)
        let filesToSync = files.filter { fileNeedsSync($0) }
        let filesToProcess = filesToSync.count
        skippedFilesCount = totalFiles - filesToProcess

        #if DEBUG
        print("🟢 SyncService: Claude Code - \(totalFiles) files discovered, \(filesToProcess) need sync, \(skippedFilesCount) skipped (unchanged)")
        #endif

        guard filesToProcess > 0 else {
            await updateProviderProgress(provider, ProviderSyncProgress(
                phase: .completed,
                progress: 1.0,
                weight: 0.5,
                itemsProcessed: 0,
                totalItems: 0
            ))
            return stats
        }

        // Phase 2: Parse and save each file
        // Batch progress updates to reduce MainActor hops, but keep UI responsive.
        let progressUpdateInterval = max(10, filesToProcess / 50) // ~2% granularity
        let minimumUpdateInterval: TimeInterval = 0.2
        var lastProgressUpdate = Date.distantPast

        for (index, fileURL) in filesToSync.enumerated() {
            try Task.checkCancellation()

            // Update progress periodically or when enough time has passed
            let now = Date()
            let shouldUpdateByCount = index % progressUpdateInterval == 0 || index == filesToProcess - 1
            let shouldUpdateByTime = now.timeIntervalSince(lastProgressUpdate) >= minimumUpdateInterval
            if shouldUpdateByCount || shouldUpdateByTime {
                lastProgressUpdate = now
                let progress = Double(index + 1) / Double(filesToProcess)
                await updateProviderProgress(provider, ProviderSyncProgress(
                    phase: .parsing(current: index + 1, total: filesToProcess),
                    progress: progress,
                    weight: 0.5,
                    itemsProcessed: index + 1,
                    totalItems: filesToProcess
                ))
            }

            // Parse file off main thread
            if let (conversation, messages) = try? await parseClaudeCodeFile(fileURL) {
                // Save to database on background queue
                if let result = await saveToDatabase(conversation, messages: messages),
                   result.didChange {
                    stats.conversationsUpdated += 1
                    stats.messagesUpdated += messages.count
                    stats.updatedConversationIds.insert(result.id)
                }
            }

            // Mark file as synced regardless of whether it changed (file was processed)
            markFileSynced(fileURL)

            // Yield periodically to prevent blocking
            if index % 10 == 0 {
                await Task.yield()
            }
        }

        // Persist file modification dates
        saveFileModificationDates()

        // Include skipped files count in stats
        stats.filesSkipped = skippedFilesCount

        // Phase 3: Complete
        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .completed,
            progress: 1.0,
            weight: 0.5,
            itemsProcessed: filesToProcess,
            totalItems: filesToProcess
        ))

        return stats
    }

    private func discoverClaudeCodeFiles() async -> [URL] {
        // Run file discovery on a background thread
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [claudeCodeParser] in
                let files = claudeCodeParser.discoverConversationFiles()
                continuation.resume(returning: files)
            }
        }
    }

    private func parseClaudeCodeFile(_ url: URL) async throws -> (Conversation, [Message])? {
        // Run parsing on a background thread
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [claudeCodeParser] in
                do {
                    let result = try claudeCodeParser.parseFile(at: url)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Codex Sync

    private func syncCodex() async throws -> SyncStats {
        let provider = Provider.codex

        // Phase 1: Discovery
        await updateProviderProgress(provider, .discovering(weight: 0.3))

        // Check if sessions exist (sessions are authoritative)
        if codexParser.hasSessionFiles() {
            // Sessions exist - use incremental sync with per-file tracking
            return try await syncCodexSessions()
        }

        // No sessions - fall back to history.jsonl
        return try await syncCodexHistory()
    }

    /// Sync Codex using session files (incremental, per-file tracking)
    private func syncCodexSessions() async throws -> SyncStats {
        var stats = SyncStats()
        let provider = Provider.codex

        // Invalidate cache for deleted sessions
        invalidateDeletedCodexSessions()

        // Discover all session files
        let files = await discoverCodexSessionFiles()
        let totalFiles = files.count

        guard totalFiles > 0 else {
            await updateProviderProgress(provider, ProviderSyncProgress(
                phase: .completed,
                progress: 1.0,
                weight: 0.3
            ))
            return stats
        }

        // Filter to only files that need syncing (modified since last sync)
        let filesToSync = files.filter { codexSessionNeedsSync($0) }
        let filesToProcess = filesToSync.count
        let skippedCount = totalFiles - filesToProcess

        #if DEBUG
        print("🟢 SyncService: Codex sessions - \(totalFiles) files discovered, \(filesToProcess) need sync, \(skippedCount) skipped (unchanged)")
        #endif

        guard filesToProcess > 0 else {
            await updateProviderProgress(provider, ProviderSyncProgress(
                phase: .completed,
                progress: 1.0,
                weight: 0.3,
                itemsProcessed: 0,
                totalItems: 0
            ))
            stats.filesSkipped = skippedCount
            return stats
        }

        // Phase 2: Parse and save each file
        let progressUpdateInterval = max(5, filesToProcess / 20)

        for (index, fileURL) in filesToSync.enumerated() {
            try Task.checkCancellation()

            // Update progress periodically
            if index % progressUpdateInterval == 0 || index == filesToProcess - 1 {
                let progress = Double(index + 1) / Double(filesToProcess)
                await updateProviderProgress(provider, ProviderSyncProgress(
                    phase: .parsing(current: index + 1, total: filesToProcess),
                    progress: progress,
                    weight: 0.3,
                    itemsProcessed: index + 1,
                    totalItems: filesToProcess
                ))
            }

            // Parse session file
            do {
                let updatedIds = try await parseCodexSessionFile(fileURL)
                if !updatedIds.isEmpty {
                    stats.conversationsUpdated += 1
                    stats.updatedConversationIds.formUnion(updatedIds)
                }
            } catch {
                #if DEBUG
                print("⚠️ SyncService: Failed to parse Codex session \(fileURL.lastPathComponent): \(error)")
                #endif
            }

            // Mark file as synced regardless of whether it changed
            markCodexSessionSynced(fileURL)

            // Yield periodically to prevent blocking
            if index % 10 == 0 {
                await Task.yield()
            }
        }

        // Persist session modification dates
        saveCodexSessionModDates()

        stats.filesSkipped = skippedCount

        // Phase 3: Complete
        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .completed,
            progress: 1.0,
            weight: 0.3,
            itemsProcessed: filesToProcess,
            totalItems: filesToProcess
        ))

        return stats
    }

    /// Sync Codex using history.jsonl fallback (no sessions available)
    private func syncCodexHistory() async throws -> SyncStats {
        var stats = SyncStats()
        let provider = Provider.codex

        // Phase 2: Parse
        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .parsing(current: 1, total: 1),
            progress: 0.5,
            weight: 0.3
        ))

        let results = try await parseCodexHistoryFile()
        let totalResults = results.count

        // Phase 3: Save (on background queue)
        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .saving,
            progress: 0.8,
            weight: 0.3
        ))

        // Batch saves on background queue
        let savedStats = await saveBatchToDatabase(results)
        stats.conversationsUpdated += savedStats.conversationsUpdated
        stats.messagesUpdated += savedStats.messagesUpdated
        stats.updatedConversationIds.formUnion(savedStats.updatedConversationIds)

        // Phase 4: Complete
        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .completed,
            progress: 1.0,
            weight: 0.3,
            itemsProcessed: totalResults,
            totalItems: totalResults
        ))

        return stats
    }

    /// Discover Codex session files
    private func discoverCodexSessionFiles() async -> [URL] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [codexParser] in
                let files = codexParser.discoverSessionFiles()
                continuation.resume(returning: files)
            }
        }
    }

    private func parseCodexHistoryFile() async throws -> [(Conversation, [Message])] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [codexParser] in
                do {
                    // parseHistoryOnly() parses history.jsonl without checking sessions
                    let results = try codexParser.parseHistoryOnly()
                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Database Operations (background queue)

    /// Save a single conversation to database on background queue
    private func saveToDatabase(_ conversation: Conversation, messages: [Message]) async -> ConversationRepository.UpsertResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [repository] in
                do {
                    let result = try repository.upsert(conversation, messages: messages)
                    continuation.resume(returning: result)
                } catch {
                    // Log database errors to help diagnose sync issues
                    #if DEBUG
                    print("⚠️ SyncService: Failed to save conversation \(conversation.id): \(error.localizedDescription)")
                    #endif
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Save a batch of conversations to database on background queue
    private func saveBatchToDatabase(_ items: [(Conversation, [Message])]) async -> SyncStats {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [repository] in
                var stats = SyncStats()
                var failedCount = 0
                for (conversation, messages) in items {
                    do {
                        let result = try repository.upsert(conversation, messages: messages)
                        if result.didChange {
                            stats.conversationsUpdated += 1
                            stats.messagesUpdated += messages.count
                            stats.updatedConversationIds.insert(result.id)
                        }
                    } catch {
                        failedCount += 1
                        // Log but continue processing other items
                        #if DEBUG
                        print("⚠️ SyncService: Failed to save conversation \(conversation.id): \(error.localizedDescription)")
                        #endif
                    }
                }
                #if DEBUG
                if failedCount > 0 {
                    print("⚠️ SyncService: \(failedCount)/\(items.count) conversations failed to save")
                }
                #endif
                continuation.resume(returning: stats)
            }
        }
    }

    // MARK: - State Updates (hop to MainActor)

    private func updateStatus(_ status: SyncStatus) async {
        await MainActor.run { [weak state] in
            state?.setStatus(status)
        }
    }

    private func updateProviderProgress(_ provider: Provider, _ progress: ProviderSyncProgress) async {
        await MainActor.run { [weak state] in
            state?.updateProviderProgress(provider, progress: progress)
        }
    }

    // MARK: - OpenCode Sync

    private func syncOpenCode() async throws -> SyncStats {
        var stats = SyncStats()
        let provider = Provider.opencode

        // Phase 1: Discovery
        await updateProviderProgress(provider, .discovering(weight: 0.2))

        let files = OpenCodeParser.discoverSessionFiles()
        let totalFiles = files.count

        guard totalFiles > 0 else {
            await updateProviderProgress(provider, ProviderSyncProgress(phase: .completed, progress: 1.0, weight: 0.2))
            return stats
        }

        // Phase 2: Parse and save each file
        let progressUpdateInterval = max(5, totalFiles / 20)

        for (index, fileURL) in files.enumerated() {
            try Task.checkCancellation()

            if index % progressUpdateInterval == 0 || index == totalFiles - 1 {
                let progress = Double(index + 1) / Double(totalFiles)
                await updateProviderProgress(provider, ProviderSyncProgress(
                    phase: .parsing(current: index + 1, total: totalFiles),
                    progress: progress * 0.9,
                    weight: 0.2,
                    itemsProcessed: index + 1,
                    totalItems: totalFiles
                ))
            }

            if let (conversation, messages) = OpenCodeParser.parseSession(at: fileURL) {
                if let result = await saveToDatabase(conversation, messages: messages), result.didChange {
                    stats.conversationsUpdated += 1
                    stats.messagesUpdated += messages.count
                    stats.updatedConversationIds.insert(result.id)
                }
            }
        }

        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .completed, progress: 1.0, weight: 0.2,
            itemsProcessed: totalFiles, totalItems: totalFiles
        ))

        return stats
    }

    // MARK: - Gemini CLI Sync

    private func syncGeminiCLI() async throws -> SyncStats {
        var stats = SyncStats()
        let provider = Provider.geminiCLI

        // Phase 1: Discovery
        await updateProviderProgress(provider, .discovering(weight: 0.2))

        let files = GeminiCLIParser.discoverSessionFiles()
        let totalFiles = files.count

        guard totalFiles > 0 else {
            await updateProviderProgress(provider, ProviderSyncProgress(phase: .completed, progress: 1.0, weight: 0.2))
            return stats
        }

        // Phase 2: Parse and save each file
        let progressUpdateInterval = max(5, totalFiles / 20)

        for (index, fileURL) in files.enumerated() {
            try Task.checkCancellation()

            if index % progressUpdateInterval == 0 || index == totalFiles - 1 {
                let progress = Double(index + 1) / Double(totalFiles)
                await updateProviderProgress(provider, ProviderSyncProgress(
                    phase: .parsing(current: index + 1, total: totalFiles),
                    progress: progress * 0.9,
                    weight: 0.2,
                    itemsProcessed: index + 1,
                    totalItems: totalFiles
                ))
            }

            if let (conversation, messages) = GeminiCLIParser.parseSession(at: fileURL) {
                if let result = await saveToDatabase(conversation, messages: messages), result.didChange {
                    stats.conversationsUpdated += 1
                    stats.messagesUpdated += messages.count
                    stats.updatedConversationIds.insert(result.id)
                }
            }
        }

        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .completed, progress: 1.0, weight: 0.2,
            itemsProcessed: totalFiles, totalItems: totalFiles
        ))

        return stats
    }

    // MARK: - Copilot CLI Sync

    private func syncCopilot() async throws -> SyncStats {
        var stats = SyncStats()
        let provider = Provider.copilot

        // Phase 1: Discovery
        await updateProviderProgress(provider, .discovering(weight: 0.2))

        let files = CopilotCLIParser.discoverSessionFiles()
        let totalFiles = files.count

        guard totalFiles > 0 else {
            await updateProviderProgress(provider, ProviderSyncProgress(phase: .completed, progress: 1.0, weight: 0.2))
            return stats
        }

        // Phase 2: Parse and save each file
        let progressUpdateInterval = max(5, totalFiles / 20)

        for (index, fileURL) in files.enumerated() {
            try Task.checkCancellation()

            if index % progressUpdateInterval == 0 || index == totalFiles - 1 {
                let progress = Double(index + 1) / Double(totalFiles)
                await updateProviderProgress(provider, ProviderSyncProgress(
                    phase: .parsing(current: index + 1, total: totalFiles),
                    progress: progress * 0.9,
                    weight: 0.2,
                    itemsProcessed: index + 1,
                    totalItems: totalFiles
                ))
            }

            if let (conversation, messages) = CopilotCLIParser.parseSession(at: fileURL) {
                if let result = await saveToDatabase(conversation, messages: messages), result.didChange {
                    stats.conversationsUpdated += 1
                    stats.messagesUpdated += messages.count
                    stats.updatedConversationIds.insert(result.id)
                }
            }
        }

        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .completed, progress: 1.0, weight: 0.2,
            itemsProcessed: totalFiles, totalItems: totalFiles
        ))

        return stats
    }

    // MARK: - Cursor Sync

    private func syncCursor() async throws -> SyncStats {
        var stats = SyncStats()
        let provider = Provider.cursor

        // Phase 1: Discovery
        await updateProviderProgress(provider, .discovering(weight: 0.2))

        // Cursor parses all databases at once
        let results = CursorParser.parseAllSessions()
        let totalResults = results.count

        guard totalResults > 0 else {
            await updateProviderProgress(provider, ProviderSyncProgress(phase: .completed, progress: 1.0, weight: 0.2))
            return stats
        }

        // Phase 2: Save results
        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .saving, progress: 0.5, weight: 0.2,
            itemsProcessed: 0, totalItems: totalResults
        ))

        let savedStats = await saveBatchToDatabase(results)
        stats.conversationsUpdated += savedStats.conversationsUpdated
        stats.messagesUpdated += savedStats.messagesUpdated
        stats.updatedConversationIds.formUnion(savedStats.updatedConversationIds)

        await updateProviderProgress(provider, ProviderSyncProgress(
            phase: .completed, progress: 1.0, weight: 0.2,
            itemsProcessed: totalResults, totalItems: totalResults
        ))

        return stats
    }
}
