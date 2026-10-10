import Foundation

/// Everything the local search reads from a `ClipStore`.
///
/// The search used to take a `ClipStore` directly and run on the main actor,
/// which froze the panel for the whole query (measured 130–200 ms on a
/// production-sized library). Narrowing the dependency to these three members
/// lets the same engine run against an immutable snapshot instead.
protocol SearchDataSource {
    var database: DatabaseManager? { get }
    var memoryIndex: MemorySearchIndex { get }
    func clip(dbID: Int64) -> Clip?
}

// `clip(id:)` was part of this protocol but no search path ever called it — the
// engine looks clips up by `dbID` only — and carrying it forced every snapshot
// to copy a second 100k-entry dictionary for nothing.

extension ClipStore: SearchDataSource {}

/// Immutable, copy-on-write view of the store's in-memory search state.
///
/// Every field is a value type, and Swift shares their storage until one side
/// mutates, so taking a snapshot on the main actor costs O(1) and the search
/// can then read it from a background queue with no locks and no shared
/// mutable state.
///
/// `@unchecked Sendable` is sound here because the instance is immutable in
/// practice: it is created on the main actor, handed to one search, and never
/// mutated afterwards (`memoryIndex` is a private copy that no call site
/// writes to).
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
