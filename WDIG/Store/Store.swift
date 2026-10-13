import Foundation
import SwiftData

/// The one container of the app. The store file sits in Application Support and goes
/// into device backups; nothing in it is ever purged, raw points are kept for good.
enum Store {
    static let schema = Schema(versionedSchema: StoreSchemaV2.self)

    /// The store on disk, or one in memory for tests.
    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration("WDIG", schema: schema, isStoredInMemoryOnly: true)
        } else {
            let url = try storeURL()
            configuration = ModelConfiguration("WDIG", schema: schema, url: url, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: StoreMigrationPlan.self, configurations: [configuration])
    }

    static func storeURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appending(path: "WDIG", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "store.sqlite")
    }
}
