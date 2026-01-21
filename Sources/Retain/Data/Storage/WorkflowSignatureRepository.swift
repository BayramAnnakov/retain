import Foundation
import GRDB

/// Repository for workflow signature persistence + aggregates
final class WorkflowSignatureRepository {
    private let db: AppDatabase

    init(db: AppDatabase = .shared) {
        self.db = db
    }

    func upsert(_ signature: WorkflowSignature) async throws {
        try await db.writer.write { db in
            if var existing = try WorkflowSignature
                .filter(WorkflowSignature.Columns.conversationId == signature.conversationId)
                .fetchOne(db) {
                existing.signature = signature.signature
                existing.action = signature.action
                existing.artifact = signature.artifact
                existing.domains = signature.domains
                existing.snippet = signature.snippet
                existing.version = signature.version
                existing.updatedAt = signature.updatedAt
                existing.sourceQueueId = signature.sourceQueueId
                existing.confidence = signature.confidence
                existing.source = signature.source
                existing.detectorVersion = signature.detectorVersion
                existing.isPriming = signature.isPriming
                try existing.update(db)
            } else {
                try signature.insert(db)
            }
        }
    }

    func fetchTopClusters(
        limit: Int = 10,
        sampleLimit: Int = 3,
        excludingActions: [String] = [],
        excludedArtifacts: [String] = ["none"],
        minimumCount: Int = 3
    ) async throws -> [WorkflowCluster] {
        try await db.reader.read { db in
            var conditions: [String] = []
            var argumentsArray: [DatabaseValueConvertible?] = []

            if !excludingActions.isEmpty {
                let placeholders = Array(repeating: "?", count: excludingActions.count).joined(separator: ",")
                conditions.append("ws.action NOT IN (\(placeholders))")
                argumentsArray.append(contentsOf: excludingActions)
            }

            if !excludedArtifacts.isEmpty {
                let placeholders = Array(repeating: "?", count: excludedArtifacts.count).joined(separator: ",")
                conditions.append("ws.artifact NOT IN (\(placeholders))")
                argumentsArray.append(contentsOf: excludedArtifacts)
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

            argumentsArray.append(minimumCount)
            argumentsArray.append(limit)
            let arguments = StatementArguments(argumentsArray)

            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    ws.signature AS signature,
                    ws.action AS action,
                    ws.artifact AS artifact,
                    ws.domains AS domains,
                    COUNT(*) AS count,
                    COUNT(DISTINCT COALESCE(c.projectPath, '')) AS distinctProjects
                FROM workflow_signatures ws
                JOIN conversations c ON c.id = ws.conversationId
                \(whereClause)
                GROUP BY ws.signature, ws.action, ws.artifact, ws.domains
                HAVING COUNT(*) >= ?
                ORDER BY count DESC
                LIMIT ?
                """, arguments: arguments)

            var clusters: [WorkflowCluster] = []

            for row in rows {
                let signature: String = row["signature"]
                let action: String = row["action"]
                let artifact: String = row["artifact"]
                let domains: String = row["domains"]
                let count: Int = row["count"]
                let distinctProjects: Int = row["distinctProjects"]

                if (action == "fix" || action == "debug"), distinctProjects < 2 {
                    continue
                }

                let sampleRows = try Row.fetchAll(db, sql: """
                    SELECT ws.snippet AS snippet, c.sourceType AS sourceType, c.projectPath AS projectPath
                    FROM workflow_signatures ws
                    JOIN conversations c ON c.id = ws.conversationId
                    WHERE ws.signature = ?
                    ORDER BY ws.updatedAt DESC
                    LIMIT ?
                    """, arguments: [signature, sampleLimit])

                let samples = sampleRows.map { sampleRow in
                    WorkflowClusterSample(
                        sourceType: sampleRow["sourceType"] ?? "",
                        projectPath: sampleRow["projectPath"],
                        snippet: sampleRow["snippet"] ?? ""
                    )
                }

                clusters.append(
                    WorkflowCluster(
                        signature: signature,
                        action: action,
                        artifact: artifact,
                        domains: domains.split(separator: ",").map { String($0) },
                        count: count,
                        distinctProjects: distinctProjects,
                        samples: samples
                    )
                )
            }

            return clusters
        }
    }

    func fetchClusters(
        action: String,
        limit: Int = 10,
        sampleLimit: Int = 3
    ) async throws -> [WorkflowCluster] {
        try await db.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    ws.signature AS signature,
                    ws.action AS action,
                    ws.artifact AS artifact,
                    ws.domains AS domains,
                    COUNT(*) AS count,
                    COUNT(DISTINCT COALESCE(c.projectPath, '')) AS distinctProjects
                FROM workflow_signatures ws
                JOIN conversations c ON c.id = ws.conversationId
                WHERE ws.action = ?
                GROUP BY ws.signature, ws.action, ws.artifact, ws.domains
                ORDER BY count DESC
                LIMIT ?
                """, arguments: [action, limit])

            var clusters: [WorkflowCluster] = []

            for row in rows {
                let signature: String = row["signature"]
                let action: String = row["action"]
                let artifact: String = row["artifact"]
                let domains: String = row["domains"]
                let count: Int = row["count"]
                let distinctProjects: Int = row["distinctProjects"]

                let sampleRows = try Row.fetchAll(db, sql: """
                    SELECT ws.snippet AS snippet, c.sourceType AS sourceType, c.projectPath AS projectPath
                    FROM workflow_signatures ws
                    JOIN conversations c ON c.id = ws.conversationId
                    WHERE ws.signature = ?
                    ORDER BY ws.updatedAt DESC
                    LIMIT ?
                    """, arguments: [signature, sampleLimit])

                let samples = sampleRows.map { sampleRow in
                    WorkflowClusterSample(
                        sourceType: sampleRow["sourceType"] ?? "",
                        projectPath: sampleRow["projectPath"],
                        snippet: sampleRow["snippet"] ?? ""
                    )
                }

                clusters.append(
                    WorkflowCluster(
                        signature: signature,
                        action: action,
                        artifact: artifact,
                        domains: domains.split(separator: ",").map { String($0) },
                        count: count,
                        distinctProjects: distinctProjects,
                        samples: samples
                    )
                )
            }

            return clusters
        }
    }

    func fetchConversationIdsMissingSignature() async throws -> [UUID] {
        try await db.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id AS id
                FROM conversations c
                LEFT JOIN workflow_signatures ws ON ws.conversationId = c.id
                WHERE ws.id IS NULL
                """)
            return rows.compactMap { row in
                if let uuid: UUID = row["id"] {
                    return uuid
                }
                if let string: String = row["id"] {
                    return UUID(uuidString: string)
                }
                return nil
            }
        }
    }

    func deleteAll() async throws {
        _ = try await db.writer.write { db in
            try WorkflowSignature.deleteAll(db)
        }
    }
}
