import Combine
import Foundation

final class ClipBox {
    let clip: Clip

    init(_ clip: Clip) {
        self.clip = clip
    }
}

enum ClipDeleteResult: Equatable {
    case deleted(count: Int)
    case failed
}

enum ClipClearResult: Equatable {
    case cleared(deleted: Int)
    case busy
    case failed
}

struct ClipClearSummary: Equatable {
    let removable: Int
    let privateCount: Int

    var requiresAuthentication: Bool {
        privateCount > 0
    }
}

enum ClipAssetAvailability: Equatable {
    case available
    case unavailable
}

enum ClipStoreUnavailabilityReason: Equatable {

    case databaseUnreadable

    case historyUnreadable

    case migrationFailed

    case storageUnavailable
}

enum ClipStoreAvailability: Equatable {

    case ready

    case unavailable(reason: ClipStoreUnavailabilityReason, detail: String)

    var isReady: Bool { self == .ready }

    var reason: ClipStoreUnavailabilityReason? {
        guard case .unavailable(let reason, _) = self else { return nil }
        return reason
    }
}

/// In-memory clip mirror + write coordination for one workspace.
final class ClipStore: ObservableObject {

    private(set) static var shared = ClipStore(
        baseDirectory: WorkspaceStore.activeBaseDirectoryOnDisk()
    )

    static func replaceShared(with store: ClipStore) {
        shared = store
        NotificationCenter.default.post(
            name: sharedReplacedNotification,
            object: nil
        )
    }

    static let sharedReplacedNotification = Notification.Name(
        "ClipaStoreSharedReplaced"
    )

    static let captureRejectedNotification = Notification.Name(
        "ClipaStoreCaptureRejected"
    )

    static let autoPauseStateChanged = Notification.Name(
        "ClipaAutoPauseStateChanged"
    )

    private var storedItems: [Clip] = []

    var items: [Clip] { storedItems }

    private let itemsDidChange = PassthroughSubject<Void, Never>()

    var itemsPublisher: AnyPublisher<Void, Never> {
        itemsDidChange.eraseToAnyPublisher()
    }

    @Published private(set) var isClearingHistory = false

    @Published private(set) var availability: ClipStoreAvailability = .ready

    private(set) var memoryIndex = MemorySearchIndex()

    private(set) var database: DatabaseManager?
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private var settingsStore: SettingsStore?
    private var clipsByDBID: [Int64: ClipBox] = [:]
    private var clipsByUUID: [UUID: Int64] = [:]

    private var hasAnnouncedCaptureRejection = false

    var settings: SettingsStore { settingsStore ?? .shared }

    var dataDirectory: URL { baseDirectory }

    init(baseDirectory: URL? = nil, settingsStore: SettingsStore? = nil) {
        self.settingsStore = settingsStore
        let base = baseDirectory ?? Self.defaultBaseDirectory()
        self.baseDirectory = base
        try? fileManager.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )

        let databaseExisted = fileManager.fileExists(
            atPath: DatabaseManager.databaseURL(in: base).path
        )
        do {
            self.database = try DatabaseManager(baseDirectory: base)
        } catch {
            NSLog("Clipa failed to open database: \(error.localizedDescription)")
            self.database = nil
            self.availability = .unavailable(
                reason: Self.unavailabilityReason(
                    for: error,
                    databaseExisted: databaseExisted
                ),
                detail: error.localizedDescription
            )
        }
        reloadFromDatabase()
    }

    private static func unavailabilityReason(
        for error: Error,
        databaseExisted: Bool
    ) -> ClipStoreUnavailabilityReason {
        if let databaseError = error as? DatabaseError,
           case .migration = databaseError {
            return .migrationFailed
        }
        return databaseExisted ? .databaseUnreadable : .storageUnavailable
    }

    static func defaultBaseDirectory() -> URL {
        if let override = defaultBaseDirectoryOverride {
            return override
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return support.appendingPathComponent("Clipa", isDirectory: true)
    }

    static var defaultBaseDirectoryOverride: URL?

    func reloadFromDatabase() {
        guard let database else {

            if availability.isReady {
                availability = .unavailable(
                    reason: .databaseUnreadable,
                    detail: ""
                )
            }
            replaceAll([])
            return
        }
        do {
            let clips = try runDB(database) { db in
                try await db.loadRecentClips()
            }
            replaceAll(clips)
            availability = .ready
            hasAnnouncedCaptureRejection = false
        } catch {
            NSLog("Clipa failed to load history: \(error.localizedDescription)")
            availability = .unavailable(
                reason: .historyUnreadable,
                detail: error.localizedDescription
            )
            replaceAll([])
        }
    }

    @discardableResult
    func retryDatabaseOpen() -> Bool {
        if availability.isReady, database != nil { return true }
        let databasePath = DatabaseManager.databaseURL(in: baseDirectory)
        let databaseExisted = fileManager.fileExists(atPath: databasePath.path)

        if let stale = database {
            _ = try? runDB(stale) { await $0.invalidate() }
            database = nil
        }
        do {
            let reopened = try DatabaseManager(baseDirectory: baseDirectory)
            database = reopened
            availability = .ready
            hasAnnouncedCaptureRejection = false
            reloadFromDatabase()
            return availability.isReady
        } catch {
            NSLog("Clipa database reopen failed: \(error.localizedDescription)")
            database = nil
            availability = .unavailable(
                reason: Self.unavailabilityReason(
                    for: error,
                    databaseExisted: databaseExisted
                ),
                detail: error.localizedDescription
            )
            replaceAll([])
            return false
        }
    }

    func clip(dbID: Int64) -> Clip? {
        clipsByDBID[dbID]?.clip
    }

    var clipsByDBIDSnapshot: [Int64: ClipBox] { clipsByDBID }

    var searchSnapshot: SearchSnapshot { SearchSnapshot(store: self) }

    func clip(id: UUID) -> Clip? {
        guard let dbID = clipsByUUID[id] else { return nil }
        return clipsByDBID[dbID]?.clip
    }

    @discardableResult
    func insert(_ draft: NewClip, allowAutoPause: Bool = true) -> Bool {
        var prepared = draft
        if prepared.contentHash == nil {
            prepared.contentHash = Self.computeContentHash(for: prepared)
        }

        guard !isClearingHistory else {
            NSLog("Clipa dropped a capture that arrived during a history clear")
            return false
        }
        guard availability.isReady, let database else {
            rejectCaptureWhileUnavailable(prepared)
            return false
        }

        let limitExceeded =
            allowAutoPause
            && settings.autoPauseAtLimit
            && settings.historyLimit > 0
            && historyCount >= settings.historyLimit
        if limitExceeded {

            let draftKind = prepared.kind
            let draftHash = prepared.contentHash ?? ""
            do {
                let duplicate = try runDB(database) { db in
                    try await db.findDuplicate(
                        contentHash: draftHash,
                        kind: draftKind
                    )
                }
                if duplicate == nil {
                    if !settings.pauseRecording {
                        settings.pauseRecording = true
                        settings.autoPausedByLimit = true
                        NotificationCenter.default.post(
                            name: Self.autoPauseStateChanged,
                            object: nil
                        )
                    }
                    return false
                }
            } catch {
                NSLog(
                    "Clipa duplicate check failed: \(error.localizedDescription)"
                )
                return false
            }
        }

        do {
            let preparedCopy = prepared
            let outcome = try runDB(database) { db in
                try await db.insertClip(preparedCopy)
            }
            if outcome.inserted {
                upsert(outcome.clip)
                trimToLimit()
            } else {

                if let data = prepared.imageData,
                   (try? runDB(database) { db in
                       try await db.hasImageData(dbID: outcome.clip.dbID)
                   }) == false {
                    var adoptedClip: Clip?
                    let imageFormat = prepared.imageFormat
                    do {
                        adoptedClip = try runDB(database) { db in
                            try await db.updateImage(
                                dbID: outcome.clip.dbID,
                                data: data,
                                format: imageFormat
                            )
                        }
                    } catch {
                        NSLog(
                            "Clipa failed to adopt replacement image: \(error.localizedDescription)"
                        )
                    }
                    if let adoptedClip {
                        upsert(adoptedClip)
                        return outcome.inserted
                    }
                }
                upsert(outcome.clip)
            }
            return outcome.inserted
        } catch {
            NSLog("Clipa insert failed: \(error.localizedDescription)")
            return false
        }
    }

    private func rejectCaptureWhileUnavailable(_ draft: NewClip) {
        guard !hasAnnouncedCaptureRejection else { return }
        hasAnnouncedCaptureRejection = true
        NSLog("Clipa rejected a capture: store unavailable")
        NotificationCenter.default.post(
            name: Self.captureRejectedNotification,
            object: self
        )
    }

    @MainActor
    @discardableResult
    func insertCaptureAsync(
        _ draft: NewClip,
        allowAutoPause: Bool = true,
        captureEpoch: UInt64? = nil
    ) async -> Bool {
        var prepared = draft
        if prepared.contentHash == nil {
            prepared.contentHash = Self.computeContentHash(for: prepared)
        }
        guard !isClearingHistory else {
            NSLog("Clipa dropped a capture that arrived during a history clear")
            return false
        }
        guard availability.isReady, let database else {
            rejectCaptureWhileUnavailable(prepared)
            return false
        }

        let limitExceeded =
            allowAutoPause
            && settings.autoPauseAtLimit
            && settings.historyLimit > 0
            && historyCount >= settings.historyLimit
        if limitExceeded {
            let draftKind = prepared.kind
            do {
                let duplicate = try await database.findDuplicate(
                    contentHash: prepared.contentHash ?? "",
                    kind: draftKind
                )
                if duplicate == nil {
                    if !settings.pauseRecording {
                        settings.pauseRecording = true
                        settings.autoPausedByLimit = true
                        NotificationCenter.default.post(
                            name: Self.autoPauseStateChanged,
                            object: nil
                        )
                    }
                    return false
                }
            } catch {
                NSLog(
                    "Clipa async duplicate check failed: \(error.localizedDescription)"
                )
                return false
            }
        }

        guard !isClearingHistory else {
            NSLog("Clipa dropped a capture that crossed a history clear")
            return false
        }

        do {
            let outcome = try await database.insertClip(
                prepared,
                captureStillCurrent: { [captureEpoch] in
                    guard let captureEpoch else { return true }
                    return ClipboardMonitor.shared.isCurrentCapture(captureEpoch)
                }
            )
            if outcome.inserted {
                upsert(outcome.clip)
                await trimToLimitAsync()
            } else {
                if let data = prepared.imageData,
                   try await database.hasImageData(
                       dbID: outcome.clip.dbID
                   ) == false {
                    var adoptedClip: Clip?
                    do {
                        adoptedClip = try await database.updateImage(
                            dbID: outcome.clip.dbID,
                            data: data,
                            format: prepared.imageFormat
                        )
                    } catch {
                        NSLog(
                            "Clipa async image adoption failed: \(error.localizedDescription)"
                        )
                    }
                    if let adoptedClip {
                        upsert(adoptedClip)
                        return outcome.inserted
                    }
                }
                upsert(outcome.clip)
            }
            return outcome.inserted
        } catch DatabaseError.historyClearInProgress {
            NSLog("Clipa dropped a capture that crossed a history clear")
            return false
        } catch {
            NSLog(
                "Clipa async insert failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    func togglePrivate(_ item: Clip) -> Bool {
        guard !isClearingHistory else { return false }
        return togglePrivate(dbID: item.dbID)
    }

    @discardableResult
    func togglePrivate(dbID: Int64) -> Bool {
        guard !isClearingHistory else { return false }
        guard let database,
              let current = clip(dbID: dbID) else { return false }
        do {

            let updated: Clip? = try runDB(database) { db in
                try await db.updatePrivate(
                    dbID: dbID,
                    isPrivate: !current.isPrivate
                )
            }
            guard let updated else { return false }
            upsert(updated)
            return true
        } catch {
            NSLog("Clipa private update failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func togglePrivateAsync(_ item: Clip) async -> Bool {
        await togglePrivateAsync(dbID: item.dbID)
    }

    @MainActor
    @discardableResult
    func togglePrivateAsync(dbID: Int64) async -> Bool {
        guard !isClearingHistory else { return false }
        guard let database,
              let current = clip(dbID: dbID) else { return false }
        do {
            guard let updated = try await database.updatePrivate(
                dbID: dbID,
                isPrivate: !current.isPrivate
            ) else { return false }

            if updated.kind == .image,
               let raw = try await database.imageData(dbID: dbID) {
                let data: Data = try updated.isPrivate
                    ? StoreCrypto.sealDataForStorage(raw)
                    : {
                        guard let plain = StoreCrypto.openDataStored(raw) else {
                            throw StoreCrypto.Failure.authenticationFailed
                        }
                        return plain
                    }()
                _ = try await database.updateImage(
                    dbID: dbID,
                    data: data,
                    format: updated.imageFormat
                )
            }
            upsert(updated)
            return true
        } catch {
            NSLog(
                "Clipa async private update failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    @discardableResult
    func reclassifyPending(limit: Int = 200) -> Bool {
        guard !isClearingHistory else { return false }
        guard let database else { return false }
        do {
            let changed = try runDB(database) { db in
                try await db.reclassifyPending(limit: limit)
            }
            if changed > 0 {
                reloadFromDatabase()
            }
            return changed > 0
        } catch {
            NSLog(
                "Clipa reclassification failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    @MainActor
    @discardableResult
    func reclassifyPendingAsync(limit: Int = 200) async -> Bool {
        guard !isClearingHistory else { return false }
        guard let database else { return false }
        do {
            let changed = try await database.reclassifyPending(limit: limit)
            if changed > 0 {
                reloadFromDatabase()
            }
            return changed > 0
        } catch {
            NSLog(
                "Clipa background reclassification failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    @MainActor
    @discardableResult
    func importLegacyImagesAsync(batchSize: Int = 50) async -> Bool {
        guard !isClearingHistory, let database else { return false }
        var handled = 0
        do {
            while true {
                let result = try await database.importLegacyImages(
                    limit: batchSize
                )
                handled += result.migrated + result.missing
                if result.remaining == 0
                    || (result.migrated + result.missing) == 0 {
                    break
                }
            }
            if handled > 0 {
                reloadFromDatabase()
            }
            return handled > 0
        } catch {
            NSLog(
                "Clipa legacy image import failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    @MainActor
    func migrateImagesToOwnTableAsync(batchSize: Int = 20) async -> Bool {
        guard !isClearingHistory, let database else { return false }
        do {
            var moved = 0
            var batches = 0
            while true {
                let result = try await database.migrateClipImages(
                    limit: batchSize
                )
                moved += result.moved
                batches += 1
                if batches % 10 == 0, result.remaining > 0 {
                    NSLog(
                        "Clipa image storage migration: moved=\(moved)"
                            + " remaining=\(result.remaining)"
                    )
                }
                if result.remaining == 0 || result.moved == 0 { break }
            }
            if !(try await database.clipImagesCompactionDone()) {
                NSLog("Clipa image storage migration: compacting database")
                try await database.compactAfterImageMigration()
            }
            if moved > 0 {
                NSLog("Clipa image storage migration moved \(moved) images")
            }
            return moved > 0
        } catch {
            NSLog(
                "Clipa image storage migration failed: "
                    + error.localizedDescription
            )
            return false
        }
    }

    @discardableResult
    func importLegacyImages(batchSize: Int = 50) -> Bool {
        guard !isClearingHistory, let database else { return false }
        var handled = 0
        do {
            while true {
                let result = try runDB(database) { db in
                    try await db.importLegacyImages(limit: batchSize)
                }
                handled += result.migrated + result.missing
                if result.remaining == 0
                    || (result.migrated + result.missing) == 0 {
                    break
                }
            }
            if handled > 0 {
                reloadFromDatabase()
            }
            return handled > 0
        } catch {
            NSLog(
                "Clipa legacy image import failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    func setNote(_ note: String?, for item: Clip) -> Bool {
        guard !isClearingHistory else { return false }
        guard let database else { return false }
        let trimmed = (note ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated: Clip? = try runDB(database) { db in
                try await db.updateNote(
                    dbID: item.dbID,
                    note: trimmed
                )
            }
            guard let updated else { return false }
            upsert(updated)
            return true
        } catch {
            NSLog("Clipa note update failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func setNoteAsync(_ note: String?, for item: Clip) async -> Bool {
        guard !isClearingHistory else { return false }
        guard let database else { return false }
        let trimmed = (note ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let updated = try await database.updateNote(
                dbID: item.dbID,
                note: trimmed
            ) else { return false }
            upsert(updated)
            return true
        } catch {
            NSLog(
                "Clipa async note update failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    @discardableResult
    func delete(_ item: Clip) -> ClipDeleteResult {
        guard !isClearingHistory else { return .failed }
        return remove(dbIDs: [item.dbID])
    }

    @discardableResult
    func delete(ids: Set<UUID>) -> ClipDeleteResult {
        guard !isClearingHistory else { return .failed }
        let dbIDs = ids.compactMap { clipsByUUID[$0] }
        return remove(dbIDs: dbIDs)
    }

    @discardableResult
    func hide(_ item: Clip) -> ClipDeleteResult {
        delete(item)
    }

    func clearAll() {
        guard !isClearingHistory, let database else { return }
        isClearingHistory = true
        defer { isClearingHistory = false }
        ClipboardMonitor.shared.beginClearBarrier()
        do {
            let removed = try runDB(database) { db in
                try await db.clearAll(
                    secureErase: self.settings.secureEraseHistoryOnClear
                )
            }
            let removedIDs = Set(removed.map(\.dbID))
            clipsByDBID = clipsByDBID.filter { !removedIDs.contains($0.key) }
            clipsByUUID = clipsByUUID.filter { !removedIDs.contains($0.value) }
            mutateItems { $0.removeAll { removedIDs.contains($0.dbID) } }
            for row in removed {
                memoryIndex.remove(dbID: row.dbID)
            }
            reconcileAutoPauseAfterHistoryChange()
        } catch {
            NSLog("Clipa clear failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    @discardableResult
    func clearAllAsync() async -> ClipClearResult {
        guard !isClearingHistory else { return .busy }
        isClearingHistory = true
        defer { isClearingHistory = false }

        ClipboardMonitor.shared.beginClearBarrier()
        guard let database else { return .failed }
        do {
            let removed = try await database.clearAll(
                secureErase: settings.secureEraseHistoryOnClear
            )
            let removedIDs = Set(removed.map(\.dbID))
            clipsByDBID = clipsByDBID.filter { !removedIDs.contains($0.key) }
            clipsByUUID = clipsByUUID.filter { !removedIDs.contains($0.value) }
            mutateItems { $0.removeAll { removedIDs.contains($0.dbID) } }
            for row in removed {
                memoryIndex.remove(dbID: row.dbID)
            }
            reconcileAutoPauseAfterHistoryChange()
            return .cleared(deleted: removed.count)
        } catch {
            NSLog("Clipa async clear failed: \(error.localizedDescription)")
            return .failed
        }
    }

    func discardUncaptured(_ draft: NewClip) {}

    @MainActor
    @discardableResult
    func acceptCaptured(
        _ draft: NewClip,
        captureEpoch: UInt64
    ) async -> Bool {
        guard ClipboardMonitor.shared.isCurrentCapture(captureEpoch) else {
            discardUncaptured(draft)
            return false
        }
        return await insertCaptureAsync(draft, captureEpoch: captureEpoch)
    }

    var clearSummary: ClipClearSummary {
        return ClipClearSummary(
            removable: items.count,
            privateCount: items.lazy.filter(\.isPrivate).count
        )
    }

    @MainActor
    func deleteAsync(_ item: Clip) async -> ClipDeleteResult {
        guard !isClearingHistory else { return .failed }
        return await removeAsync(dbIDs: [item.dbID])
    }

    @MainActor
    func deleteAsync(ids: Set<UUID>) async -> ClipDeleteResult {
        guard !isClearingHistory else { return .failed }
        let dbIDs = ids.compactMap { clipsByUUID[$0] }
        return await removeAsync(dbIDs: dbIDs)
    }

    @MainActor
    @discardableResult
    private func removeAsync(dbIDs: [Int64]) async -> ClipDeleteResult {
        guard !isClearingHistory else { return .failed }
        guard !dbIDs.isEmpty else { return .deleted(count: 0) }
        guard let database else { return .failed }
        do {
            let deleted = try await database.deleteClips(dbIDs: dbIDs)
            let deletedIDs = Set(deleted.map(\.dbID))
            clipsByDBID = clipsByDBID.filter { !deletedIDs.contains($0.key) }
            clipsByUUID = clipsByUUID.filter { !deletedIDs.contains($0.value) }
            mutateItems { $0.removeAll { deletedIDs.contains($0.dbID) } }
            for clip in deleted {
                memoryIndex.remove(dbID: clip.dbID)
            }
            reconcileAutoPauseAfterHistoryChange()
            return .deleted(count: deleted.count)
        } catch {
            NSLog("Clipa async delete failed: \(error.localizedDescription)")
            return .failed
        }
    }

    @discardableResult
    private func remove(dbIDs: [Int64]) -> ClipDeleteResult {
        guard !isClearingHistory else { return .failed }
        guard !dbIDs.isEmpty else { return .deleted(count: 0) }
        guard let database else { return .failed }
        do {
            let deleted = try runDB(database) { db in
                try await db.deleteClips(dbIDs: dbIDs)
            }
            let deletedIDs = Set(deleted.map(\.dbID))
            clipsByDBID = clipsByDBID.filter { !deletedIDs.contains($0.key) }
            clipsByUUID = clipsByUUID.filter { !deletedIDs.contains($0.value) }
            mutateItems { $0.removeAll { deletedIDs.contains($0.dbID) } }
            for clip in deleted {
                memoryIndex.remove(dbID: clip.dbID)
            }
            reconcileAutoPauseAfterHistoryChange()
            return .deleted(count: deleted.count)
        } catch {
            NSLog("Clipa delete failed: \(error.localizedDescription)")
            return .failed
        }
    }

    private func trimToLimit() {
        let limit = settings.historyLimit
        guard limit > 0 else { return }
        let removable = items
        let overflow = removable.count - limit
        guard overflow > 0 else { return }
        let removed = removable.suffix(overflow)
        _ = remove(dbIDs: removed.map(\.dbID))
    }

    @MainActor
    private func trimToLimitAsync() async {
        let limit = settings.historyLimit
        guard limit > 0 else { return }
        let removable = items
        let overflow = removable.count - limit
        guard overflow > 0 else { return }
        let removed = removable.suffix(overflow)
        _ = await removeAsync(dbIDs: removed.map(\.dbID))
    }

    var historyCount: Int { items.count }

    func applyHistoryLimitNow() {
        trimToLimit()
        reconcileAutoPauseAfterHistoryChange()
    }

    func reconcileAutoPauseAfterHistoryChange() {
        guard settings.autoPausedByLimit, settings.pauseRecording else { return }
        let limit = settings.historyLimit
        guard limit > 0, historyCount < limit else { return }
        settings.pauseRecording = false
        settings.autoPausedByLimit = false
        NotificationCenter.default.post(
            name: Self.autoPauseStateChanged,
            object: nil
        )
    }

    private func mutateItems(_ body: (inout [Clip]) -> Void) {
        objectWillChange.send()
        body(&storedItems)
        itemsDidChange.send()
    }

    private func replaceAll(_ clips: [Clip]) {
        let sorted = clips.sorted(by: Self.recentlyUsedFirst)
        mutateItems { $0 = sorted }
        clipsByDBID = Dictionary(
            uniqueKeysWithValues: sorted.map { ($0.dbID, ClipBox($0)) }
        )
        clipsByUUID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.dbID) })
        memoryIndex.rebuild(from: sorted)
    }

    private func upsert(_ clip: Clip) {
        clipsByDBID[clip.dbID] = ClipBox(clip)
        clipsByUUID[clip.id] = clip.dbID

        memoryIndex.update(clip: clip)
        mutateItems { items in
            guard let oldIndex = items.firstIndex(where: {
                $0.dbID == clip.dbID
            }) else {
                items.insert(
                    clip,
                    at: Self.insertionIndex(for: clip, in: items)
                )
                return
            }
            let previous = items[oldIndex]
            items[oldIndex] = clip

            guard previous.lastCopiedAt != clip.lastCopiedAt else { return }
            items.remove(at: oldIndex)
            items.insert(
                clip,
                at: Self.insertionIndex(for: clip, in: items)
            )
        }
    }

    private static func insertionIndex(
        for clip: Clip,
        in items: [Clip]
    ) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let mid = low + (high - low) / 2
            if Self.recentlyUsedFirst(items[mid], clip) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func recentlyUsedFirst(_ lhs: Clip, _ rhs: Clip) -> Bool {
        if lhs.lastCopiedAt != rhs.lastCopiedAt {
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
        return lhs.dbID > rhs.dbID
    }

    private func runDB<T>(
        _ database: DatabaseManager,
        _ operation: @escaping @Sendable (DatabaseManager) async throws -> T
    ) throws -> T {
        try DatabaseSync.run(database, operation)
    }

    private static func computeContentHash(
        for draft: NewClip
    ) -> String? {
        switch draft.kind {
        case .image:
            guard let data = draft.imageData, !data.isEmpty else { return nil }
            return ContentHasher.hash(data: data)
        case .file:
            if !draft.fileURLs.isEmpty {
                return ContentHasher.hash(fileURLs: draft.fileURLs)
            }
            return ContentHasher.hash(text: draft.text)
        default:
            return ContentHasher.hash(text: draft.text)
        }
    }

    func imageData(for item: Clip) -> Data? {
        guard item.kind == .image, let database else { return nil }
        let raw = try? runDB(database) { db in
            try await db.imageData(dbID: item.dbID)
        }
        guard let raw else { return nil }

        return StoreCrypto.openDataStored(raw)
    }

    func imageDataAsync(for item: Clip) async -> Data? {
        guard item.kind == .image, let database else { return nil }
        guard let raw = try? await database.imageData(dbID: item.dbID)
        else { return nil }
        return StoreCrypto.openDataStored(raw)
    }

    @MainActor
    func sealPrivateImagesIfNeeded() {
        guard let database else { return }
        var sealed = 0
        var failed = 0
        for item in items where item.isPrivate && item.kind == .image {
            let raw = try? runDB(database) { db in
                try await db.imageData(dbID: item.dbID)
            }
            guard let raw, !raw.isEmpty, !StoreCrypto.isSealedData(raw) else {
                continue
            }
            do {
                let sealedData = try StoreCrypto.sealDataForStorage(raw)
                _ = try runDB(database) { db in
                    try await db.updateImage(
                        dbID: item.dbID,
                        data: sealedData,
                        format: item.imageFormat
                    )
                }
                sealed += 1
            } catch {
                failed += 1
                NSLog(
                    "Clipa private image seal failed: "
                        + "\(error.localizedDescription)"
                )
            }
        }
        if sealed > 0 || failed > 0 {
            NSLog("Clipa private image seal: \(sealed) sealed, \(failed) failed")
        }
    }

    func hasImageData(for item: Clip) -> Bool {
        guard item.kind == .image, let database else { return false }
        return (try? runDB(database) { db in
            try await db.hasImageData(dbID: item.dbID)
        }) ?? false
    }

    func hasImageDataAsync(for item: Clip) async -> Bool {
        guard item.kind == .image, let database else { return false }
        return (try? await database.hasImageData(dbID: item.dbID)) ?? false
    }

    func assetAvailability(for item: Clip) -> ClipAssetAvailability {
        switch item.kind {
        case .image:
            return hasImageData(for: item) ? .available : .unavailable
        case .file:
            guard !item.fileURLs.isEmpty else { return .unavailable }
            let allExist = item.fileURLs.allSatisfy { url in
                fileManager.fileExists(atPath: url.path)
            }
            return allExist ? .available : .unavailable
        default:
            return .available
        }
    }

    func assetAvailabilityAsync(
        for item: Clip
    ) async -> ClipAssetAvailability {
        switch item.kind {
        case .image:
            return await hasImageDataAsync(for: item)
                ? .available
                : .unavailable
        case .file:
            guard !item.fileURLs.isEmpty else { return .unavailable }
            let allExist = item.fileURLs.allSatisfy { url in
                fileManager.fileExists(atPath: url.path)
            }
            return allExist ? .available : .unavailable
        default:
            return .available
        }
    }

    @discardableResult
    func replaceAllForTesting(_ drafts: [NewClip]) -> [Clip] {
        guard let database else { return [] }
        do {
            let inserted = try runDB(database) { db in
                try await db.replaceAllForTesting(drafts)
            }
            replaceAll(inserted)
            return inserted
        } catch {
            NSLog("Clipa replace-for-testing failed: \(error.localizedDescription)")
            return []
        }
    }
}
