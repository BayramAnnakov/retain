import Foundation

struct ScanScope: Equatable {
    var timeWindowDays: Int?  // nil = all time
    var projectPath: String?  // nil = all projects
    var providers: Set<Provider>  // empty = all providers

    static let all = ScanScope(timeWindowDays: nil, projectPath: nil, providers: [])
}
