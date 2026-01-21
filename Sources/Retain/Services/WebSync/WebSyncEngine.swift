import Foundation
import WebKit

/// Main coordinator for web-based conversation sync
@MainActor
final class WebSyncEngine: ObservableObject {
    // MARK: - Published State

    @Published private(set) var claudeConnectionStatus: ConnectionStatus = .disconnected
    @Published private(set) var chatgptConnectionStatus: ConnectionStatus = .disconnected
    @Published private(set) var syncingProviders: Set<Provider> = []
    @Published private(set) var lastSyncDate: [Provider: Date] = [:]
    @Published private(set) var lastVerifiedDate: [Provider: Date] = [:]

    /// Computed property for backward compatibility
    var isSyncing: Bool { !syncingProviders.isEmpty }

    /// Check if a specific provider is currently syncing
    func isSyncing(provider: Provider) -> Bool {
        syncingProviders.contains(provider)
    }
    @Published private(set) var backoffUntil: [Provider: Date] = [:]
    @Published private(set) var consecutiveFailures: [Provider: Int] = [:]
    @Published var error: WebSyncError?

    /// Session expiry notifications - set when a session is cleared due to expiration
    /// UI should observe this and show appropriate messaging
    @Published var sessionExpiredNotification: SessionExpiredNotification?

    struct SessionExpiredNotification: Equatable {
        let provider: Provider
        let timestamp: Date
    }

    // MARK: - Connection Status

    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected(email: String?)
        case error(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    /// Rich session state that distinguishes between verified and unverified sessions
    enum SessionState: Equatable {
        case notConnected       // No cookies stored
        case sessionSaved       // Cookies exist but not recently verified
        case connected(email: String?)  // Verified within last hour
        case connecting
        case error(String)
    }

    /// Get the rich session state for a provider
    /// - notConnected: No cookies in storage
    /// - sessionSaved: Cookies exist but haven't been verified recently
    /// - connected: Session verified within the last hour
    func getSessionState(for provider: Provider) -> SessionState {
        let connectionStatus: ConnectionStatus
        switch provider {
        case .claudeWeb:
            connectionStatus = claudeConnectionStatus
        case .chatgptWeb:
            connectionStatus = chatgptConnectionStatus
        default:
            return .notConnected
        }

        switch connectionStatus {
        case .connecting:
            return .connecting
        case .error(let message):
            return .error(message)
        case .connected(let email):
            // Check if recently verified (within last hour)
            if let verified = lastVerifiedDate[provider],
               Date().timeIntervalSince(verified) < 3600 {
                return .connected(email: email)
            }
            // Cookies exist but not recently verified
            return .sessionSaved
        case .disconnected:
            // Check if there are stored cookies (but not connected)
            if sessionStorage.hasValidSession(for: provider) {
                return .sessionSaved
            }
            return .notConnected
        }
    }

    /// Mark a session as verified (call after successful API validation)
    func markSessionVerified(for provider: Provider) {
        lastVerifiedDate[provider] = Date()
        persistLastVerifiedDates()
    }

    /// Clear verification state for a provider
    private func clearVerificationState(for provider: Provider) {
        lastVerifiedDate[provider] = nil
        persistLastVerifiedDates()
    }

    private let lastVerifiedDefaultsKey = "webSyncLastVerifiedDates"

    private func loadLastVerifiedDates() -> [Provider: Date] {
        guard let stored = UserDefaults.standard.dictionary(forKey: lastVerifiedDefaultsKey) as? [String: Double] else {
            return [:]
        }
        var result: [Provider: Date] = [:]
        for (key, timestamp) in stored {
            if let provider = Provider(rawValue: key) {
                result[provider] = Date(timeIntervalSince1970: timestamp)
            }
        }
        return result
    }

    private func persistLastVerifiedDates() {
        var stored: [String: Double] = [:]
        for (provider, date) in lastVerifiedDate {
            stored[provider.rawValue] = date.timeIntervalSince1970
        }
        UserDefaults.standard.set(stored, forKey: lastVerifiedDefaultsKey)
    }

    // MARK: - Errors

    enum WebSyncError: LocalizedError {
        case notAuthenticated
        case networkError(Error)
        case parseError(String)
        case rateLimited(retryAfter: TimeInterval?)
        case sessionExpired

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Not authenticated. Please sign in."
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .parseError(let message):
                return "Parse error: \(message)"
            case .rateLimited(let retryAfter):
                if let retryAfter, retryAfter > 0 {
                    return "Rate limited. Retry after \(Int(retryAfter))s."
                }
                return "Rate limited. Please wait and try again."
            case .sessionExpired:
                return "Session expired (~30 days). Already-synced conversations are safe. Sign in again in your browser, then reconnect."
            }
        }
    }

    // MARK: - Dependencies

    private let sessionStorage = SessionStorage()
    private let claudeSync: ClaudeWebSync
    private let chatgptSync: ChatGPTWebSync
    private let repository: ConversationRepository
    private let cookieImportOrder: [Browser] = [.safari, .chrome, .firefox]
    private let lastSyncDefaultsKey = "webSyncLastSyncDates"
    private let backoffDefaultsKey = "webSyncBackoffUntil"
    private let failureDefaultsKey = "webSyncConsecutiveFailures"
    private let maxRetryAttempts = 3
    private let baseRetryDelayNanos: UInt64 = 1_000_000_000
    private let maxRetryDelayNanos: UInt64 = 16_000_000_000
    private let syncLookbackSeconds: TimeInterval = 60

    // MARK: - Init

    /// Set to true to skip auto-checking sessions on init (used during onboarding)
    private var skipInitialSessionCheck: Bool = false

    init(repository: ConversationRepository = ConversationRepository(), skipInitialSessionCheck: Bool = false, deferKeychainPersistence: Bool = true) {
        self.repository = repository
        self.skipInitialSessionCheck = skipInitialSessionCheck
        self.sessionStorage.deferKeychainPersistence = deferKeychainPersistence
        self.claudeSync = ClaudeWebSync(sessionStorage: sessionStorage)
        self.chatgptSync = ChatGPTWebSync(sessionStorage: sessionStorage)
        self.lastSyncDate = loadLastSyncDates()
        self.lastVerifiedDate = loadLastVerifiedDates()
        self.backoffUntil = loadBackoffUntil()
        self.consecutiveFailures = loadConsecutiveFailures()

        // NOTE: Session check deferred to avoid keychain prompt during onboarding
        // Call checkExistingSessions() explicitly after onboarding completes
        if !skipInitialSessionCheck {
            Task {
                await checkExistingSessions()
            }
        }
    }

    /// Manually trigger session check (call after onboarding completes)
    func checkExistingSessionsIfNeeded() async {
        if skipInitialSessionCheck {
            skipInitialSessionCheck = false
            await checkExistingSessions()
        }
    }

    // MARK: - Session Management

    /// Check for existing valid sessions on startup
    private func checkExistingSessions() async {
        // Check Claude session
        if sessionStorage.hasValidSession(for: .claudeWeb) {
            do {
                let userInfo = try await claudeSync.validateSession()
                claudeConnectionStatus = .connected(email: userInfo.email)
                markSessionVerified(for: .claudeWeb)
            } catch {
                handleSessionCheckError(error, provider: .claudeWeb)
            }
        }

        // Check ChatGPT session
        if sessionStorage.hasValidSession(for: .chatgptWeb) {
            do {
                let userInfo = try await chatgptSync.validateSession()
                chatgptConnectionStatus = .connected(email: userInfo.email)
                markSessionVerified(for: .chatgptWeb)
            } catch {
                handleSessionCheckError(error, provider: .chatgptWeb)
            }
        }
    }

    /// Clear the session expiry notification (call after user acknowledges)
    func clearSessionExpiredNotification() {
        sessionExpiredNotification = nil
    }

    /// Verify a session on-demand (called from Settings when user taps "Verify")
    func verifySession(for provider: Provider) async {
        guard sessionStorage.hasValidSession(for: provider) else { return }

        setConnectionStatus(.connecting, for: provider)

        do {
            let userInfo = try await validateSession(for: provider)
            setConnectionStatus(.connected(email: userInfo.email), for: provider)
            markSessionVerified(for: provider)
        } catch {
            handleVerifySessionError(error, provider: provider)
        }
    }

    /// Clear session state and notify UI that a session expired.
    private func handleSessionExpired(for provider: Provider) {
        sessionStorage.clearSession(for: provider)
        clearVerificationState(for: provider)
        clearLastSyncDate(provider)
        clearBackoff(for: provider)
        consecutiveFailures[provider] = 0
        persistConsecutiveFailures()

        if provider == .chatgptWeb {
            chatgptSync.clearAccessToken()
            KeychainHelper.chatgptAccessToken = nil
        }

        setConnectionStatus(.disconnected, for: provider)
        sessionExpiredNotification = SessionExpiredNotification(
            provider: provider,
            timestamp: Date()
        )
    }

    /// Handle startup session validation failures without discarding valid cookies.
    private func handleSessionCheckError(_ error: Error, provider: Provider) {
        if let syncError = error as? WebSyncError {
            switch syncError {
            case .sessionExpired, .notAuthenticated:
                handleSessionExpired(for: provider)
                return
            default:
                break
            }
        }

        // Transient failure (network, rate limit, parse): keep cookies, mark unverified.
        clearVerificationState(for: provider)
        setConnectionStatus(.disconnected, for: provider)
    }

    /// Handle explicit verify failures (user-initiated).
    private func handleVerifySessionError(_ error: Error, provider: Provider) {
        if let syncError = error as? WebSyncError {
            switch syncError {
            case .sessionExpired, .notAuthenticated:
                handleSessionExpired(for: provider)
                return
            default:
                break
            }
        }

        clearVerificationState(for: provider)
        setConnectionStatus(.error(error.localizedDescription), for: provider)
    }

    /// Create WebView configuration for login
    func createLoginWebView(for provider: Provider) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)

        return webView
    }

    /// Handle login completion - extract and store cookies
    func handleLoginComplete(for provider: Provider, webView: WKWebView) async {
        let dataStore = webView.configuration.websiteDataStore

        do {
            let cookies = await allCookies(in: dataStore.httpCookieStore)
            let filteredCookies = filterCookies(cookies, for: provider)

            switch provider {
            case .claudeWeb:
                claudeConnectionStatus = .connecting
                sessionStorage.storeCookies(filteredCookies, for: .claudeWeb)

                let userInfo = try await claudeSync.validateSession()
                claudeConnectionStatus = .connected(email: userInfo.email)
                markSessionVerified(for: .claudeWeb)

            case .chatgptWeb:
                chatgptConnectionStatus = .connecting
                sessionStorage.storeCookies(filteredCookies, for: .chatgptWeb)

                let userInfo = try await chatgptSync.validateSession()
                chatgptConnectionStatus = .connected(email: userInfo.email)
                markSessionVerified(for: .chatgptWeb)

            default:
                break
            }
        } catch {
            switch provider {
            case .claudeWeb:
                claudeConnectionStatus = .error(error.localizedDescription)
            case .chatgptWeb:
                chatgptConnectionStatus = .error(error.localizedDescription)
            default:
                break
            }
        }
    }

    /// Disconnect from a provider
    func disconnect(provider: Provider) {
        sessionStorage.clearSession(for: provider)
        clearLastSyncDate(provider)
        clearBackoff(for: provider)
        clearVerificationState(for: provider)
        consecutiveFailures[provider] = 0
        persistConsecutiveFailures()

        // Clear provider-specific Keychain tokens
        if provider == .chatgptWeb {
            KeychainHelper.chatgptAccessToken = nil
        }

        Task {
            await clearWebViewCookies(for: provider)
        }

        switch provider {
        case .claudeWeb:
            claudeConnectionStatus = .disconnected
        case .chatgptWeb:
            chatgptConnectionStatus = .disconnected
        default:
            break
        }
    }

    /// Enable keychain persistence and persist any pending cookies
    /// Call this after onboarding completes
    func enableKeychainPersistence() {
        sessionStorage.deferKeychainPersistence = false
        sessionStorage.persistPendingCookies()
    }

    // MARK: - Cookie Scoping

    private func filterCookies(_ cookies: [HTTPCookie], for provider: Provider) -> [HTTPCookie] {
        let allowedDomains = allowedCookieDomains(for: provider)
        guard !allowedDomains.isEmpty else { return [] }
        return cookies.filter { cookie in
            allowedDomains.contains { domainMatches(cookie.domain, allowedDomain: $0) }
        }
    }

    private func allowedCookieDomains(for provider: Provider) -> [String] {
        switch provider {
        case .claudeWeb:
            return ["claude.ai"]
        case .chatgptWeb:
            return ["chatgpt.com", "openai.com"]
        default:
            return []
        }
    }

    private func domainMatches(_ cookieDomain: String, allowedDomain: String) -> Bool {
        let normalizedCookieDomain = normalizeDomain(cookieDomain.lowercased())
        let normalizedAllowedDomain = normalizeDomain(allowedDomain.lowercased())

        return normalizedCookieDomain == normalizedAllowedDomain
            || normalizedCookieDomain.hasSuffix("." + normalizedAllowedDomain)
    }

    private func normalizeDomain(_ domain: String) -> String {
        domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    }

    private func clearWebViewCookies(for provider: Provider) async {
        let allowedDomains = allowedCookieDomains(for: provider)
        guard !allowedDomains.isEmpty else { return }

        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await allCookies(in: store)

        for cookie in cookies where allowedDomains.contains(where: { domainMatches(cookie.domain, allowedDomain: $0) }) {
            await deleteCookie(cookie, in: store)
        }
    }

    private func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func deleteCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) {
                continuation.resume()
            }
        }
    }

    // MARK: - Sync Operations

    /// Import browser cookies (Safari, Chrome, Firefox) to authenticate a provider.
    func importBrowserCookies(for provider: Provider) async {
        guard provider == .claudeWeb || provider == .chatgptWeb else { return }

        setConnectionStatus(.connecting, for: provider)

        do {
            let browsers = cookieImportOrder
            let candidates = try await Task.detached {
                try Self.loadCookieCandidates(
                    client: BrowserCookieClient(),
                    provider: provider,
                    browsers: browsers
                )
            }.value

            var lastError: Error?

            for candidate in candidates {
                let filteredCookies = filterCookies(candidate.cookies, for: provider)
                guard !filteredCookies.isEmpty else { continue }

                sessionStorage.storeCookies(filteredCookies, for: provider)

                do {
                    let userInfo = try await validateSession(for: provider)
                    setConnectionStatus(.connected(email: userInfo.email), for: provider)
                    markSessionVerified(for: provider)
                    return
                } catch {
                    sessionStorage.clearSession(for: provider)
                    lastError = error
                }
            }

            if let lastError {
                setConnectionStatus(.error(lastError.localizedDescription), for: provider)
            } else {
                setConnectionStatus(.error("No valid session cookies found."), for: provider)
            }
        } catch {
            setConnectionStatus(.error(error.localizedDescription), for: provider)
        }
    }

    /// Sync all connected web sources
    func syncAll() async {
        error = nil

        // Sync Claude.ai if connected and not already syncing
        if claudeConnectionStatus.isConnected && !syncingProviders.contains(.claudeWeb) {
            do {
                _ = try await syncClaude()
            } catch let syncError as WebSyncError {
                error = syncError
            } catch {
                self.error = .networkError(error)
            }
        }

        // Sync ChatGPT if connected and not already syncing
        if chatgptConnectionStatus.isConnected && !syncingProviders.contains(.chatgptWeb) {
            do {
                _ = try await syncChatGPT()
            } catch let syncError as WebSyncError {
                error = syncError
            } catch {
                self.error = .networkError(error)
            }
        }
    }

    /// Sync Claude.ai conversations
    /// Heavy work runs off MainActor to avoid blocking UI
    func syncClaude() async throws -> SyncStats {
        // Check if already syncing this provider
        guard !syncingProviders.contains(.claudeWeb) else {
            return SyncStats()
        }
        syncingProviders.insert(.claudeWeb)
        defer { syncingProviders.remove(.claudeWeb) }

        try ensureNotRateLimited(for: .claudeWeb)
        let lastSync = effectiveLastSyncDate(for: .claudeWeb)

        // Capture dependencies for off-MainActor work
        let claudeSyncRef = claudeSync
        let repositoryRef = repository

        // Run heavy sync work off MainActor
        let task = Task.detached { () throws -> WebSyncResult in
            var stats = SyncStats()
            var latestUpdatedAt: Date? = nil

            try Task.checkCancellation()

            // Fetch conversation list
            let conversationMetas: [ConversationMeta]
            do {
                conversationMetas = try await self.retrying(provider: .claudeWeb) {
                    try await claudeSyncRef.fetchConversationList(since: lastSync)
                }
            } catch let error as WebSyncError {
                stats.errors += 1
                switch error {
                case .sessionExpired, .notAuthenticated, .rateLimited:
                    throw error
                default:
                    return WebSyncResult(stats: stats, latestUpdatedAt: latestUpdatedAt)
                }
            } catch {
                stats.errors += 1
                return WebSyncResult(stats: stats, latestUpdatedAt: latestUpdatedAt)
            }

            try Task.checkCancellation()

            // Fetch and store each conversation
            for meta in conversationMetas {
                try Task.checkCancellation()
                do {
                    let (conversation, messages) = try await self.retrying(provider: .claudeWeb) {
                        try await claudeSyncRef.fetchConversation(id: meta.id)
                    }
                    if let result = try? repositoryRef.upsert(conversation, messages: messages),
                       result.didChange {
                        stats.conversationsUpdated += 1
                        stats.messagesUpdated += messages.count
                        stats.updatedConversationIds.insert(result.id)
                    }
                    if latestUpdatedAt == nil || meta.updatedAt > latestUpdatedAt! {
                        latestUpdatedAt = meta.updatedAt
                    }
                } catch {
                    stats.errors += 1
                    // Track the failed conversation ID
                    var providerFailures = stats.failedConversationIds[.claudeWeb] ?? []
                    providerFailures.append(meta.id)
                    stats.failedConversationIds[.claudeWeb] = providerFailures
                    continue
                }

                // Rate limit: ~60 requests per minute
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            }
            return WebSyncResult(stats: stats, latestUpdatedAt: latestUpdatedAt)
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }

            // Update status on MainActor
            updateLastSyncDateIfAvailable(.claudeWeb, latestUpdatedAt: result.latestUpdatedAt)
            resetFailureState(for: .claudeWeb)
            return result.stats
        } catch is CancellationError {
            task.cancel()
            throw CancellationError()
        } catch {
            if let syncError = error as? WebSyncError {
                switch syncError {
                case .sessionExpired, .notAuthenticated:
                    handleSessionExpired(for: .claudeWeb)
                default:
                    break
                }
            }
            recordFailure(for: .claudeWeb, error: error)
            throw error
        }
    }

    // MARK: - Cookie Import Helpers

    private struct CookieCandidate {
        let label: String
        let cookies: [HTTPCookie]
    }

    private enum CookieImportError: LocalizedError {
        case noCookiesFound(provider: Provider)
        case accessDenied(provider: Provider, hints: [String])

        var errorDescription: String? {
            switch self {
            case .noCookiesFound(let provider):
                return "No \(provider.displayName) cookies found in Safari, Chrome, or Firefox. Sign in and try again."
            case .accessDenied(_, let hints):
                let details = hints.joined(separator: " ")
                return "Browser cookie access denied. \(details)"
            }
        }
    }

    private nonisolated static func loadCookieCandidates(
        client: BrowserCookieClient,
        provider: Provider,
        browsers: [Browser]
    ) throws -> [CookieCandidate] {
        let query = BrowserCookieQuery(
            domains: cookieDomains(for: provider),
            domainMatch: .suffix,
            origin: .domainBased
        )

        var candidates: [CookieCandidate] = []
        var accessDeniedHints: [String] = []

        for browser in browsers {
            do {
                let sources = try client.records(matching: query, in: browser)
                for source in sources {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard !cookies.isEmpty else { continue }
                    candidates.append(CookieCandidate(label: source.label, cookies: cookies))
                }
            } catch let error as BrowserCookieError {
                if case .accessDenied = error {
                    let hint = "\(error.browser.displayName): \(error.errorDescription ?? "Access denied")"
                    accessDeniedHints.append(hint)
                }
            }
        }

        if candidates.isEmpty {
            if !accessDeniedHints.isEmpty {
                throw CookieImportError.accessDenied(provider: provider, hints: accessDeniedHints)
            }
            throw CookieImportError.noCookiesFound(provider: provider)
        }

        return candidates
    }

    private nonisolated static func cookieDomains(for provider: Provider) -> [String] {
        switch provider {
        case .claudeWeb:
            return ["claude.ai"]
        case .chatgptWeb:
            return ["chatgpt.com", "openai.com"]
        default:
            return []
        }
    }

    private func validateSession(for provider: Provider) async throws -> WebUserInfo {
        switch provider {
        case .claudeWeb:
            return try await claudeSync.validateSession()
        case .chatgptWeb:
            return try await chatgptSync.validateSession()
        default:
            throw WebSyncError.notAuthenticated
        }
    }

    private func setConnectionStatus(_ status: ConnectionStatus, for provider: Provider) {
        switch provider {
        case .claudeWeb:
            claudeConnectionStatus = status
        case .chatgptWeb:
            chatgptConnectionStatus = status
        default:
            break
        }
    }

    /// Sync ChatGPT conversations
    /// Heavy work runs off MainActor to avoid blocking UI
    func syncChatGPT() async throws -> SyncStats {
        // Check if already syncing this provider
        guard !syncingProviders.contains(.chatgptWeb) else {
            return SyncStats()
        }
        syncingProviders.insert(.chatgptWeb)
        defer { syncingProviders.remove(.chatgptWeb) }

        try ensureNotRateLimited(for: .chatgptWeb)
        #if DEBUG
        print("🟢 WebSyncEngine: syncChatGPT start")
        #endif
        let lastSync = effectiveLastSyncDate(for: .chatgptWeb)
        let stopAt = lastSync == nil ? nil : lastSyncDate[.chatgptWeb]

        // Capture dependencies for off-MainActor work
        let chatgptSyncRef = chatgptSync
        let repositoryRef = repository

        // Run heavy sync work off MainActor
        let task = Task.detached { () throws -> WebSyncResult in
            var stats = SyncStats()
            var latestUpdatedAt: Date? = nil

            try Task.checkCancellation()

            // Fetch conversation list (paginated)
            var offset = 0
            let limit = 20
            var hasMore = true

            while hasMore {
                try Task.checkCancellation()
                let page: ChatGPTWebSync.ConversationListPage
                do {
                    page = try await self.retrying(provider: .chatgptWeb) {
                        try await chatgptSyncRef.fetchConversationList(offset: offset, limit: limit)
                    }
                } catch let error as WebSyncError {
                    stats.errors += 1
                    switch error {
                    case .sessionExpired, .notAuthenticated, .rateLimited:
                        throw error
                    default:
                        return WebSyncResult(stats: stats, latestUpdatedAt: latestUpdatedAt)
                    }
                } catch {
                    stats.errors += 1
                    return WebSyncResult(stats: stats, latestUpdatedAt: latestUpdatedAt)
                }
                var conversationMetas = page.metas
                if let lastSync {
                    conversationMetas = conversationMetas.filter { $0.updatedAt >= lastSync }
                }
                #if DEBUG
                print("🟢 WebSyncEngine: ChatGPT list offset=\(offset) count=\(conversationMetas.count)")
                #endif

                if conversationMetas.isEmpty {
                    if let stopAt,
                       let oldest = page.oldestUpdatedAt,
                       oldest < stopAt {
                        hasMore = false
                        break
                    }
                    hasMore = page.metas.count == limit
                    offset += limit
                    continue
                }

                // Fetch and store each conversation
                for meta in conversationMetas {
                    try Task.checkCancellation()
                    do {
                        let (conversation, messages) = try await self.retrying(provider: .chatgptWeb) {
                            try await chatgptSyncRef.fetchConversation(id: meta.id)
                        }
                        if let result = try? repositoryRef.upsert(conversation, messages: messages),
                           result.didChange {
                            stats.conversationsUpdated += 1
                            stats.messagesUpdated += messages.count
                            stats.updatedConversationIds.insert(result.id)
                        }
                        if latestUpdatedAt == nil || meta.updatedAt > latestUpdatedAt! {
                            latestUpdatedAt = meta.updatedAt
                        }
                    } catch {
                        stats.errors += 1
                        // Track the failed conversation ID
                        var providerFailures = stats.failedConversationIds[.chatgptWeb] ?? []
                        providerFailures.append(meta.id)
                        stats.failedConversationIds[.chatgptWeb] = providerFailures
                        continue
                    }

                    // Rate limit
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }

                offset += limit
                hasMore = page.metas.count == limit
            }
            return WebSyncResult(stats: stats, latestUpdatedAt: latestUpdatedAt)
        }

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }

            // Update status on MainActor
            updateLastSyncDateIfAvailable(.chatgptWeb, latestUpdatedAt: result.latestUpdatedAt)
            resetFailureState(for: .chatgptWeb)
            return result.stats
        } catch is CancellationError {
            task.cancel()
            throw CancellationError()
        } catch {
            if let syncError = error as? WebSyncError {
                switch syncError {
                case .sessionExpired, .notAuthenticated:
                    handleSessionExpired(for: .chatgptWeb)
                default:
                    break
                }
            }
            recordFailure(for: .chatgptWeb, error: error)
            throw error
        }
    }

    private func loadLastSyncDates() -> [Provider: Date] {
        guard let stored = UserDefaults.standard.dictionary(forKey: lastSyncDefaultsKey) as? [String: Double] else {
            return [:]
        }

        var result: [Provider: Date] = [:]
        for (key, timestamp) in stored {
            if let provider = Provider(rawValue: key) {
                result[provider] = Date(timeIntervalSince1970: timestamp)
            }
        }
        return result
    }

    private func setLastSyncDate(_ provider: Provider, date: Date) {
        lastSyncDate[provider] = date
        var stored = UserDefaults.standard.dictionary(forKey: lastSyncDefaultsKey) as? [String: Double] ?? [:]
        stored[provider.rawValue] = date.timeIntervalSince1970
        UserDefaults.standard.set(stored, forKey: lastSyncDefaultsKey)
    }

    private func clearLastSyncDate(_ provider: Provider) {
        lastSyncDate[provider] = nil
        var stored = UserDefaults.standard.dictionary(forKey: lastSyncDefaultsKey) as? [String: Double] ?? [:]
        stored.removeValue(forKey: provider.rawValue)
        UserDefaults.standard.set(stored, forKey: lastSyncDefaultsKey)
    }

    private func effectiveLastSyncDate(for provider: Provider) -> Date? {
        guard let stored = lastSyncDate[provider] else { return nil }
        let counts = (try? repository.countByProvider()) ?? [:]
        let existingCount = counts[provider] ?? 0
        #if DEBUG
        if provider == .chatgptWeb {
            print("🟢 WebSyncEngine: ChatGPT lastSync=\(stored) existingCount=\(existingCount)")
        }
        #endif
        if existingCount == 0 {
            return nil
        }
        let adjusted = stored.addingTimeInterval(-syncLookbackSeconds)
        if adjusted.timeIntervalSince1970 < 0 {
            return Date(timeIntervalSince1970: 0)
        }
        return adjusted
    }

    private struct WebSyncResult {
        let stats: SyncStats
        let latestUpdatedAt: Date?
    }

    private func updateLastSyncDateIfAvailable(_ provider: Provider, latestUpdatedAt: Date?) {
        guard let latestUpdatedAt else { return }
        setLastSyncDate(provider, date: latestUpdatedAt)
    }

    private func ensureNotRateLimited(for provider: Provider) throws {
        if let until = backoffUntil[provider] {
            if until <= Date() {
                clearBackoff(for: provider)
                return
            }
            let retryAfter = until.timeIntervalSinceNow
            throw WebSyncError.rateLimited(retryAfter: retryAfter)
        }
    }

    private func recordFailure(for provider: Provider, error: Error) {
        let failures = (consecutiveFailures[provider] ?? 0) + 1
        consecutiveFailures[provider] = failures
        persistConsecutiveFailures()

        if let syncError = error as? WebSyncError,
           case let .rateLimited(retryAfter) = syncError {
            applyBackoff(for: provider, retryAfter: retryAfter)
        }
    }

    private func resetFailureState(for provider: Provider) {
        consecutiveFailures[provider] = 0
        persistConsecutiveFailures()
        clearBackoff(for: provider)
    }

    private func applyBackoff(for provider: Provider, retryAfter: TimeInterval?) {
        let delay = retryAfter ?? 60
        let until = Date().addingTimeInterval(max(delay, 5))
        backoffUntil[provider] = until
        persistBackoffUntil()
    }

    private func clearBackoff(for provider: Provider) {
        backoffUntil[provider] = nil
        persistBackoffUntil()
    }

    private func retrying<T>(
        provider: Provider,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var delay = baseRetryDelayNanos

        while true {
            try Task.checkCancellation()
            do {
                let result = try await operation()
                return result
            } catch let syncError as WebSyncError {
                if case let .rateLimited(retryAfter) = syncError {
                    applyBackoff(for: provider, retryAfter: retryAfter)
                    throw syncError
                }
                attempt += 1
                if attempt >= maxRetryAttempts {
                    throw syncError
                }
            } catch {
                attempt += 1
                if attempt >= maxRetryAttempts {
                    throw error
                }
            }

            let jitter = UInt64.random(in: 0...250_000_000)
            try await Task.sleep(nanoseconds: delay + jitter)
            delay = min(delay * 2, maxRetryDelayNanos)
        }
    }

    private func loadBackoffUntil() -> [Provider: Date] {
        guard let stored = UserDefaults.standard.dictionary(forKey: backoffDefaultsKey) as? [String: Double] else {
            return [:]
        }
        var result: [Provider: Date] = [:]
        for (key, timestamp) in stored {
            if let provider = Provider(rawValue: key) {
                result[provider] = Date(timeIntervalSince1970: timestamp)
            }
        }
        return result
    }

    private func persistBackoffUntil() {
        var stored: [String: Double] = [:]
        for (provider, date) in backoffUntil {
            stored[provider.rawValue] = date.timeIntervalSince1970
        }
        UserDefaults.standard.set(stored, forKey: backoffDefaultsKey)
    }

    private func loadConsecutiveFailures() -> [Provider: Int] {
        guard let stored = UserDefaults.standard.dictionary(forKey: failureDefaultsKey) as? [String: Int] else {
            return [:]
        }
        var result: [Provider: Int] = [:]
        for (key, value) in stored {
            if let provider = Provider(rawValue: key) {
                result[provider] = value
            }
        }
        return result
    }

    private func persistConsecutiveFailures() {
        var stored: [String: Int] = [:]
        for (provider, count) in consecutiveFailures {
            stored[provider.rawValue] = count
        }
        UserDefaults.standard.set(stored, forKey: failureDefaultsKey)
    }
}

// MARK: - Session Storage

final class SessionStorage {
    private var cookieCache: [Provider: [HTTPCookie]] = [:]
    private var pendingCookieData: [String: [[String: Any]]] = [:]  // In-memory storage during onboarding
    private let legacyCookieFileURL: URL
    private var hasMigrated = false

    /// When true, cookies are stored in memory only (no keychain access)
    /// Set to false after onboarding to persist to keychain
    var deferKeychainPersistence: Bool = true

    init() {
        // Legacy file path for migration
        let fileManager = FileManager.default
        let appSupportURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser
        let directoryURL = appSupportURL.appendingPathComponent("Retain", isDirectory: true)
        legacyCookieFileURL = directoryURL.appendingPathComponent("web-session-cookies.json")

        // NOTE: Migration deferred to first keychain access to avoid prompting during onboarding
        // migrateFromFileToKeychain() is called lazily in ensureMigrated()
    }

    /// Ensure migration has run before any keychain access
    private func ensureMigrated() {
        guard !hasMigrated else { return }
        hasMigrated = true
        migrateFromFileToKeychain()
    }

    /// Migrate cookies from legacy JSON file to Keychain
    private func migrateFromFileToKeychain() {
        // Check if legacy file exists
        guard FileManager.default.fileExists(atPath: legacyCookieFileURL.path) else { return }

        // Load from legacy file
        guard let data = try? Data(contentsOf: legacyCookieFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]],
              !json.isEmpty else {
            return
        }

        // Check if Keychain already has data (already migrated)
        if KeychainHelper.webSessionCookies != nil {
            // Already migrated, delete legacy file
            try? FileManager.default.removeItem(at: legacyCookieFileURL)
            return
        }

        // Migrate to Keychain
        if let encoded = try? JSONSerialization.data(withJSONObject: json),
           let jsonString = String(data: encoded, encoding: .utf8) {
            KeychainHelper.webSessionCookies = jsonString
        }

        // Delete legacy file after successful migration
        try? FileManager.default.removeItem(at: legacyCookieFileURL)
    }

    /// Store session cookies for a provider
    func storeCookies(_ cookies: [HTTPCookie], for provider: Provider) {
        cookieCache[provider] = cookies

        // Convert Date objects to TimeInterval for JSON serialization
        let cookieData = cookies.compactMap { cookie -> [String: Any]? in
            guard let properties = cookie.properties else { return nil }
            var stringDict: [String: Any] = [:]
            for (key, value) in properties {
                if let date = value as? Date {
                    stringDict[key.rawValue] = date.timeIntervalSince1970
                } else {
                    stringDict[key.rawValue] = value
                }
            }
            return stringDict
        }

        saveCookieData(cookieData, for: provider)
    }

    /// Get stored cookies for a provider
    func getCookies(for provider: Provider) -> [HTTPCookie] {
        if let cached = cookieCache[provider] {
            return cached
        }

        guard let cookieData = loadCookieData()[provider.rawValue] else { return [] }

        let dateKeys = Set([
            HTTPCookiePropertyKey.expires.rawValue,
            "Created"
        ])

        let cookies = cookieData.compactMap { dict -> HTTPCookie? in
            var propertyKeyDict: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in dict {
                if dateKeys.contains(key), let timestamp = value as? TimeInterval {
                    propertyKeyDict[HTTPCookiePropertyKey(key)] = Date(timeIntervalSince1970: timestamp)
                } else {
                    propertyKeyDict[HTTPCookiePropertyKey(key)] = value
                }
            }
            return HTTPCookie(properties: propertyKeyDict)
        }
        cookieCache[provider] = cookies
        return cookies
    }

    /// Check if valid session exists
    func hasValidSession(for provider: Provider) -> Bool {
        let cookies = getCookies(for: provider)
        let now = Date()
        let isValid = cookies.contains { cookie in
            guard let expires = cookie.expiresDate else { return true }
            return expires > now
        }
        if !isValid && !cookies.isEmpty {
            clearSession(for: provider)
        }
        return isValid
    }

    /// Clear session for a provider
    func clearSession(for provider: Provider) {
        cookieCache.removeValue(forKey: provider)
        var allData = loadCookieData()
        allData.removeValue(forKey: provider.rawValue)
        writeCookieData(allData)
    }

    private func loadCookieData() -> [String: [[String: Any]]] {
        // During onboarding, return in-memory data only (no keychain access)
        if deferKeychainPersistence {
            return pendingCookieData
        }

        // Ensure migration before keychain access (deferred from init to avoid onboarding prompt)
        ensureMigrated()
        // Load from Keychain
        guard let jsonString = KeychainHelper.webSessionCookies,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] else {
            return [:]
        }
        return json
    }

    private func saveCookieData(_ cookies: [[String: Any]], for provider: Provider) {
        // During onboarding, store in memory only
        if deferKeychainPersistence {
            pendingCookieData[provider.rawValue] = cookies
            return
        }

        var allData = loadCookieData()
        allData[provider.rawValue] = cookies
        writeCookieData(allData)
    }

    private func writeCookieData(_ data: [String: [[String: Any]]]) {
        guard let encoded = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: encoded, encoding: .utf8) else {
            return
        }
        KeychainHelper.webSessionCookies = jsonString
    }

    /// Persist any pending in-memory cookie data to keychain
    /// Call this after onboarding completes
    func persistPendingCookies() {
        guard !pendingCookieData.isEmpty else { return }

        // Merge with existing keychain data
        ensureMigrated()
        var allData: [String: [[String: Any]]] = [:]
        if let jsonString = KeychainHelper.webSessionCookies,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]] {
            allData = json
        }

        // Add pending data
        for (key, value) in pendingCookieData {
            allData[key] = value
        }

        writeCookieData(allData)
        pendingCookieData.removeAll()
    }
}

// MARK: - User Info

struct WebUserInfo {
    let email: String?
    let name: String?
    let organizationId: String?
}

// MARK: - Conversation Meta

struct ConversationMeta {
    let id: String
    let title: String?
    let createdAt: Date
    let updatedAt: Date
}
