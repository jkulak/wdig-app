import SwiftData

/// Every schema the store has had, oldest first, and the stages between them. A new
/// schema adds itself here with its stage, lightweight where SwiftData allows it, custom
/// otherwise, and is tested against a store file written by the version before it.
enum StoreMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [StoreSchemaV1.self, StoreSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: StoreSchemaV1.self, toVersion: StoreSchemaV2.self)]
    }
}
