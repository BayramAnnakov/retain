import Foundation

#if os(macOS)

/// Supported browsers for cookie extraction on macOS.
///
/// Use this to pick a cookie source (for example `.safari` or `.chrome`) when calling
/// ``BrowserCookieClient`` APIs.
public enum Browser: String, Sendable, Hashable, CaseIterable {
    case safari
    case chrome
    case chromeBeta
    case chromeCanary
    case arc
    case arcBeta
    case arcCanary
    case chatgptAtlas
    case chromium
    case firefox
    case brave
    case braveBeta
    case braveNightly
    case edge
    case edgeBeta
    case edgeCanary
    case helium
    case vivaldi

    /// Display name for UI or logs.
    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .chromeBeta: "Chrome Beta"
        case .chromeCanary: "Chrome Canary"
        case .arc: "Arc"
        case .arcBeta: "Arc Beta"
        case .arcCanary: "Arc Canary"
        case .chatgptAtlas: "ChatGPT Atlas"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .brave: "Brave"
        case .braveBeta: "Brave Beta"
        case .braveNightly: "Brave Nightly"
        case .edge: "Microsoft Edge"
        case .edgeBeta: "Microsoft Edge Beta"
        case .edgeCanary: "Microsoft Edge Canary"
        case .helium: "Helium"
        case .vivaldi: "Vivaldi"
        }
    }

    /// Preferred order to search for cookies when no user preference exists.
    /// Try all supported browsers by default; callers can pass a smaller list.
    public static let defaultImportOrder: [Browser] = [
        .safari,
        .chrome,
        .edge,
        .brave,
        .arc,
        .chatgptAtlas,
        .chromium,
        .helium,
        .vivaldi,
        .firefox,
        .chromeBeta,
        .chromeCanary,
        .arcBeta,
        .arcCanary,
        .braveBeta,
        .braveNightly,
        .edgeBeta,
        .edgeCanary,
    ]

    var engine: BrowserEngine {
        switch self {
        case .safari:
            .webkit
        case .firefox:
            .firefox
        default:
            .chromium
        }
    }
}

enum BrowserEngine: Sendable {
    case webkit
    case chromium
    case firefox
}

/// Defaults for browser selection.
public enum BrowserCookieDefaults {
    /// Preferred order to search for cookies when no user preference exists.
    public static let importOrder: [Browser] = Browser.defaultImportOrder
}

/// Chromium profile root locations for supported browsers.
public struct ChromiumProfileRoot: Sendable {
    public let browser: Browser
    public let url: URL

    public var labelPrefix: String { self.browser.displayName }

    public init(browser: Browser, url: URL) {
        self.browser = browser
        self.url = url
    }
}

public enum ChromiumProfileLocator {
    /// Returns Chromium profile roots for the given browsers and home directories.
    public static func roots(
        for browsers: [Browser] = Browser.defaultImportOrder,
        homeDirectories: [URL] = BrowserCookieClient.defaultHomeDirectories()) -> [ChromiumProfileRoot]
    {
        let homes = self.uniqueHomes(homeDirectories)
        let chromiumBrowsers = browsers.filter { $0.engine == .chromium }

        var roots: [ChromiumProfileRoot] = []
        roots.reserveCapacity(homes.count * chromiumBrowsers.count)
        for home in homes {
            let appSupport = home
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
            for browser in chromiumBrowsers {
                guard let relative = self.chromiumRelativePath(for: browser) else { continue }
                roots.append(ChromiumProfileRoot(
                    browser: browser,
                    url: appSupport.appendingPathComponent(relative)))
            }
        }
        return roots
    }

    static func chromiumRelativePath(for browser: Browser) -> String? {
        switch browser {
        case .chrome:
            "Google/Chrome"
        case .chromeBeta:
            "Google/Chrome Beta"
        case .chromeCanary:
            "Google/Chrome Canary"
        case .arc:
            "Arc/User Data"
        case .arcBeta:
            "Arc Beta/User Data"
        case .arcCanary:
            "Arc Canary/User Data"
        case .chatgptAtlas:
            "com.openai.atlas/browser-data/host"
        case .chromium:
            "Chromium"
        case .helium:
            "net.imput.helium"
        case .brave:
            "BraveSoftware/Brave-Browser"
        case .braveBeta:
            "BraveSoftware/Brave-Browser-Beta"
        case .braveNightly:
            "BraveSoftware/Brave-Browser-Nightly"
        case .edge:
            "Microsoft Edge"
        case .edgeBeta:
            "Microsoft Edge Beta"
        case .edgeCanary:
            "Microsoft Edge Canary"
        case .vivaldi:
            "Vivaldi"
        case .safari, .firefox:
            nil
        }
    }

    private static func uniqueHomes(_ homes: [URL]) -> [URL] {
        var seen = Set<String>()
        return homes.filter { home in
            let path = home.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }
}

extension Collection<Browser> {
    /// Human-readable label (for settings UI).
    public var displayLabel: String {
        map(\.displayName).joined(separator: " -> ")
    }

    /// Short label (for compact UI).
    public var shortLabel: String {
        map(\.displayName).joined(separator: "/")
    }

    /// Hint for user-facing login prompts.
    public var loginHint: String {
        let names = map(\.displayName)
        guard let last = names.last else { return "browser" }
        if names.count == 1 { return last }
        if names.count == 2 { return "\(names[0]) or \(last)" }
        return "\(names.dropLast().joined(separator: ", ")), or \(last)"
    }
}

/// Domain matching strategy for cookie queries.
public enum BrowserCookieDomainMatch: Sendable {
    /// Match when the cookie's domain contains the pattern.
    case contains
    /// Match when the cookie's domain ends with the pattern (suffix match).
    case suffix
    /// Match when the cookie's domain exactly matches the pattern.
    case exact
}

/// Custom resolver that maps domain -> origin URL.
public enum BrowserCookieOriginStrategy: Sendable {
    /// Use `https://{domain}`.
    case domainBased
    /// Always use the provided origin URL.
    case fixed(URL)
    /// Custom resolver that maps domain -> origin URL.
    case custom(@Sendable (String) -> URL?)

    func resolve(domain: String) -> URL? {
        switch self {
        case .domainBased:
            URL(string: "https://\(domain)")
        case let .fixed(url):
            url
        case let .custom(resolver):
            resolver(domain)
        }
    }
}

/// Query definition for fetching browser cookies.
public struct BrowserCookieQuery: Sendable {
    /// Domain patterns to match (empty = no filtering).
    public var domains: [String]
    /// Matching strategy for domains.
    public var domainMatch: BrowserCookieDomainMatch
    /// Origin URL resolver for building `HTTPCookie` values.
    public var origin: BrowserCookieOriginStrategy
    /// Include expired cookies when true.
    public var includeExpired: Bool
    /// Reference date used to filter expired cookies.
    public var referenceDate: Date

    /// Creates a query for filtering and converting cookies.
    /// - Parameters:
    ///   - domains: Domain patterns to match (empty = no filtering).
    ///   - domainMatch: Domain matching strategy for `domains`.
    ///   - origin: Origin URL strategy used when converting to `HTTPCookie`.
    ///   - includeExpired: Whether expired cookies should be included.
    ///   - referenceDate: "Now" date used to filter expired cookies when `includeExpired == false`.
    public init(
        domains: [String] = [],
        domainMatch: BrowserCookieDomainMatch = .contains,
        origin: BrowserCookieOriginStrategy = .domainBased,
        includeExpired: Bool = false,
        referenceDate: Date = Date())
    {
        self.domains = domains
        self.domainMatch = domainMatch
        self.origin = origin
        self.includeExpired = includeExpired
        self.referenceDate = referenceDate
    }
}

/// A browser profile identifier.
public struct BrowserProfile: Sendable, Hashable {
    /// Stable identifier for the profile (often a filesystem path or derived key).
    public let id: String
    /// Human-readable profile name.
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which cookie store a browser profile represents.
public enum BrowserCookieStoreKind: String, Sendable {
    /// Primary/regular cookie database for a profile.
    case primary
    /// Auxiliary store used by some Chromium variants (e.g. "Network" cookies).
    case network
    /// Safari cookie store.
    case safari
}

/// A concrete cookie store for a browser profile.
public struct BrowserCookieStore: Sendable, Hashable {
    /// Browser family and distribution.
    public let browser: Browser
    /// Browser profile metadata.
    public let profile: BrowserProfile
    /// Cookie store kind (e.g., primary vs network).
    public let kind: BrowserCookieStoreKind
    /// Human-readable label for UI or logs.
    public let label: String
    /// Backing cookie database URL when applicable.
    public let databaseURL: URL?

    public init(
        browser: Browser,
        profile: BrowserProfile,
        kind: BrowserCookieStoreKind,
        label: String,
        databaseURL: URL?)
    {
        self.browser = browser
        self.profile = profile
        self.kind = kind
        self.label = label
        self.databaseURL = databaseURL
    }
}

/// A browser cookie record normalized for cross-browser handling.
public struct BrowserCookieRecord: Sendable {
    /// Cookie domain (normalized; leading dot removed).
    public let domain: String
    public let name: String
    public let path: String
    public let value: String
    /// Cookie expiry date, or `nil` for session cookies.
    public let expires: Date?
    public let isSecure: Bool
    public let isHTTPOnly: Bool

    public init(
        domain: String,
        name: String,
        path: String,
        value: String,
        expires: Date?,
        isSecure: Bool,
        isHTTPOnly: Bool)
    {
        self.domain = domain
        self.name = name
        self.path = path
        self.value = value
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }
}

/// Cookie records loaded from a specific browser store.
public struct BrowserCookieStoreRecords: Sendable {
    /// Cookie store that produced these records.
    public let store: BrowserCookieStore
    /// Cookie records from the store.
    public let records: [BrowserCookieRecord]

    public init(store: BrowserCookieStore, records: [BrowserCookieRecord]) {
        self.store = store
        self.records = records
    }

    /// Convenience access to the store label.
    public var label: String {
        self.store.label
    }

    /// Convenience access to the store's browser.
    public var browser: Browser {
        self.store.browser
    }

    /// Converts the contained records into `HTTPCookie` values.
    /// - Parameter origin: Origin URL strategy used when building `HTTPCookie`.
    public func cookies(origin: BrowserCookieOriginStrategy = .domainBased) -> [HTTPCookie] {
        BrowserCookieClient.makeHTTPCookies(self.records, origin: origin)
    }
}

/// Errors raised when reading browser cookies.
public enum BrowserCookieError: LocalizedError, Sendable {
    /// No cookie store found for the requested browser.
    case notFound(browser: Browser, details: String)
    /// Access denied (for example Full Disk Access / Keychain denied).
    case accessDenied(browser: Browser, details: String)
    /// Store found but loading/parsing failed.
    case loadFailed(browser: Browser, details: String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(_, details), let .accessDenied(_, details), let .loadFailed(_, details):
            details
        }
    }

    /// Browser that produced the error.
    public var browser: Browser {
        switch self {
        case let .notFound(browser, _), let .accessDenied(browser, _), let .loadFailed(browser, _):
            browser
        }
    }

    /// Optional guidance for user-facing permission errors.
    public var accessDeniedHint: String? {
        switch self {
        case let .accessDenied(_, details):
            details
        case .notFound, .loadFailed:
            nil
        }
    }
}

/// Context for a Keychain prompt triggered by Chromium cookie decryption.
public struct BrowserCookieKeychainPromptContext: Sendable {
    public let service: String
    public let account: String
    public let label: String

    public init(service: String, account: String, label: String) {
        self.service = service
        self.account = account
        self.label = label
    }
}

public enum BrowserCookieKeychainPromptHandler {
    public static var handler: ((BrowserCookieKeychainPromptContext) -> Void)?
}

#endif
