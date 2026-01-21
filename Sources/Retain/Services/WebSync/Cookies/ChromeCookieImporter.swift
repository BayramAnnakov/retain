#if os(macOS)
import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3

/// Reads cookies from a local Chromium cookie DB (macOS).
///
/// Notes:
/// - Chromium stores cookie values in an SQLite DB, and most values are encrypted (`encrypted_value` starts
///   with `v10` on macOS). Decryption uses the "Chrome Safe Storage" password from the macOS Keychain and
///   AES-CBC + PBKDF2. This is inherently brittle across Chromium changes; keep it best-effort.
enum ChromeCookieImporter {
    private static let chromeSafeStorageKeyLock = NSLock()
    private nonisolated(unsafe) static var cachedChromeSafeStorageKey: Data?

    enum ImportError: LocalizedError {
        case cookieDBNotFound(path: String)
        case keychainDenied
        case sqliteFailed(message: String)

        var errorDescription: String? {
            switch self {
            case let .cookieDBNotFound(path): "Chromium Cookies DB not found at \(path)."
            case .keychainDenied: "macOS Keychain denied access to Chrome Safe Storage."
            case let .sqliteFailed(message): "Failed to read Chromium cookies: \(message)"
            }
        }
    }

    struct CookieRecord: Sendable {
        let hostKey: String
        let name: String
        let path: String
        let expiresUTC: Int64
        let isSecure: Bool
        let isHTTPOnly: Bool
        let value: String
    }

    static func availableStores(for browser: Browser, homeDirectories: [URL]) -> [BrowserCookieStore] {
        guard browser.engine == .chromium else { return [] }
        let labelPrefix = browser.displayName
        let roots = ChromiumProfileLocator
            .roots(for: [browser], homeDirectories: homeDirectories)
            .map(\.url)

        var candidates: [ChromeProfileCandidate] = []
        for root in roots {
            candidates.append(contentsOf: Self.chromeProfileCookieDBs(
                root: root,
                labelPrefix: labelPrefix,
                browser: browser))
        }
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.cookiesDB.path) }
            .map { candidate in
                BrowserCookieStore(
                    browser: candidate.browser,
                    profile: candidate.profile,
                    kind: candidate.kind,
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
        let chromeKey = try Self.chromeSafeStorageKey()
        return try Self.readCookiesFromLockedChromeDB(
            sourceDB: sourceDB,
            key: chromeKey,
            matchingDomains: domains,
            domainMatch: domainMatch)
    }

    // MARK: - DB copy helper

    private static func readCookiesFromLockedChromeDB(
        sourceDB: URL,
        key: Data,
        matchingDomains: [String],
        domainMatch: BrowserCookieDomainMatch) throws -> [CookieRecord]
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweet-cookie-kit-chrome-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let copiedDB = tempDir.appendingPathComponent("Cookies")
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
            key: key,
            matchingDomains: matchingDomains,
            domainMatch: domainMatch)
    }

    // MARK: - SQLite read

    private static func readCookies(
        fromDB path: String,
        key: Data,
        matchingDomains: [String],
        domainMatch: BrowserCookieDomainMatch) throws -> [CookieRecord]
    {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        let conditions = BrowserCookieDomainMatcher.sqlCondition(
            column: "host_key",
            patterns: matchingDomains,
            match: domainMatch)
        let sql = """
        SELECT host_key, name, path, expires_utc, is_secure, is_httponly, value, encrypted_value
        FROM cookies
        WHERE \(conditions)
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [CookieRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hostKey = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let path = String(cString: sqlite3_column_text(stmt, 2))
            let expires = sqlite3_column_int64(stmt, 3)
            let isSecure = sqlite3_column_int(stmt, 4) != 0
            let isHTTPOnly = sqlite3_column_int(stmt, 5) != 0

            let plain = Self.readTextColumn(stmt, index: 6)
            let enc = Self.readBlobColumn(stmt, index: 7)

            let value: String
            if let plain, !plain.isEmpty {
                value = plain
            } else if let enc, !enc.isEmpty, let decrypted = Self.decryptChromiumValue(enc, key: key) {
                value = decrypted
            } else {
                continue
            }

            out.append(CookieRecord(
                hostKey: hostKey,
                name: name,
                path: path,
                expiresUTC: expires,
                isSecure: isSecure,
                isHTTPOnly: isHTTPOnly,
                value: value))
        }
        return out
    }

    private static func readTextColumn(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func readBlobColumn(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }

    // MARK: - Keychain + crypto

    private static func chromeSafeStorageKey() throws -> Data {
        self.chromeSafeStorageKeyLock.lock()
        if let cached = self.cachedChromeSafeStorageKey {
            self.chromeSafeStorageKeyLock.unlock()
            return cached
        }
        self.chromeSafeStorageKeyLock.unlock()

        let labels: [(service: String, account: String)] = [
            ("Chrome Safe Storage", "Chrome"),
            ("Chromium Safe Storage", "Chromium"),
            ("Brave Safe Storage", "Brave"),
            ("Arc Safe Storage", "Arc"),
            ("Arc Safe Storage", "Arc Beta"),
            ("Arc Safe Storage", "Arc Canary"),
            ("ChatGPT Atlas Safe Storage", "ChatGPT Atlas"),
            ("ChatGPT Atlas Safe Storage", "com.openai.atlas"),
            ("com.openai.atlas Safe Storage", "com.openai.atlas"),
            ("Helium Safe Storage", "Helium"),
            ("net.imput.helium Safe Storage", "net.imput.helium"),
            ("Microsoft Edge Safe Storage", "Microsoft Edge"),
            ("Vivaldi Safe Storage", "Vivaldi"),
        ]

        if let context = Self.preflightSafeStoragePrompt(labels: labels) {
            BrowserCookieKeychainPromptHandler.handler?(context)
        }

        var password: String?
        for label in labels {
            let result = Self.findGenericPassword(
                service: label.service,
                account: label.account,
                allowInteraction: true)
            if let p = result.password {
                password = p
                break
            }
        }
        guard let password else { throw ImportError.keychainDenied }

        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength)
                }
            }
        }
        guard result == kCCSuccess else {
            throw ImportError.keychainDenied
        }

        self.chromeSafeStorageKeyLock.lock()
        self.cachedChromeSafeStorageKey = key
        self.chromeSafeStorageKeyLock.unlock()
        return key
    }

    // Exposed for tests.
    static func decryptChromiumValue(_ encryptedValue: Data, key: Data) -> String? {
        guard encryptedValue.count > 3 else { return nil }
        let prefix = encryptedValue.prefix(3)
        let prefixString = String(data: prefix, encoding: .utf8)
        let payload = encryptedValue.dropFirst(3)

        if prefixString != "v10" {
            return nil
        }

        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        var outLength: size_t = 0
        let outCapacity = out.count

        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress,
                            payload.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLength

        let candidate = out.count > 32 ? out.dropFirst(32) : out[...]
        if let decoded = String(data: Data(candidate), encoding: .utf8) {
            return Self.cleanValue(decoded)
        }
        if let decoded = String(data: out, encoding: .utf8) {
            return Self.cleanValue(decoded)
        }
        return nil
    }

    private static func cleanValue(_ value: String) -> String {
        var i = value.startIndex
        while i < value.endIndex, value[i].unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
            i = value.index(after: i)
        }
        return String(value[i...])
    }

    private static func preflightSafeStoragePrompt(
        labels: [(service: String, account: String)]) -> BrowserCookieKeychainPromptContext?
    {
        for label in labels {
            let result = Self.findGenericPassword(
                service: label.service,
                account: label.account,
                allowInteraction: false)
            switch result.status {
            case errSecSuccess:
                if result.password != nil { return nil }
            case errSecInteractionNotAllowed:
                return BrowserCookieKeychainPromptContext(
                    service: label.service,
                    account: label.account,
                    label: label.service)
            default:
                continue
            }
        }
        return nil
    }

    private static func findGenericPassword(
        service: String,
        account: String,
        allowInteraction: Bool) -> (status: OSStatus, password: String?)
    {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let data = result as? Data else { return (status, nil) }
        let password = String(data: data, encoding: .utf8)
        return (status, password)
    }

    // MARK: - Profile discovery

    private struct ChromeProfileCandidate: Sendable {
        let browser: Browser
        let profile: BrowserProfile
        let kind: BrowserCookieStoreKind
        let label: String
        let cookiesDB: URL
    }

    private static func chromeProfileCookieDBs(
        root: URL,
        labelPrefix: String,
        browser: Browser) -> [ChromeProfileCandidate]
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
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return profileDirs.flatMap { dir in
            let profileName = dir.lastPathComponent
            let profile = BrowserProfile(id: dir.path, name: profileName)
            let labelBase = "\(labelPrefix) \(profileName)"
            let cookiesDB = dir.appendingPathComponent("Cookies")
            let networkCookiesDB = dir.appendingPathComponent("Network").appendingPathComponent("Cookies")
            return [
                ChromeProfileCandidate(
                    browser: browser,
                    profile: profile,
                    kind: .network,
                    label: "\(labelBase) (Network)",
                    cookiesDB: networkCookiesDB),
                ChromeProfileCandidate(
                    browser: browser,
                    profile: profile,
                    kind: .primary,
                    label: labelBase,
                    cookiesDB: cookiesDB),
            ]
        }
    }

}
#endif
