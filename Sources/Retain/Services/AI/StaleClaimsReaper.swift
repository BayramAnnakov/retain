import Foundation

/// Periodically releases stale claims from crashed/stuck processes
/// Runs on app launch and every 5 minutes thereafter
/// Also processes orphaned completed results on startup
actor StaleClaimsReaper {
    private let queueRepository: AnalysisQueueRepository
    private let resultProcessor: AnalysisResultProcessor
    private var reaperTask: Task<Void, Never>?

    /// How long before a claim is considered stale (default: 10 minutes)
    private let staleThreshold: TimeInterval

    /// How often to run the reaper (default: 5 minutes)
    private let reaperInterval: TimeInterval

    /// Whether the reaper is currently running
    private(set) var isRunning = false

    /// Last time the reaper ran
    private(set) var lastReapTime: Date?

    /// Number of claims released in last run
    private(set) var lastReleasedCount = 0

    /// Number of orphaned results processed on startup
    private(set) var orphanedResultsProcessed = 0

    // MARK: - Init

    init(
        queueRepository: AnalysisQueueRepository = AnalysisQueueRepository(),
        resultProcessor: AnalysisResultProcessor = AnalysisResultProcessor(),
        staleThreshold: TimeInterval = 600,  // 10 minutes
        reaperInterval: TimeInterval = 300   // 5 minutes
    ) {
        self.queueRepository = queueRepository
        self.resultProcessor = resultProcessor
        self.staleThreshold = staleThreshold
        self.reaperInterval = reaperInterval
    }

    // MARK: - Lifecycle

    /// Start the periodic reaper
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Run immediately on start: reap stale claims + process orphaned results
        Task {
            await reapStaleClaims()
            await processOrphanedResults()
        }

        // Schedule periodic runs (only reaping, not result processing)
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self?.reaperInterval ?? 300) * 1_000_000_000)
                    await self?.reapStaleClaims()
                } catch {
                    // Task was cancelled
                    break
                }
            }
        }
    }

    /// Process any completed items that weren't applied (e.g., from app crash)
    /// Called once on startup to handle orphaned results
    private func processOrphanedResults() async {
        do {
            let processed = try resultProcessor.processAllUnprocessed()
            orphanedResultsProcessed = processed

            if processed > 0 {
                #if DEBUG
                print("StaleClaimsReaper: Processed \(processed) orphaned completed results on startup")
                #endif
            }
        } catch {
            #if DEBUG
            print("StaleClaimsReaper: Error processing orphaned results: \(error)")
            #endif
        }
    }

    /// Stop the periodic reaper
    func stop() {
        isRunning = false
        reaperTask?.cancel()
        reaperTask = nil
    }

    // MARK: - Reaping

    /// Release stale claims (can be called manually or by scheduler)
    func reapStaleClaims() async {
        do {
            let released = try queueRepository.releaseStaleClaims(olderThan: staleThreshold)
            lastReapTime = Date()
            lastReleasedCount = released

            if released > 0 {
                #if DEBUG
                print("StaleClaimsReaper: Released \(released) stale claims")
                #endif
            }
        } catch {
            #if DEBUG
            print("StaleClaimsReaper error: \(error)")
            #endif
        }
    }

    /// Get current status for monitoring
    func getStatus() -> ReaperStatus {
        ReaperStatus(
            isRunning: isRunning,
            lastReapTime: lastReapTime,
            lastReleasedCount: lastReleasedCount,
            orphanedResultsProcessed: orphanedResultsProcessed,
            staleThreshold: staleThreshold,
            reaperInterval: reaperInterval
        )
    }

    // MARK: - Status

    struct ReaperStatus {
        let isRunning: Bool
        let lastReapTime: Date?
        let lastReleasedCount: Int
        let orphanedResultsProcessed: Int
        let staleThreshold: TimeInterval
        let reaperInterval: TimeInterval

        var formattedLastReapTime: String {
            guard let time = lastReapTime else { return "Never" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: time, relativeTo: Date())
        }

        var formattedStaleThreshold: String {
            let minutes = Int(staleThreshold / 60)
            return "\(minutes) min"
        }

        var formattedReaperInterval: String {
            let minutes = Int(reaperInterval / 60)
            return "\(minutes) min"
        }
    }
}

// MARK: - Cleanup Extension

extension StaleClaimsReaper {
    /// Clean up old completed/failed items
    /// Should be called less frequently (e.g., daily)
    func cleanupOldItems(olderThanDays: Int = 30) async {
        let threshold = TimeInterval(olderThanDays * 24 * 60 * 60)

        do {
            let deleted = try queueRepository.deleteOldItems(olderThan: threshold)
            if deleted > 0 {
                #if DEBUG
                print("StaleClaimsReaper: Deleted \(deleted) old queue items")
                #endif
            }
        } catch {
            #if DEBUG
            print("StaleClaimsReaper cleanup error: \(error)")
            #endif
        }
    }
}
