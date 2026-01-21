#if os(macOS)
import Foundation
import SQLite3

/// Reads cookies from Firefox profile cookie DBs (macOS).
enum FirefoxCookieImporter {
    enum ImportError: LocalizedError {
        case cookieDBNotFound(path: String)
        case cookieDBNotReadable(path: String)
        case sqliteFailed(message: String)

        var errorDescription: String? {
            switch self {
            case let .cookieDBNotFound(path): "Firefox cookie DB not found at \(path)."
            case let .cookieDBNotReadable(path):
                "Firefox cookie DB exists but is not readable (\(path))."
            case let .sqliteFailed(message): "Failed to read Firefox cookies: \(message)"
            }
        }
    }

    struct CookieRecord: Sendable {
        let host: String
        let name: String
        let path: String
        let value: String
        let expires: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool
    }

    static func availableStores(homeDirectories: [URL]) -> [BrowserCookieStore] {
        let roots: [URL] = homeDirectories.map { home in
            home
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("Firefox")
                .appendingPathComponent("Profiles")
        }

        var candidates: [FirefoxProfileCandidate] = []
        for root in roots {
            candidates.append(contentsOf: Self.firefoxProfileCookieDBs(
                root: root,
                labelPrefix: "Firefox",
                browser: .firefox))
        }
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.cookiesDB.path) }
            .map { candidate in
                BrowserCookieStore(
                    browser: candidate.browser,
                    profile: candidate.profile,
                    kind: .primary,
                    label: candidate.label,
                    databaseURL: candidate.cookiesDB)
            }
    }

    static func loadCookies(
        from store: BrowserCookieStore,
        matchingDomains domains: [String],
        domainMatch: BrowserCookieDomainMatch) throws -> [CookieRecord]
    {
        guard let sourceDB = store.databaseURL else {
            throw ImportError.cookieDBNotFound(path: "Missing cookie DB for \(store.label)")
        }
        return try Self.readCookiesFromLockedFirefoxDB(
            sourceDB: sourceDB,
            matchingDomains: domains,
            domainMatch: domainMatch)
    }

    // MARK: - DB copy helper

    private static func readCookiesFromLockedFirefoxDB(
        sourceDB: URL,
        matchingDomains: [String],
        domainMatch: BrowserCookieDomainMatch) throws -> [CookieRecord]
    {
        guard FileManager.default.isReadableFile(atPath: sourceDB.path) else {
            throw ImportError.cookieDBNotReadable(path: sourceDB.path)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweet-cookie-kit-firefox-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let copiedDB = tempDir.appendingPathComponent("cookies.sqlite")
        try FileManager.default.copyItem(at: sourceDB, to: copiedDB)

        for suffix in ["-wal", "-shm"] {
            let src = URL(fileURLWithPath: sourceDB.path + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                let dst = URL(fileURLWithPath: copiedDB.path + suffix)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }

        defer { try? FileManager.default.removeItem(at: tempDir) }

        return try Self.readCookies(
            fromDB: copiedDB.path,
            matchingDomains: matchingDomains,
            domainMatch: domainMatch)
    }

    // MARK: - SQLite read

    private static func readCookies(
        fromDB path: String,
        matchingDomains: [String],
        domainMatch: BrowserCookieDomainMatch) throws -> [CookieRecord]
    {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        let conditions = BrowserCookieDomainMatcher.sqlCondition(
            column: "host",
            patterns: matchingDomains,
            match: domainMatch)
        let sql = """
        SELECT host, name, path, value, expiry, isSecure, isHttpOnly
        FROM moz_cookies
        WHERE \(conditions)
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [CookieRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let host = Self.readTextColumn(stmt, index: 0),
                  let name = Self.readTextColumn(stmt, index: 1),
                  let path = Self.readTextColumn(stmt, index: 2),
                  let value = Self.readTextColumn(stmt, index: 3)
            else { continue }

            let expiry = sqlite3_column_int64(stmt, 4)
            let isSecure = sqlite3_column_int(stmt, 5) != 0
            let isHTTPOnly = sqlite3_column_int(stmt, 6) != 0

            let expiresDate = expiry > 0 ? Date(timeIntervalSince1970: TimeInterval(expiry)) : nil

            out.append(CookieRecord(
                host: BrowserCookieDomainMatcher.normalizeDomain(host),
                name: name,
                path: path,
                value: value,
                expires: expiresDate,
                isSecure: isSecure,
                isHTTPOnly: isHTTPOnly))
        }

        return out
    }

    private static func readTextColumn(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    // MARK: - Profile discovery

    private struct FirefoxProfileCandidate: Sendable {
        let browser: Browser
        let profile: BrowserProfile
        let label: String
        let cookiesDB: URL
    }

    private static func firefoxProfileCookieDBs(
        root: URL,
        labelPrefix: String,
        browser: Browser) -> [FirefoxProfileCandidate]
    {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileDirs = entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            return true
        }
        .sorted { lhs, rhs in
            let left = Self.profileSortKey(lhs.lastPathComponent)
            let right = Self.profileSortKey(rhs.lastPathComponent)
            if left.rank != right.rank { return left.rank < right.rank }
            return left.name < right.name
        }

        return profileDirs.map { dir in
            let profileName = dir.lastPathComponent
            let profile = BrowserProfile(id: dir.path, name: profileName)
            let label = "\(labelPrefix) \(profileName)"
            let cookiesDB = dir.appendingPathComponent("cookies.sqlite")
            return FirefoxProfileCandidate(browser: browser, profile: profile, label: label, cookiesDB: cookiesDB)
        }
    }

    private static func profileSortKey(_ name: String) -> (rank: Int, name: String) {
        let lower = name.lowercased()
        if lower.contains("default-release") { return (0, lower) }
        if lower.contains("default") { return (1, lower) }
        return (2, lower)
    }
}
#endif
