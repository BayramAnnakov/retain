import Foundation

/// Command-line runner to execute full CLI LLM scan and persist results.
enum CLIFullScanRunner {
    private static let scanFlag = "--scan-cli"
    private static let dbFlag = "--db"
    private static let resetFlag = "--reset"
    private static let allowCloudFlag = "--allow-cloud"
    private static let typesFlag = "--types"
    private static let batchFlag = "--batch"

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains(scanFlag) else { return false }

        let dbURL = resolveDatabaseURL(from: arguments)
        let shouldReset = arguments.contains(resetFlag)
        let allowCloud = arguments.contains(allowCloudFlag)
        let batchSize = parseIntFlag(batchFlag, arguments: arguments, defaultValue: 10)
        let types = parseTypes(arguments: arguments)

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do {
                try await runScan(
                    dbURL: dbURL,
                    types: types,
                    batchSize: batchSize,
                    resetBeforeScan: shouldReset,
                    allowCloud: allowCloud
                )
            } catch {
                fputs("CLI scan failed: \(error)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }
        // Keep the main run loop alive while waiting so @MainActor work can proceed.
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if exitCode != 0 {
            exit(exitCode)
        }
        return true
    }

    private static func resolveDatabaseURL(from arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: dbFlag), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1])
        }

        let fileManager = FileManager.default
        let appSupportURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let directoryURL = appSupportURL?.appendingPathComponent("Retain", isDirectory: true)
        return directoryURL?.appendingPathComponent("retain.sqlite")
            ?? URL(fileURLWithPath: "retain.sqlite")
    }

    private static func parseIntFlag(_ flag: String, arguments: [String], defaultValue: Int) -> Int {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return defaultValue
        }
        return Int(arguments[index + 1]) ?? defaultValue
    }

    private static func parseTypes(arguments: [String]) -> [AnalysisType] {
        guard let index = arguments.firstIndex(of: typesFlag), index + 1 < arguments.count else {
            return [.learning, .workflow]
        }

        let raw = arguments[index + 1]
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let mapped = parts.compactMap { AnalysisType(rawValue: $0) }.filter { $0 != .dedupe }
        return mapped.isEmpty ? [.learning, .workflow] : mapped
    }

    private static func runScan(
        dbURL: URL,
        types: [AnalysisType],
        batchSize: Int,
        resetBeforeScan: Bool,
        allowCloud: Bool
    ) async throws {
        let database = try AppDatabase.open(path: dbURL)

        if resetBeforeScan {
            try database.write { db in
                try db.execute(sql: "DELETE FROM learnings")
                try db.execute(sql: "DELETE FROM workflow_signatures")
                try db.execute(sql: "DELETE FROM analysis_queue")
                try db.execute(sql: "DELETE FROM analysis_suggestions")
            }
        }

        let queueRepository = AnalysisQueueRepository(database: database)
        let workflowRepository = WorkflowSignatureRepository(db: database)
        let learningRepository = LearningRepository(database: database)
        let resultProcessor = AnalysisResultProcessor(
            database: database,
            learningRepository: learningRepository,
            workflowRepository: workflowRepository
        )
        let conversationRepository = ConversationRepository(database: database)

        let originalConsent = UserDefaults.standard.bool(forKey: "allowCloudAnalysis")
        if allowCloud {
            UserDefaults.standard.set(true, forKey: "allowCloudAnalysis")
        }
        defer {
            if allowCloud {
                UserDefaults.standard.set(originalConsent, forKey: "allowCloudAnalysis")
            }
        }

        let orchestrator = await MainActor.run {
            LLMOrchestrator(
                cliService: CLILLMService(),
                queueRepository: queueRepository,
                resultProcessor: resultProcessor,
                conversationRepository: conversationRepository
            )
        }

        try await orchestrator.runFullScan(
            types: types,
            batchSize: batchSize,
            requireCLI: true
        )

        let counts = try database.read { db in
            let learnings = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM learnings") ?? 0
            let workflows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workflow_signatures") ?? 0
            return (learnings, workflows)
        }

        print("CLI scan complete: \(counts.0) learnings, \(counts.1) workflows")
    }
}
