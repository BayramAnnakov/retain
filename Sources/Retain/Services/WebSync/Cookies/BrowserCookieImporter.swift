import Foundation

#if os(macOS)

/// High-level API for enumerating and reading browser cookies.
///
/// This API is best-effort: browsers can change formats, cookies may be locked by a running process,
/// and macOS privacy controls (Full Disk Access / Keychain prompts) can block reads.
public struct BrowserCookieClient: Sendable {
    /// Configuration for store discovery and cookie loading.
    public struct Configuration: Sendable {
        /// Candidate home directories used to locate browser profile folders.
        ///
        /// Defaults to common sources such as `FileManager.default.homeDirectoryForCurrentUser` and `$HOME`.
        public var homeDirectories: [URL]

        public init(homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()) {
            self.homeDirectories = homeDirectories
        }
    }

    /// Current configuration used by the client.
    public let configuration: Configuration

    /// Creates a cookie client.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Returns cookie stores for a specific browser (profile + store kind).
    /// - Parameter browser: Browser to enumerate.
    /// - Returns: Stores for the browser (often one per profile).
    public func stores(for browser: Browser) -> [BrowserCookieStore] {
        switch browser.engine {
        case .webkit:
            let profile = BrowserProfile(id: "safari.default", name: "Default")
            return [BrowserCookieStore(
                browser: .safari,
                profile: profile,
                kind: .safari,
                label: "Safari",
                databaseURL: nil)]
        case .chromium:
            return ChromeCookieImporter.availableStores(
                for: browser,
                homeDirectories: self.configuration.homeDirectories)
        case .firefox:
            return FirefoxCookieImporter.availableStores(homeDirectories: self.configuration.homeDirectories)
        }
    }

    /// Returns cookie stores for multiple browsers.
    /// - Parameter browsers: Browsers to enumerate.
    public func stores(in browsers: [Browser]) -> [BrowserCookieStore] {
        browsers.flatMap { self.stores(for: $0) }
    }

    /// Loads cookie records from multiple browsers.
    /// - Parameters:
    ///   - query: Filter for domains/expiry.
    ///   - browsers: Browsers to load from.
    ///   - logger: Optional logger for diagnostic messages (paths, failures, fallbacks).
    /// - Returns: Records grouped per browser profile/store.
    public func records(
        matching query: BrowserCookieQuery,
        in browsers: [Browser],
        logger: ((String) -> Void)? = nil) throws -> [BrowserCookieStoreRecords]
    {
        try browsers.flatMap { try self.records(matching: query, in: $0, logger: logger) }
    }

    /// Loads cookie records from a specific browser.
    /// - Parameters:
    ///   - query: Filter for domains/expiry.
    ///   - browser: Browser to load from.
    ///   - logger: Optional logger for diagnostic messages (paths, failures, fallbacks).
    /// - Returns: Records grouped per browser profile/store.
    public func records(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        logger: ((String) -> Void)? = nil) throws -> [BrowserCookieStoreRecords]
    {
        let stores = self.stores(for: browser)
        if stores.isEmpty {
            throw BrowserCookieError.notFound(
                browser: browser,
                details: "\(browser.displayName) cookie store not found.")
        }
        return try stores.compactMap { store in
            let records = try self.records(matching: query, in: store, logger: logger)
            guard !records.isEmpty else { return nil }
            return BrowserCookieStoreRecords(store: store, records: records)
        }
    }

    /// Loads cookie records from a specific cookie store.
    /// - Parameters:
    ///   - query: Filter for domains/expiry.
    ///   - store: Cookie store to load from.
    ///   - logger: Optional logger for diagnostic messages (paths, failures, fallbacks).
    public func records(
        matching query: BrowserCookieQuery,
        in store: BrowserCookieStore,
        logger: ((String) -> Void)? = nil) throws -> [BrowserCookieRecord]
    {
        let records: [BrowserCookieRecord]
        switch store.browser.engine {
        case .webkit:
            do {
                let loaded = try SafariCookieImporter.loadCookies(
                    matchingDomains: query.domains,
                    domainMatch: query.domainMatch,
                    homeDirectories: self.configuration.homeDirectories,
                    logger: logger)
                records = loaded.map { record in
                    BrowserCookieRecord(
                        domain: BrowserCookieDomainMatcher.normalizeDomain(record.domain),
                        name: record.name,
                        path: record.path,
                        value: record.value,
                        expires: record.expires,
                        isSecure: record.isSecure,
                        isHTTPOnly: record.isHTTPOnly)
                }
            } catch let error as SafariCookieImporter.ImportError {
                throw BrowserCookieError.mapSafariError(error, browser: store.browser)
            } catch {
                throw BrowserCookieError.loadFailed(
                    browser: store.browser,
                    details: "Safari cookie load failed: \(error.localizedDescription)")
            }
        case .chromium:
            do {
                let loaded = try ChromeCookieImporter.loadCookies(
                    from: store,
                    matchingDomains: query.domains,
                    domainMatch: query.domainMatch)
                records = loaded.map { record in
                    BrowserCookieRecord(
                        domain: BrowserCookieDomainMatcher.normalizeDomain(record.hostKey),
                        name: record.name,
                        path: record.path,
                        value: record.value,
                        expires: BrowserCookieDomainMatcher.chromeExpiryDate(expiresUTC: record.expiresUTC),
                        isSecure: record.isSecure,
                        isHTTPOnly: record.isHTTPOnly)
                }
            } catch let error as ChromeCookieImporter.ImportError {
                throw BrowserCookieError.mapChromeError(error, browser: store.browser)
            } catch {
                throw BrowserCookieError.loadFailed(
                    browser: store.browser,
                    details: "\(store.browser.displayName) cookie load failed: \(error.localizedDescription)")
            }
        case .firefox:
            do {
                let loaded = try FirefoxCookieImporter.loadCookies(
                    from: store,
                    matchingDomains: query.domains,
                    domainMatch: query.domainMatch)
                records = loaded.map { record in
                    BrowserCookieRecord(
                        domain: BrowserCookieDomainMatcher.normalizeDomain(record.host),
                        name: record.name,
                        path: record.path,
                        value: record.value,
                        expires: record.expires,
                        isSecure: record.isSecure,
                        isHTTPOnly: record.isHTTPOnly)
                }
            } catch let error as FirefoxCookieImporter.ImportError {
                throw BrowserCookieError.mapFirefoxError(error, browser: store.browser)
            } catch {
                throw BrowserCookieError.loadFailed(
                    browser: store.browser,
                    details: "Firefox cookie load failed: \(error.localizedDescription)")
            }
        }

        return BrowserCookieDomainMatcher.filterExpired(
            records,
            includeExpired: query.includeExpired,
            now: query.referenceDate)
    }

    /// Loads `HTTPCookie` values from a specific cookie store.
    /// - Parameters:
    ///   - query: Filter + conversion settings.
    ///   - store: Cookie store to load from.
    ///   - logger: Optional logger for diagnostic messages (paths, failures, fallbacks).
    /// - Returns: `HTTPCookie` values converted from loaded records.
    public func cookies(
        matching query: BrowserCookieQuery,
        in store: BrowserCookieStore,
        logger: ((String) -> Void)? = nil) throws -> [HTTPCookie]
    {
        let records = try self.records(matching: query, in: store, logger: logger)
        return Self.makeHTTPCookies(records, origin: query.origin)
    }

    /// Loads `HTTPCookie` values from multiple browser stores.
    /// - Parameters:
    ///   - query: Filter + conversion settings.
    ///   - browser: Browser to load from.
    ///   - logger: Optional logger for diagnostic messages (paths, failures, fallbacks).
    public func cookies(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        logger: ((String) -> Void)? = nil) throws -> [HTTPCookie]
    {
        let sources = try self.records(matching: query, in: browser, logger: logger)
        return sources.flatMap { $0.cookies(origin: query.origin) }
    }

    /// Loads `HTTPCookie` values from multiple browsers.
    /// - Parameters:
    ///   - query: Filter + conversion settings.
    ///   - browsers: Browsers to load from.
    ///   - logger: Optional logger for diagnostic messages (paths, failures, fallbacks).
    public func cookies(
        matching query: BrowserCookieQuery,
        in browsers: [Browser],
        logger: ((String) -> Void)? = nil) throws -> [HTTPCookie]
    {
        let sources = try self.records(matching: query, in: browsers, logger: logger)
        return sources.flatMap { $0.cookies(origin: query.origin) }
    }

    /// Convert cookie records into `HTTPCookie` values.
    /// - Parameters:
    ///   - records: Normalized cookie records.
    ///   - origin: Origin URL strategy used when building `HTTPCookie`.
    /// - Returns: Best-effort `HTTPCookie` values (records with invalid domains are dropped).
    public static func makeHTTPCookies(
        _ records: [BrowserCookieRecord],
        origin: BrowserCookieOriginStrategy = .domainBased) -> [HTTPCookie]
    {
        records.compactMap { record in
            let domain = BrowserCookieDomainMatcher.normalizeDomain(record.domain)
            guard !domain.isEmpty else { return nil }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: record.path,
                .name: record.name,
                .value: record.value,
                .secure: record.isSecure,
            ]
            if let originURL = origin.resolve(domain: domain) {
                props[.originURL] = originURL
            }
            if record.isHTTPOnly {
                props[.init("HttpOnly")] = "TRUE"
            }
            if let expires = record.expires {
                props[.expires] = expires
            }
            return HTTPCookie(properties: props)
        }
    }

    /// Default home directories used when searching for browser profiles.
    public static func defaultHomeDirectories() -> [URL] {
        var homes: [URL] = []
        homes.append(FileManager.default.homeDirectoryForCurrentUser)
        if let userHome = NSHomeDirectoryForUser(NSUserName()) {
            homes.append(URL(fileURLWithPath: userHome))
        }
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
            homes.append(URL(fileURLWithPath: envHome))
        }
        var seen = Set<String>()
        return homes.filter { home in
            let path = home.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }
}

enum BrowserCookieDomainMatcher {
    static func normalizeDomain(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") { return String(trimmed.dropFirst()) }
        return trimmed
    }

    static func matches(domain: String, patterns: [String], match: BrowserCookieDomainMatch) -> Bool {
        guard !patterns.isEmpty else { return true }
        let haystack = self.normalizeDomain(domain).lowercased()
        return patterns.contains { pattern in
            let needle = self.normalizeDomain(pattern).lowercased()
            switch match {
            case .contains:
                return haystack.contains(needle)
            case .suffix:
                return haystack.hasSuffix(needle)
            case .exact:
                return haystack == needle
            }
        }
    }

    static func filterExpired(
        _ records: [BrowserCookieRecord],
        includeExpired: Bool,
        now: Date) -> [BrowserCookieRecord]
    {
        guard !includeExpired else { return records }
        return records.filter { record in
            guard let expires = record.expires else { return true }
            return expires >= now
        }
    }

    static func chromeExpiryDate(expiresUTC: Int64) -> Date? {
        guard expiresUTC > 0 else { return nil }
        let seconds = (Double(expiresUTC) / 1_000_000.0) - 11_644_473_600.0
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func sqlCondition(column: String, patterns: [String], match: BrowserCookieDomainMatch) -> String {
        guard !patterns.isEmpty else { return "1=1" }
        let clauses: [String] = patterns.map { raw in
            let value = self.escapeForSQL(raw)
            switch match {
            case .contains:
                return "\(column) LIKE '%\(value)%'"
            case .suffix:
                return "\(column) LIKE '%\(value)'"
            case .exact:
                let normalized = self.escapeForSQL(self.normalizeDomain(raw))
                return "(\(column) = '\(normalized)' OR \(column) = '.\(normalized)')"
            }
        }
        return clauses.joined(separator: " OR ")
    }

    static func escapeForSQL(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

extension BrowserCookieError {
    static func mapSafariError(_ error: SafariCookieImporter.ImportError, browser: Browser) -> BrowserCookieError {
        switch error {
        case .cookieFileNotFound:
            BrowserCookieError.notFound(browser: browser, details: error.localizedDescription)
        case .cookieFileNotReadable:
            BrowserCookieError.accessDenied(browser: browser, details: error.localizedDescription)
        case .invalidFile:
            BrowserCookieError.loadFailed(browser: browser, details: error.localizedDescription)
        }
    }

    static func mapChromeError(_ error: ChromeCookieImporter.ImportError, browser: Browser) -> BrowserCookieError {
        switch error {
        case .cookieDBNotFound:
            BrowserCookieError.notFound(browser: browser, details: error.localizedDescription)
        case .keychainDenied:
            BrowserCookieError.accessDenied(browser: browser, details: error.localizedDescription)
        case .sqliteFailed:
            BrowserCookieError.loadFailed(browser: browser, details: error.localizedDescription)
        }
    }

    static func mapFirefoxError(_ error: FirefoxCookieImporter.ImportError, browser: Browser) -> BrowserCookieError {
        switch error {
        case .cookieDBNotFound:
            BrowserCookieError.notFound(browser: browser, details: error.localizedDescription)
        case .cookieDBNotReadable:
            BrowserCookieError.accessDenied(browser: browser, details: error.localizedDescription)
        case .sqliteFailed:
            BrowserCookieError.loadFailed(browser: browser, details: error.localizedDescription)
        }
    }
}

#endif
