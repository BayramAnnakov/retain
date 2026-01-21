import SwiftUI
import Charts
import GRDB

/// Analytics dashboard showing conversation statistics
struct AnalyticsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var timeRange: TimeRange = .month
    @State private var activityMode: ActivityMode = .providerStack
    @State private var stats: AnalyticsStats?

    enum TimeRange: String, CaseIterable {
        case week = "7 Days"
        case month = "30 Days"
        case quarter = "90 Days"
        case year = "Year"
        case all = "All Time"

        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .year: return 365
            case .all: return nil
            }
        }
    }

    enum ActivityMode: String, CaseIterable {
        case providerStack = "Daily Provider Stack"
        case grid = "Activity Grid"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                HStack {
                    Text("Analytics")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Spacer()

                    Picker("Time Range", selection: $timeRange) {
                        ForEach(TimeRange.allCases, id: \.self) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 400)
                }
                .padding(.horizontal)

                if let stats = stats {
                    // Overview Cards
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        StatCard(
                            title: "Total Conversations",
                            value: "\(stats.totalConversations)",
                            icon: "bubble.left.and.bubble.right",
                            color: .blue
                        )

                        StatCard(
                            title: "Total Messages",
                            value: "\(stats.totalMessages)",
                            icon: "text.bubble",
                            color: .green
                        )

                        StatCard(
                            title: "Approved Learnings",
                            value: "\(stats.learningFunnel.approved)",
                            icon: "lightbulb",
                            color: .yellow
                        )

                        StatCard(
                            title: "Pending Review",
                            value: "\(stats.learningFunnel.pending)",
                            icon: "exclamationmark.bubble",
                            color: .orange
                        )

                        StatCard(
                            title: "Impact Index",
                            value: stats.impactIndex.estimatedHoursSavedFormatted,
                            icon: "bolt.fill",
                            color: .pink
                        )

                        StatCard(
                            title: "Active Days",
                            value: "\(stats.activeDays)",
                            icon: "calendar",
                            color: .purple
                        )
                    }
                    .padding(.horizontal)

                    // Charts Row
                    HStack(spacing: 16) {
                        // Activity Chart
                        GroupBox {
                            if activityMode == .grid {
                                ContributionGridView(days: stats.contributionDays)
                            } else {
                                DailyProviderStackView(data: stats.dailyActivityByProvider)
                            }
                        } label: {
                            HStack {
                                Text("Activity")
                                Spacer()
                                Picker("", selection: $activityMode) {
                                    ForEach(ActivityMode.allCases, id: \.self) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 240)
                                .labelsHidden()
                            }
                        }
                        .frame(maxWidth: .infinity)

                        // Provider Distribution
                        GroupBox("By Provider") {
                            if #available(macOS 14.0, *) {
                                Chart(stats.providerDistribution, id: \.provider) { item in
                                    SectorMark(
                                        angle: .value("Count", item.count),
                                        innerRadius: .ratio(0.5),
                                        angularInset: 2
                                    )
                                    .foregroundStyle(by: .value("Provider", item.provider.displayName))
                                    .cornerRadius(4)
                                }
                                .frame(height: 200)
                            } else {
                                ProviderList(distribution: stats.providerDistribution)
                            }
                        }
                        .frame(width: 300)
                    }
                    .padding(.horizontal)

                    // Learning Funnel + Repeatability
                    HStack(spacing: 16) {
                        GroupBox("Learning Funnel") {
                            LearningFunnelView(stats: stats.learningFunnel)
                                .frame(height: 200)
                        }
                        .frame(maxWidth: .infinity)

                        GroupBox("Repeatability Score") {
                            RepeatabilityScoreView(buckets: stats.repeatabilityBuckets)
                                .frame(height: 200)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal)

                    HStack(spacing: 16) {
                        GroupBox("Task-Type Affinity") {
                            TaskAffinityView(data: stats.taskAffinity)
                                .frame(height: 240)
                        }
                        .frame(maxWidth: .infinity)

                        GroupBox("Correction Rate") {
                            CorrectionRateView(data: stats.correctionRates)
                                .frame(height: 240)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal)

                    GroupBox("Prompt Style Fingerprints") {
                        PromptStyleView(rows: stats.promptStyles)
                            .padding(.vertical, 8)
                    }
                    .padding(.horizontal)

                    GroupBox("Time of Day Breakdown") {
                        TimeOfDayView(data: stats.hourlyActivity)
                            .padding(.vertical, 8)
                    }
                    .padding(.horizontal)

                    GroupBox("Consistency Trend") {
                        ConsistencyTrendView(points: stats.consistencyTrend)
                            .padding(.vertical, 8)
                    }
                    .padding(.horizontal)

                    GroupBox("Assistant Usage") {
                        AssistantUsageView(stats: stats.providerUsage)
                            .padding(.vertical, 8)
                    }
                    .padding(.horizontal)

                    // Top Projects
                    GroupBox("Most Active Projects") {
                        if stats.topProjects.isEmpty {
                            Text("No project data available")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(stats.topProjects.prefix(10), id: \.path) { project in
                                    ProjectRow(project: project)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal)

                    // Recent Conversations
                    GroupBox("Recent Conversations") {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(stats.recentConversations.prefix(5)) { conversation in
                                RecentConversationRow(conversation: conversation)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.horizontal)

                } else {
                    // Loading state with context
                    VStack(spacing: Spacing.md) {
                        ProgressView()
                            .scaleEffect(1.5)

                        Text("Analyzing Conversations")
                            .font(AppFont.headline)

                        Text("Processing \(appState.conversations.count) conversations...")
                            .font(AppFont.body)
                            .foregroundColor(AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.vertical)
        }
        .onAppear {
            loadStats()
        }
        .onChange(of: timeRange) { _, _ in
            loadStats()
        }
    }

    private func loadStats() {
        Task {
            stats = await calculateStats()
        }
    }

    private func calculateStats() async -> AnalyticsStats {
        let conversations = appState.conversations
        let cutoffDate = timeRange.days.map { Calendar.current.date(byAdding: .day, value: -$0, to: Date())! }

        let filteredConversations = cutoffDate.map { date in
            conversations.filter { $0.updatedAt >= date }
        } ?? conversations

        // Calculate daily activity
        var dailyActivity: [DailyActivity] = []
        var dailyActivityByProvider: [DailyActivityProvider] = []
        let calendar = Calendar.current
        let groupedByDay = Dictionary(grouping: filteredConversations) { conversation in
            calendar.startOfDay(for: conversation.updatedAt)
        }

        for (date, convs) in groupedByDay.sorted(by: { $0.key < $1.key }) {
            let messageCount = convs.reduce(0) { $0 + $1.messageCount }
            dailyActivity.append(DailyActivity(date: date, count: messageCount))

            let groupedByProvider = Dictionary(grouping: convs) { $0.provider }
            for (provider, providerConversations) in groupedByProvider {
                let providerCount = providerConversations.reduce(0) { $0 + $1.messageCount }
                dailyActivityByProvider.append(
                    DailyActivityProvider(date: date, provider: provider, count: providerCount)
                )
            }
        }

        let contributionDays = buildContributionDays(
            dailyActivity: dailyActivity,
            timeRange: timeRange,
            calendar: calendar
        )

        // Provider distribution
        var providerDistribution: [ProviderCount] = []
        for provider in Provider.allCases {
            let count = filteredConversations.filter { $0.provider == provider }.count
            if count > 0 {
                providerDistribution.append(ProviderCount(provider: provider, count: count))
            }
        }

        let messagesByProvider = Dictionary(grouping: filteredConversations, by: \.provider)
            .mapValues { $0.reduce(0) { $0 + $1.messageCount } }

        // Top projects
        var projectCounts: [String: Int] = [:]
        for conversation in filteredConversations {
            if let path = conversation.projectPath {
                let projectName = URL(fileURLWithPath: path).lastPathComponent
                projectCounts[projectName, default: 0] += conversation.messageCount
            }
        }
        let topProjects = projectCounts
            .map { ProjectStats(path: $0.key, messageCount: $0.value) }
            .sorted { $0.messageCount > $1.messageCount }

        let providerUsage = AnalyticsDataBuilder.buildProviderUsageStats(
            conversations: filteredConversations,
            calendar: calendar
        )

        let bucketSize = HeatmapBucketSize.from(timeRange: timeRange)

        let extras = await Task.detached {
            let database = AppDatabase.shared
            let learningFunnel = AnalyticsDataBuilder.fetchLearningFunnel(database: database, cutoffDate: cutoffDate)
            let workflowRuns = AnalyticsDataBuilder.fetchWorkflowRunCount(database: database, cutoffDate: cutoffDate)
            let repeatabilityBuckets = AnalyticsDataBuilder.fetchRepeatabilityBuckets(database: database, cutoffDate: cutoffDate)
            let impactIndex = ImpactIndexStats.build(
                approvedLearnings: learningFunnel.approved,
                workflowRuns: workflowRuns
            )
            let analysisLatency = AnalyticsDataBuilder.fetchAnalysisLatency(database: database, cutoffDate: cutoffDate)
            let taskAffinity = AnalyticsDataBuilder.fetchTaskAffinity(database: database, cutoffDate: cutoffDate)
            let correctionCounts = AnalyticsDataBuilder.fetchCorrectionCounts(database: database, cutoffDate: cutoffDate)
            let promptStyles = AnalyticsDataBuilder.fetchPromptStyles(database: database, cutoffDate: cutoffDate)
            let hourlyActivity = AnalyticsDataBuilder.fetchHourlyActivity(database: database, cutoffDate: cutoffDate)
            let consistencyTrend = AnalyticsDataBuilder.fetchConsistencyTrend(
                database: database,
                cutoffDate: cutoffDate,
                bucketSize: bucketSize
            )
            return (
                learningFunnel,
                repeatabilityBuckets,
                impactIndex,
                analysisLatency,
                taskAffinity,
                correctionCounts,
                promptStyles,
                hourlyActivity,
                consistencyTrend
            )
        }.value

        let correctionRates = Provider.allCases.compactMap { provider -> CorrectionRateRow? in
            let totalMessages = messagesByProvider[provider] ?? 0
            guard totalMessages > 0 else { return nil }
            let corrections = extras.5[provider] ?? 0
            let rate = Double(corrections) / Double(totalMessages) * 100.0
            return CorrectionRateRow(
                provider: provider,
                correctionCount: corrections,
                totalMessages: totalMessages,
                ratePer100: rate
            )
        }

        return AnalyticsStats(
            totalConversations: filteredConversations.count,
            totalMessages: filteredConversations.reduce(0) { $0 + $1.messageCount },
            activeDays: Set(filteredConversations.map { calendar.startOfDay(for: $0.updatedAt) }).count,
            dailyActivity: dailyActivity,
            dailyActivityByProvider: dailyActivityByProvider,
            contributionDays: contributionDays,
            providerDistribution: providerDistribution,
            topProjects: topProjects,
            recentConversations: Array(filteredConversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(10)),
            learningFunnel: extras.0,
            repeatabilityBuckets: extras.1,
            impactIndex: extras.2,
            providerUsage: providerUsage,
            analysisLatency: extras.3,
            taskAffinity: extras.4,
            correctionRates: correctionRates,
            promptStyles: extras.6,
            hourlyActivity: extras.7,
            consistencyTrend: extras.8
        )
    }

    private func buildContributionDays(
        dailyActivity: [DailyActivity],
        timeRange: TimeRange,
        calendar: Calendar
    ) -> [ContributionDay] {
        let endDate = calendar.startOfDay(for: Date())
        let maxDays = 365

        let rangeStart: Date
        let minGridDays = 84
        if let days = timeRange.days {
            let effectiveDays = max(days, minGridDays)
            let rawStart = calendar.date(byAdding: .day, value: -(effectiveDays - 1), to: endDate) ?? endDate
            rangeStart = calendar.startOfDay(for: rawStart)
        } else {
            let rawStart = calendar.date(byAdding: .day, value: -(maxDays - 1), to: endDate) ?? endDate
            rangeStart = calendar.startOfDay(for: rawStart)
        }

        let countsByDay = Dictionary(
            uniqueKeysWithValues: dailyActivity.map { (calendar.startOfDay(for: $0.date), $0.count) }
        )

        let alignedStart = alignToWeekStart(rangeStart, calendar: calendar)
        let alignedEnd = alignToWeekEnd(endDate, calendar: calendar)

        var output: [ContributionDay] = []
        var cursor = alignedStart
        while cursor <= alignedEnd {
            let day = calendar.startOfDay(for: cursor)
            let inRange = day >= rangeStart && day <= endDate
            let count = inRange ? (countsByDay[day] ?? 0) : 0
            output.append(ContributionDay(date: day, count: count, isInRange: inRange))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            if cursor == day {
                break
            }
        }

        return output
    }

    private func alignToWeekStart(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: date) ?? date
    }

    private func alignToWeekEnd(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let offset = (calendar.firstWeekday + 6 - weekday + 7) % 7
        return calendar.date(byAdding: .day, value: offset, to: date) ?? date
    }

}

// MARK: - Analytics Data Builder

enum AnalyticsDataBuilder {
    static func buildProviderUsageStats(
        conversations: [Conversation],
        calendar: Calendar
    ) -> [ProviderUsageStats] {
        let grouped = Dictionary(grouping: conversations, by: \.provider)
        return Provider.allCases.compactMap { provider in
            guard let items = grouped[provider], !items.isEmpty else { return nil }
            let messageCount = items.reduce(0) { $0 + $1.messageCount }
            let activeDays = Set(items.map { calendar.startOfDay(for: $0.updatedAt) }).count
            let averageMessages = items.isEmpty ? 0 : Double(messageCount) / Double(items.count)
            return ProviderUsageStats(
                provider: provider,
                conversationCount: items.count,
                messageCount: messageCount,
                averageMessages: averageMessages,
                activeDays: activeDays
            )
        }
    }

    static func fetchLearningFunnel(
        database: AppDatabase,
        cutoffDate: Date?
    ) -> LearningFunnelStats {
        do {
            return try database.dbWriter.read { db in
                var sql = "SELECT status, COUNT(*) as count FROM learnings"
                var args: [DatabaseValueConvertible] = []
                if let cutoffDate {
                    sql += " WHERE createdAt >= ?"
                    args.append(cutoffDate)
                }
                sql += " GROUP BY status"

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                var pending = 0
                var approved = 0
                var rejected = 0
                for row in rows {
                    let status: String = row["status"]
                    let count: Int = row["count"] ?? 0
                    switch status {
                    case LearningStatus.pending.rawValue:
                        pending = count
                    case LearningStatus.approved.rawValue:
                        approved = count
                    case LearningStatus.rejected.rawValue:
                        rejected = count
                    default:
                        continue
                    }
                }
                return LearningFunnelStats(pending: pending, approved: approved, rejected: rejected)
            }
        } catch {
            return LearningFunnelStats(pending: 0, approved: 0, rejected: 0)
        }
    }

    static func fetchWorkflowRunCount(
        database: AppDatabase,
        cutoffDate: Date?
    ) -> Int {
        do {
            return try database.dbWriter.read { db in
                var sql = """
                    SELECT COUNT(*) as count
                    FROM workflow_signatures ws
                    JOIN conversations c ON c.id = ws.conversationId
                    WHERE ws.action != 'prime'
                    """
                var args: [DatabaseValueConvertible] = []
                if let cutoffDate {
                    sql += " AND c.updatedAt >= ?"
                    args.append(cutoffDate)
                }
                return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
            }
        } catch {
            return 0
        }
    }

    static func fetchRepeatabilityBuckets(
        database: AppDatabase,
        cutoffDate: Date?
    ) -> [RepeatabilityBucket] {
        do {
            return try database.dbWriter.read { db in
                var sql = """
                    SELECT COUNT(*) as runCount
                    FROM workflow_signatures ws
                    JOIN conversations c ON c.id = ws.conversationId
                    WHERE ws.action != 'prime'
                    """
                var args: [DatabaseValueConvertible] = []
                if let cutoffDate {
                    sql += " AND c.updatedAt >= ?"
                    args.append(cutoffDate)
                }
                sql += " GROUP BY ws.signature HAVING COUNT(*) >= 3"

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                var buckets: [String: Int] = [:]

                for row in rows {
                    let runCount: Int = row["runCount"] ?? 0
                    let label: String
                    switch runCount {
                    case 3:
                        label = "3"
                    case 4:
                        label = "4"
                    case 5...6:
                        label = "5-6"
                    case 7...9:
                        label = "7-9"
                    default:
                        label = "10+"
                    }
                    buckets[label, default: 0] += 1
                }

                let order = ["3", "4", "5-6", "7-9", "10+"]
                return order.map { RepeatabilityBucket(label: $0, count: buckets[$0] ?? 0) }
            }
        } catch {
            return []
        }
    }

    static func fetchTaskAffinity(
        database: AppDatabase,
        cutoffDate: Date?
    ) -> [TaskAffinityDatum] {
        do {
            return try database.dbWriter.read { db in
                let maxActionsPerProvider = 4
                var sql = """
                    SELECT c.provider AS provider, ws.action AS action, COUNT(*) AS count
                    FROM workflow_signatures ws
                    JOIN conversations c ON c.id = ws.conversationId
                    WHERE ws.action != 'prime'
                    """
                var args: [DatabaseValueConvertible] = []
                if let cutoffDate {
                    sql += " AND c.updatedAt >= ?"
                    args.append(cutoffDate)
                }
                sql += " GROUP BY c.provider, ws.action"

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                var rawData: [(Provider, String, Int)] = []

                for row in rows {
                    guard let providerRaw: String = row["provider"],
                          let provider = Provider(rawValue: providerRaw) else { continue }
                    let action: String = row["action"] ?? ""
                    if action.isEmpty || action == "none" {
                        continue
                    }
                    let count: Int = row["count"] ?? 0
                    rawData.append((provider, action, count))
                }

                let grouped = Dictionary(grouping: rawData, by: { $0.0 })
                let topPerProvider = grouped.flatMap { _, items in
                    items.sorted { $0.2 > $1.2 }.prefix(maxActionsPerProvider)
                }

                return topPerProvider.map { TaskAffinityDatum(provider: $0.0, action: $0.1, count: $0.2) }
            }
        } catch {
            return []
        }
    }

    static func fetchCorrectionCounts(
        database: AppDatabase,
        cutoffDate: Date?
    ) -> [Provider: Int] {
        do {
            return try database.dbWriter.read { db in
                var sql = """
                    SELECT c.provider AS provider, COUNT(*) AS count
                    FROM learnings l
                    JOIN conversations c ON c.id = l.conversationId
                    WHERE l.type = ?
                    """
                var args: [DatabaseValueConvertible] = [LearningType.correction.rawValue]
                if let cutoffDate {
                    sql += " AND l.createdAt >= ?"
                    args.append(cutoffDate)
                }
                sql += " GROUP BY c.provider"

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                var counts: [Provider: Int] = [:]
                for row in rows {
                    guard let providerRaw: String = row["provider"],
                          let provider = Provider(rawValue: providerRaw) else { continue }
                    counts[provider] = row["count"] ?? 0
                }
                return counts
            }
        } catch {
            return [:]
        }
    }

    static func fetchPromptStyles(
        database: AppDatabase,
        cutoffDate: Date?
    ) -> [PromptStyleRow] {
        struct PromptAccumulator {
            var messageCount = 0
            var totalLength = 0
            var constraintHits = 0
            var codeHits = 0
        }

        do {
            return try database.dbWriter.read { db in
                var sql = """
                    SELECT c.provider AS provider, m.content AS content
                    FROM messages m
                    JOIN conversations c ON c.id = m.conversationId
                    WHERE m.role = ?
                    """
                var args: [DatabaseValueConvertible] = [Role.user.rawValue]
                if let cutoffDate {
                    sql += " AND m.timestamp >= ?"
                    args.append(cutoffDate)
                }

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                var accumulators: [Provider: PromptAccumulator] = [:]

                for row in rows {
                    guard let providerRaw: String = row["provider"],
                          let provider = Provider(rawValue: providerRaw),
                          let content: String = row["content"] else { continue }
                    var acc = accumulators[provider] ?? PromptAccumulator()
                    acc.messageCount += 1
                    acc.totalLength += content.count
                    if containsConstraint(content) {
                        acc.constraintHits += 1
                    }
                    if isCodeLike(content) {
                        acc.codeHits += 1
                    }
                    accumulators[provider] = acc
                }

                return accumulators.compactMap { provider, acc in
                    guard acc.messageCount > 0 else { return nil }
                    let average = Double(acc.totalLength) / Double(acc.messageCount)
                    let constraintRate = Double(acc.constraintHits) / Double(acc.messageCount)
                    let codeRate = Double(acc.codeHits) / Double(acc.messageCount)
                    return PromptStyleRow(
                        provider: provider,
                        messageCount: acc.messageCount,
                        averageLength: average,
                        constraintRate: constraintRate,
                        codeRate: codeRate
                    )
                }
                .sorted { $0.provider.displayName < $1.provider.displayName }
            }
        } catch {
            return []
        }
    }

    static func fetchHourlyActivity(
        database: AppDatabase,
        cutoffDate: Date?
    ) -> [HourlyActivityDatum] {
        do {
            return try database.dbWriter.read { db in
                var sql = """
                    SELECT c.provider AS provider, m.timestamp AS timestamp
                    FROM messages m
                    JOIN conversations c ON c.id = m.conversationId
                    WHERE m.role = ?
                    """
                var args: [DatabaseValueConvertible] = [Role.user.rawValue]
                if let cutoffDate {
                    sql += " AND m.timestamp >= ?"
                    args.append(cutoffDate)
                }

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                var counts: [Provider: [Int]] = [:]
                let calendar = Calendar.current

                for row in rows {
                    guard let providerRaw: String = row["provider"],
                          let provider = Provider(rawValue: providerRaw),
                          let timestamp: Date = row["timestamp"] else { continue }
                    let hour = calendar.component(.hour, from: timestamp)
                    var hours = counts[provider] ?? Array(repeating: 0, count: 24)
                    if hour >= 0 && hour < hours.count {
                        hours[hour] += 1
                    }
                    counts[provider] = hours
                }

                var output: [HourlyActivityDatum] = []
                for provider in Provider.allCases {
                    let hours = counts[provider] ?? Array(repeating: 0, count: 24)
                    for hour in 0..<hours.count {
                        output.append(
                            HourlyActivityDatum(hour: hour, provider: provider, count: hours[hour])
                        )
                    }
                }
                return output
            }
        } catch {
            return []
        }
    }

    static func fetchConsistencyTrend(
        database: AppDatabase,
        cutoffDate: Date?,
        bucketSize: HeatmapBucketSize
    ) -> [ConsistencyPoint] {
        do {
            return try database.dbWriter.read { db in
                let endDate = Date()
                let startDate = cutoffDate ?? Calendar.current.date(byAdding: .month, value: -6, to: endDate) ?? endDate
                let buckets = buildHeatmapBuckets(startDate: startDate, endDate: endDate, bucketSize: bucketSize)
                let bucketIndex = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { ($0.element.startDate, $0.offset) })

                func bucketStart(for date: Date) -> Date {
                    bucketSize.startDate(for: date)
                }

                var correctionCounts = Array(repeating: 0, count: buckets.count)
                var messageCounts = Array(repeating: 0, count: buckets.count)

                var correctionSQL = "SELECT createdAt FROM learnings WHERE type = ?"
                var correctionArgs: [DatabaseValueConvertible] = [LearningType.correction.rawValue]
                if let cutoffDate {
                    correctionSQL += " AND createdAt >= ?"
                    correctionArgs.append(cutoffDate)
                }
                let correctionRows = try Row.fetchAll(db, sql: correctionSQL, arguments: StatementArguments(correctionArgs))
                for row in correctionRows {
                    guard let date: Date = row["createdAt"] else { continue }
                    let start = bucketStart(for: date)
                    if let index = bucketIndex[start] {
                        correctionCounts[index] += 1
                    }
                }

                var messageSQL = "SELECT timestamp FROM messages"
                var messageArgs: [DatabaseValueConvertible] = []
                if let cutoffDate {
                    messageSQL += " WHERE timestamp >= ?"
                    messageArgs.append(cutoffDate)
                }
                let messageRows = try Row.fetchAll(db, sql: messageSQL, arguments: StatementArguments(messageArgs))
                for row in messageRows {
                    guard let date: Date = row["timestamp"] else { continue }
                    let start = bucketStart(for: date)
                    if let index = bucketIndex[start] {
                        messageCounts[index] += 1
                    }
                }

                var points: [ConsistencyPoint] = []
                for (index, bucket) in buckets.enumerated() {
                    let messages = messageCounts[index]
                    let corrections = correctionCounts[index]
                    let rate = messages > 0 ? Double(corrections) / Double(messages) * 100.0 : 0
                    points.append(
                        ConsistencyPoint(
                            date: bucket.startDate,
                            corrections: corrections,
                            totalMessages: messages,
                            ratePer100: rate
                        )
                    )
                }
                return points
            }
        } catch {
            return []
        }
    }

    private static func containsConstraint(_ content: String) -> Bool {
        let normalized = content.lowercased()
        let tokens = [
            "must ",
            "must\n",
            "don't ",
            "do not",
            "avoid ",
            "only ",
            "strict",
            "exact",
            "format",
            "json",
            "schema",
            "never ",
            "require "
        ]
        return tokens.contains(where: { normalized.contains($0) })
    }

    private static func isCodeLike(_ content: String) -> Bool {
        if content.contains("```") {
            return true
        }
        let normalized = content.lowercased()
        let keywordHits = [
            "import ",
            "class ",
            "func ",
            "def ",
            "let ",
            "var ",
            "const ",
            "=>"
        ]
        if keywordHits.contains(where: { normalized.contains($0) }) {
            return true
        }
        let symbols = content.filter { "{}[]();=<>".contains($0) }
        return symbols.count >= 10 && content.count >= 60
    }

    static func fetchAnalysisLatency(
        database: AppDatabase,
        cutoffDate: Date?
    ) -> AnalysisLatencyStats? {
        do {
            return try database.dbWriter.read { db in
                var sql = """
                    SELECT claimedAt, completedAt, status
                    FROM analysis_queue
                    WHERE claimedAt IS NOT NULL
                      AND completedAt IS NOT NULL
                    """
                var args: [DatabaseValueConvertible] = []
                if let cutoffDate {
                    sql += " AND completedAt >= ?"
                    args.append(cutoffDate)
                }

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                var durations: [TimeInterval] = []
                var failedCount = 0
                for row in rows {
                    if let status: String = row["status"], status == "failed" {
                        failedCount += 1
                    }
                    guard let claimedAt: Date = row["claimedAt"],
                          let completedAt: Date = row["completedAt"] else { continue }
                    durations.append(completedAt.timeIntervalSince(claimedAt))
                }

                guard !durations.isEmpty else { return nil }
                let totalRuns = durations.count
                let average = durations.reduce(0, +) / Double(totalRuns)
                let sorted = durations.sorted()
                let p95Index = max(0, Int(Double(sorted.count - 1) * 0.95))
                let p95 = sorted[p95Index]

                return AnalysisLatencyStats(
                    averageSeconds: average,
                    p95Seconds: p95,
                    totalRuns: totalRuns,
                    failedRuns: failedCount
                )
            }
        } catch {
            return nil
        }
    }

    private static func buildHeatmapBuckets(
        startDate: Date,
        endDate: Date,
        bucketSize: HeatmapBucketSize
    ) -> [HeatmapBucket] {
        var buckets: [HeatmapBucket] = []
        let calendar = Calendar.current
        var cursor = bucketSize.startDate(for: startDate)
        let formatter = bucketSize.labelFormatter

        while cursor <= endDate {
            let label = formatter.string(from: cursor)
            buckets.append(HeatmapBucket(startDate: cursor, label: label))
            cursor = bucketSize.nextDate(after: cursor, calendar: calendar)
        }

        return buckets
    }
}

// MARK: - Stats Model

struct AnalyticsStats {
    let totalConversations: Int
    let totalMessages: Int
    let activeDays: Int
    let dailyActivity: [DailyActivity]
    let dailyActivityByProvider: [DailyActivityProvider]
    let contributionDays: [ContributionDay]
    let providerDistribution: [ProviderCount]
    let topProjects: [ProjectStats]
    let recentConversations: [Conversation]
    let learningFunnel: LearningFunnelStats
    let repeatabilityBuckets: [RepeatabilityBucket]
    let impactIndex: ImpactIndexStats
    let providerUsage: [ProviderUsageStats]
    let analysisLatency: AnalysisLatencyStats?
    let taskAffinity: [TaskAffinityDatum]
    let correctionRates: [CorrectionRateRow]
    let promptStyles: [PromptStyleRow]
    let hourlyActivity: [HourlyActivityDatum]
    let consistencyTrend: [ConsistencyPoint]
}

struct DailyActivity: Identifiable {
    let id = UUID()
    let date: Date
    let count: Int
}

struct DailyActivityProvider: Identifiable {
    var id: String { "\(provider.rawValue)-\(date.timeIntervalSince1970)" }
    let date: Date
    let provider: Provider
    let count: Int
}

struct ContributionDay: Identifiable {
    var id: TimeInterval { date.timeIntervalSince1970 }
    let date: Date
    let count: Int
    let isInRange: Bool
}

struct TaskAffinityDatum: Identifiable {
    let id = UUID()
    let provider: Provider
    let action: String
    let count: Int

    var actionLabel: String {
        action.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct CorrectionRateRow: Identifiable {
    var id: String { provider.rawValue }
    let provider: Provider
    let correctionCount: Int
    let totalMessages: Int
    let ratePer100: Double
}

struct PromptStyleRow: Identifiable {
    var id: String { provider.rawValue }
    let provider: Provider
    let messageCount: Int
    let averageLength: Double
    let constraintRate: Double
    let codeRate: Double
}

struct HourlyActivityDatum: Identifiable {
    var id: String { "\(provider.rawValue)-\(hour)" }
    let hour: Int
    let provider: Provider
    let count: Int
}

struct ConsistencyPoint: Identifiable {
    let id = UUID()
    let date: Date
    let corrections: Int
    let totalMessages: Int
    let ratePer100: Double
}

struct ProviderCount: Identifiable {
    var id: String { provider.rawValue }
    let provider: Provider
    let count: Int
}

struct ProjectStats {
    let path: String
    let messageCount: Int
}

struct LearningFunnelStats {
    let pending: Int
    let approved: Int
    let rejected: Int

    var total: Int { pending + approved + rejected }
}

struct RepeatabilityBucket: Identifiable {
    let id = UUID()
    let label: String
    let count: Int
}

struct HeatmapBucket: Identifiable {
    let id = UUID()
    let startDate: Date
    let label: String
}

struct ImpactIndexStats {
    let estimatedMinutesSaved: Int
    let approvedLearnings: Int
    let workflowRuns: Int

    var estimatedHoursSaved: Double {
        Double(estimatedMinutesSaved) / 60.0
    }

    var estimatedHoursSavedFormatted: String {
        String(format: "%.1fh", estimatedHoursSaved)
    }

    static func build(approvedLearnings: Int, workflowRuns: Int) -> ImpactIndexStats {
        let minutes = approvedLearnings * 3 + workflowRuns * 5
        return ImpactIndexStats(
            estimatedMinutesSaved: minutes,
            approvedLearnings: approvedLearnings,
            workflowRuns: workflowRuns
        )
    }
}

struct ProviderUsageStats: Identifiable {
    var id: String { provider.rawValue }
    let provider: Provider
    let conversationCount: Int
    let messageCount: Int
    let averageMessages: Double
    let activeDays: Int
}

struct AnalysisLatencyStats {
    let averageSeconds: TimeInterval
    let p95Seconds: TimeInterval
    let totalRuns: Int
    let failedRuns: Int
}

enum HeatmapBucketSize {
    case week
    case month

    static func from(timeRange: AnalyticsView.TimeRange) -> HeatmapBucketSize {
        if let days = timeRange.days, days <= 90 {
            return .week
        }
        return .month
    }

    func startDate(for date: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .week:
            return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? date
        case .month:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        }
    }

    func nextDate(after date: Date, calendar: Calendar) -> Date {
        switch self {
        case .week:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        }
    }

    var labelFormatter: DateFormatter {
        let formatter = DateFormatter()
        switch self {
        case .week:
            formatter.dateFormat = "MMM d"
        case .month:
            formatter.dateFormat = "MMM yy"
        }
        return formatter
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Spacer()
            }

            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Contribution Grid

struct ContributionGridView: View {
    let days: [ContributionDay]

    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 4

    private var calendar: Calendar {
        Calendar.current
    }

    private var maxCount: Int {
        days.filter { $0.isInRange }.map(\.count).max() ?? 0
    }

    private var weeks: [[ContributionDay]] {
        var output: [[ContributionDay]] = []
        var current: [ContributionDay] = []
        for day in days {
            current.append(day)
            if current.count == 7 {
                output.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            output.append(current)
        }
        return output
    }

    private var monthLabels: [Int: String] {
        var labels: [Int: String] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        var lastMonth: Int?
        for (index, week) in weeks.enumerated() {
            guard let firstDay = week.first(where: { $0.isInRange }) ?? week.first else { continue }
            let month = calendar.component(.month, from: firstDay.date)
            if month != lastMonth {
                labels[index] = formatter.string(from: firstDay.date)
                lastMonth = month
            }
        }
        return labels
    }

    private var weekdayLabelMap: [Int: String] {
        let symbols = calendar.shortWeekdaySymbols
        let startIndex = max(calendar.firstWeekday - 1, 0)
        let indices = [1, 3, 5]
        var output: [Int: String] = [:]
        for rowIndex in indices {
            output[rowIndex] = symbols[(startIndex + rowIndex) % symbols.count]
        }
        return output
    }

    var body: some View {
        if days.isEmpty {
            Text("No activity yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: cellSpacing) {
                    VStack(spacing: cellSpacing) {
                        Text(" ")
                            .frame(width: cellSize, height: cellSize)
                        ForEach(0..<7, id: \.self) { rowIndex in
                            Text(weekdayLabelMap[rowIndex] ?? "")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: cellSize, height: cellSize)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: cellSpacing) {
                            HStack(spacing: cellSpacing) {
                                ForEach(weeks.indices, id: \.self) { index in
                                    Text(monthLabels[index] ?? "")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .frame(width: cellSize, alignment: .leading)
                                }
                            }

                            HStack(alignment: .top, spacing: cellSpacing) {
                                ForEach(weeks.indices, id: \.self) { weekIndex in
                                    VStack(spacing: cellSpacing) {
                                        ForEach(weeks[weekIndex]) { day in
                                            ContributionCell(
                                                day: day,
                                                maxCount: maxCount,
                                                size: cellSize
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text("Less")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(0..<4, id: \.self) { index in
                        ContributionLegendSwatch(
                            intensity: Double(index + 1) / 4.0,
                            size: cellSize
                        )
                    }
                    Text("More")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 200)
        }
    }
}

struct ContributionCell: View {
    let day: ContributionDay
    let maxCount: Int
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: size, height: size)
            .help(helpText)
    }

    private var color: Color {
        guard day.isInRange else {
            return Color.clear
        }
        if day.count == 0 {
            return Color.secondary.opacity(0.2)
        }
        let ratio = maxCount > 0 ? Double(day.count) / Double(maxCount) : 0
        let opacity = 0.25 + ratio * 0.75
        return Color.accentColor.opacity(opacity)
    }

    private var helpText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateText = formatter.string(from: day.date)
        return "\(day.count) messages on \(dateText)"
    }
}

struct ContributionLegendSwatch: View {
    let intensity: Double
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(0.25 + intensity * 0.75))
            .frame(width: size, height: size)
    }
}

// MARK: - Daily Provider Stack

struct DailyProviderStackView: View {
    let data: [DailyActivityProvider]

    private var sortedData: [DailyActivityProvider] {
        data.sorted { $0.date < $1.date }
    }

    var body: some View {
        if data.isEmpty {
            Text("No activity yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
        } else if #available(macOS 14.0, *) {
            Chart(sortedData) { item in
                BarMark(
                    x: .value("Day", item.date, unit: .day),
                    y: .value("Messages", item.count)
                )
                .foregroundStyle(by: .value("Provider", item.provider.displayName))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 200)
        } else {
            Text("Daily provider breakdown requires macOS 14")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
        }
    }
}

// MARK: - Provider List (fallback)

struct ProviderList: View {
    let distribution: [ProviderCount]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(distribution) { item in
                HStack {
                    Circle()
                        .fill(item.provider.color)
                        .frame(width: 12, height: 12)

                    Text(item.provider.displayName)
                        .font(.caption)

                    Spacer()

                    Text("\(item.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }
}

// MARK: - Learning Funnel

struct LearningFunnelView: View {
    let stats: LearningFunnelStats

    private var chartData: [FunnelDatum] {
        [
            FunnelDatum(label: "Pending", count: stats.pending, color: .orange),
            FunnelDatum(label: "Approved", count: stats.approved, color: .green),
            FunnelDatum(label: "Rejected", count: stats.rejected, color: .red)
        ]
    }

    var body: some View {
        if #available(macOS 14.0, *) {
            Chart(chartData) { item in
                BarMark(
                    x: .value("Status", item.label),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(item.color.gradient)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(chartData) { item in
                    HStack {
                        Text(item.label)
                        Spacer()
                        Text("\(item.count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct FunnelDatum: Identifiable {
    let id = UUID()
    let label: String
    let count: Int
    let color: Color
}

// MARK: - Repeatability Score

struct RepeatabilityScoreView: View {
    let buckets: [RepeatabilityBucket]

    var body: some View {
        if buckets.isEmpty {
            Text("No repeatable workflows yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if #available(macOS 14.0, *) {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Runs", bucket.label),
                    y: .value("Workflows", bucket.count)
                )
                .foregroundStyle(Color.purple.gradient)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(buckets) { bucket in
                    HStack {
                        Text(bucket.label)
                        Spacer()
                        Text("\(bucket.count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Task Type Affinity

struct TaskAffinityView: View {
    let data: [TaskAffinityDatum]

    private var providerDomain: [String] {
        Provider.allCases
            .filter { $0.isSupported }
            .map { $0.displayName }
    }

    var body: some View {
        if data.isEmpty {
            Text("No workflow signals yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if #available(macOS 14.0, *) {
            Chart(data) { datum in
                BarMark(
                    x: .value("Provider", datum.provider.displayName),
                    y: .value("Count", datum.count)
                )
                .foregroundStyle(by: .value("Action", datum.actionLabel))
            }
            .chartXScale(domain: providerDomain)
            .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(groupedByProvider(data), id: \.provider) { group in
                    HStack {
                        Text(group.provider.displayName)
                        Spacer()
                        Text(group.summary)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func groupedByProvider(_ data: [TaskAffinityDatum]) -> [(provider: Provider, summary: String)] {
        let grouped = Dictionary(grouping: data, by: \.provider)
        return grouped.map { provider, items in
            let summary = items.sorted { $0.count > $1.count }
                .prefix(3)
                .map { "\($0.actionLabel.lowercased()) \( $0.count)" }
                .joined(separator: ", ")
            return (provider, summary)
        }
        .sorted { $0.provider.displayName < $1.provider.displayName }
    }
}

// MARK: - Correction Rate

struct CorrectionRateView: View {
    let data: [CorrectionRateRow]

    private var providerDomain: [String] {
        Provider.allCases
            .filter { $0.isSupported }
            .map { $0.displayName }
    }

    var body: some View {
        if data.isEmpty {
            Text("No correction data yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if #available(macOS 14.0, *) {
            Chart(data) { row in
                BarMark(
                    x: .value("Provider", row.provider.displayName),
                    y: .value("Corrections / 100", row.ratePer100)
                )
                .foregroundStyle(row.provider.color.gradient)
            }
            .chartXScale(domain: providerDomain)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(data) { row in
                    HStack {
                        Text(row.provider.displayName)
                        Spacer()
                        Text(String(format: "%.1f / 100", row.ratePer100))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Prompt Style Fingerprints

struct PromptStyleView: View {
    let rows: [PromptStyleRow]

    var body: some View {
        if rows.isEmpty {
            Text("No prompt style data yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Text(row.provider.displayName)
                            .frame(width: 120, alignment: .leading)

                        MetricPill(label: "Avg length", value: "\(Int(row.averageLength)) chars")
                        MetricPill(label: "Constraints", value: String(format: "%.0f%%", row.constraintRate * 100))
                        MetricPill(label: "Code", value: String(format: "%.0f%%", row.codeRate * 100))

                        Spacer()

                        Text("\(row.messageCount) prompts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Time of Day Breakdown

struct TimeOfDayView: View {
    let data: [HourlyActivityDatum]

    var body: some View {
        if data.isEmpty {
            Text("No hourly data yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if #available(macOS 14.0, *) {
            Chart(data) { datum in
                BarMark(
                    x: .value("Hour", datum.hour),
                    y: .value("Messages", datum.count)
                )
                .foregroundStyle(by: .value("Provider", datum.provider.displayName))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: 3))
            }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
            .frame(height: 220)
        } else {
            SimpleHourlyList(data: data)
        }
    }
}

struct SimpleHourlyList: View {
    let data: [HourlyActivityDatum]

    var body: some View {
        let grouped = Dictionary(grouping: data, by: \.provider)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(grouped.keys.sorted(by: { $0.displayName < $1.displayName }), id: \.rawValue) { provider in
                let total = grouped[provider]?.reduce(0) { $0 + $1.count } ?? 0
                HStack {
                    Text(provider.displayName)
                    Spacer()
                    Text("\(total) msgs")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Consistency Trend

struct ConsistencyTrendView: View {
    let points: [ConsistencyPoint]

    var body: some View {
        if points.isEmpty {
            Text("No correction trend yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if #available(macOS 14.0, *) {
            Chart(points) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Corrections / 100", point.ratePer100)
                )
                .interpolationMethod(.catmullRom)

                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Corrections / 100", point.ratePer100)
                )
            }
            .frame(height: 220)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(points.prefix(8)) { point in
                    HStack {
                        Text(point.date, style: .date)
                        Spacer()
                        Text(String(format: "%.1f / 100", point.ratePer100))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Assistant Usage

struct AssistantUsageView: View {
    let stats: [ProviderUsageStats]

    var body: some View {
        if stats.isEmpty {
            Text("No provider data yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(stats) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.provider.iconName)
                            .foregroundColor(item.provider.color)
                        Text(item.provider.displayName)
                            .frame(width: 120, alignment: .leading)
                        Spacer()
                        Text("\(item.conversationCount) convos")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(item.messageCount) msgs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f avg", item.averageMessages))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(item.activeDays) days")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Analysis Performance

struct AnalysisPerformanceView: View {
    let stats: AnalysisLatencyStats?

    var body: some View {
        if let stats {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Avg latency")
                    Spacer()
                    Text(formatDuration(stats.averageSeconds))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("P95 latency")
                    Spacer()
                    Text(formatDuration(stats.p95Seconds))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Total runs")
                    Spacer()
                    Text("\(stats.totalRuns)")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Failed runs")
                    Spacer()
                    Text("\(stats.failedRuns)")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Cost")
                    Spacer()
                    Text("Not captured yet")
                        .foregroundColor(.secondary)
                }
            }
        } else {
            Text("No scan performance data yet")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        if minutes < 60 {
            return remainder > 0 ? "\(minutes)m \(remainder)s" : "\(minutes)m"
        }
        let hours = minutes / 60
        let minutesRemainder = minutes % 60
        return minutesRemainder > 0 ? "\(hours)h \(minutesRemainder)m" : "\(hours)h"
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let project: ProjectStats

    var body: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundColor(.secondary)

            Text(project.path)
                .font(.body)

            Spacer()

            Text("\(project.messageCount) messages")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }
}

// MARK: - Recent Conversation Row

struct RecentConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack {
            Image(systemName: conversation.provider.iconName)
                .foregroundColor(conversation.provider.color)

            VStack(alignment: .leading) {
                Text(conversation.title ?? "Untitled")
                    .font(.body)
                    .lineLimit(1)

                Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(conversation.messageCount) msgs")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }
}

#Preview {
    AnalyticsView()
        .environmentObject(AppState())
}
