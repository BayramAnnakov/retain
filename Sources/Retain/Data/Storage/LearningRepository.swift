import Foundation
import GRDB

/// Repository for learning CRUD operations
final class LearningRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Create

    /// Insert a new learning
    func insert(_ learning: Learning) throws {
        try database.write { db in
            var newLearning = learning
            try newLearning.insert(db)
        }
    }

    /// Insert multiple learnings
    func insert(_ learnings: [Learning]) throws {
        try database.write { db in
            for var learning in learnings {
                try learning.insert(db)
            }
        }
    }

    // MARK: - Read

    /// Fetch all learnings
    func fetchAll() throws -> [Learning] {
        try database.read { db in
            try Learning
                .order(Learning.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch learnings by status
    func fetch(status: LearningStatus) throws -> [Learning] {
        try database.read { db in
            try Learning
                .filter(Learning.Columns.status == status.rawValue)
                .order(Learning.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch pending learnings
    func fetchPending() throws -> [Learning] {
        let includeImplicit = UserDefaults.standard.bool(forKey: "includeImplicitLearnings")
        let positive = LearningType.positive.rawValue
        let implicit = LearningType.implicit.rawValue

        return try database.read { db in
            let typeColumn = Learning.Columns.type
            let evidenceColumn = Learning.Columns.evidenceCount

            var request = Learning
                .filter(Learning.Columns.status == LearningStatus.pending.rawValue)

            if includeImplicit {
                request = request.filter(
                    (typeColumn != positive && typeColumn != implicit)
                        || (evidenceColumn >= 3)
                )
            } else {
                request = request.filter(typeColumn != positive && typeColumn != implicit)
            }

            return try request
                .order(Learning.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch approved learnings
    func fetchApproved() throws -> [Learning] {
        try fetch(status: .approved)
    }

    /// Fetch learnings for a conversation
    func fetch(conversationId: UUID) throws -> [Learning] {
        try database.read { db in
            try Learning
                .filter(Learning.Columns.conversationId == conversationId)
                .order(Learning.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single learning by ID
    func fetch(id: UUID) throws -> Learning? {
        try database.read { db in
            try Learning.fetchOne(db, key: id)
        }
    }

    /// Count pending learnings
    func countPending() throws -> Int {
        let includeImplicit = UserDefaults.standard.bool(forKey: "includeImplicitLearnings")
        let positive = LearningType.positive.rawValue
        let implicit = LearningType.implicit.rawValue

        return try database.read { db in
            let typeColumn = Learning.Columns.type
            let evidenceColumn = Learning.Columns.evidenceCount

            var request = Learning
                .filter(Learning.Columns.status == LearningStatus.pending.rawValue)

            if includeImplicit {
                request = request.filter(
                    (typeColumn != positive && typeColumn != implicit)
                        || (evidenceColumn >= 3)
                )
            } else {
                request = request.filter(typeColumn != positive && typeColumn != implicit)
            }

            return try request.fetchCount(db)
        }
    }

    /// Count learnings by status
    func countByStatus() throws -> [LearningStatus: Int] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT status, COUNT(*) as count
                FROM learnings
                GROUP BY status
                """)

            var result: [LearningStatus: Int] = [:]
            for row in rows {
                if let statusString: String = row["status"],
                   let status = LearningStatus(rawValue: statusString),
                   let count: Int = row["count"] {
                    result[status] = count
                }
            }
            return result
        }
    }

    // MARK: - Update

    /// Update a learning
    func update(_ learning: Learning) throws {
        try database.write { db in
            try learning.update(db)
        }
    }

    /// Approve a learning
    func approve(id: UUID) throws {
        try database.write { db in
            if var learning = try Learning.fetchOne(db, key: id) {
                learning.approve()
                try learning.update(db)
            }
        }
    }

    /// Reject a learning
    func reject(id: UUID) throws {
        try database.write { db in
            if var learning = try Learning.fetchOne(db, key: id) {
                learning.reject()
                try learning.update(db)
            }
        }
    }

    /// Approve multiple learnings
    func approveAll(ids: [UUID]) throws {
        try database.write { db in
            for id in ids {
                if var learning = try Learning.fetchOne(db, key: id) {
                    learning.approve()
                    try learning.update(db)
                }
            }
        }
    }

    // MARK: - Delete

    /// Delete a learning by ID
    func delete(id: UUID) throws {
        try database.write { db in
            try Learning.deleteOne(db, key: id)
        }
    }

    /// Delete all rejected learnings
    func deleteRejected() throws {
        try database.write { db in
            try Learning
                .filter(Learning.Columns.status == LearningStatus.rejected.rawValue)
                .deleteAll(db)
        }
    }

    /// Delete learnings for a conversation
    func delete(conversationId: UUID) throws {
        try database.write { db in
            try Learning
                .filter(Learning.Columns.conversationId == conversationId)
                .deleteAll(db)
        }
    }

    // MARK: - Search

    /// Search learnings by pattern or rule
    func search(query: String, limit: Int = 50) throws -> [Learning] {
        try database.read { db in
            let pattern = "%\(query)%"
            return try Learning
                .filter(Learning.Columns.pattern.like(pattern) ||
                       Learning.Columns.extractedRule.like(pattern))
                .order(Learning.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Export

    /// Fetch all approved learnings grouped by scope
    func fetchApprovedGroupedByScope() throws -> [LearningScope: [Learning]] {
        let approved = try fetchApproved()
        return Dictionary(grouping: approved, by: { $0.scope })
    }

    /// Fetch all approved learnings grouped by type
    func fetchApprovedGroupedByType() throws -> [LearningType: [Learning]] {
        let approved = try fetchApproved()
        return Dictionary(grouping: approved, by: { $0.type })
    }
}
