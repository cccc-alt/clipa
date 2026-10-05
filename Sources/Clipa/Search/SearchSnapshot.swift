import Foundation

protocol SearchDataSource {
    var database: DatabaseManager? { get }
    var memoryIndex: MemorySearchIndex { get }
    func clip(dbID: Int64) -> Clip?
}

extension ClipStore: SearchDataSource {}

struct SearchSnapshot: SearchDataSource, @unchecked Sendable {
    let database: DatabaseManager?
    let memoryIndex: MemorySearchIndex
    let itemCount: Int

    private let clipsByDBID: [Int64: ClipBox]

    init(store: ClipStore) {
        database = store.database
        memoryIndex = store.memoryIndex.snapshot()
        itemCount = store.items.count
        clipsByDBID = store.clipsByDBIDSnapshot
    }

    func clip(dbID: Int64) -> Clip? {
        clipsByDBID[dbID]?.clip
    }
}
