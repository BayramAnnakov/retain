import Foundation

/// Handler for retain:// URL scheme deep linking
struct URLSchemeHandler {
    /// Supported routes for URL scheme navigation
    enum Route: Equatable {
        case conversation(UUID)
        case search(String)
        case learnings
        case sync

        var description: String {
            switch self {
            case .conversation(let id):
                return "conversation(\(id))"
            case .search(let query):
                return "search(\(query))"
            case .learnings:
                return "learnings"
            case .sync:
                return "sync"
            }
        }
    }

    /// Parse a URL into a route
    /// - Parameter url: The URL to parse (must have scheme "retain")
    /// - Returns: The parsed route, or nil if invalid
    static func parse(_ url: URL) -> Route? {
        guard url.scheme?.lowercased() == "retain" else {
            return nil
        }

        let host = url.host?.lowercased()

        switch host {
        case "conversation":
            // retain://conversation/{uuid}
            let pathComponents = url.pathComponents.filter { $0 != "/" }
            guard let uuidString = pathComponents.first,
                  let uuid = UUID(uuidString: uuidString) else {
                return nil
            }
            return .conversation(uuid)

        case "search":
            // retain://search?q={query}
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let queryItems = components.queryItems,
                  let query = queryItems.first(where: { $0.name == "q" })?.value,
                  !query.isEmpty else {
                return nil
            }
            return .search(query)

        case "learnings":
            // retain://learnings
            return .learnings

        case "sync":
            // retain://sync
            return .sync

        default:
            return nil
        }
    }

    /// Build a URL for a route
    /// - Parameter route: The route to build a URL for
    /// - Returns: The constructed URL
    static func buildURL(for route: Route) -> URL? {
        var components = URLComponents()
        components.scheme = "retain"

        switch route {
        case .conversation(let id):
            components.host = "conversation"
            components.path = "/\(id.uuidString)"

        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]

        case .learnings:
            components.host = "learnings"

        case .sync:
            components.host = "sync"
        }

        return components.url
    }
}
