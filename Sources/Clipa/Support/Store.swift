import Combine
import Foundation

/// Reference box for one clip in the store's lookup table.
///
/// A search snapshot shares these dictionaries so it can materialize results
/// off-main. Without the box, the first write after a snapshot copies every
/// entry — ~100k `Clip` values, each with several reference-counted strings —
/// measured at 19ms. With it, the copy only retains pointers.
final class ClipBox {
    let clip: Clip

    init(_ clip: Clip) {
        self.clip = clip
    }
}

/// Result of a clip deletion request. `deleted(count:)` is reported even when
/// count is zero (nothing matched); `failed` means the database call errored.
enum ClipDeleteResult: Equatable {
    case deleted(count: Int)
    case failed
}

/// Result of a history clear request. Returning counts lets the menu surface
/// an explicit success/failure message instead of failing silently in logs.
enum ClipClearResult: Equatable {
    case cleared(deleted: Int)
    case busy
    case failed
}

/// Pre-flight view of a clear request, used by the menu confirmation.
struct ClipClearSummary: Equatable {
    let removable: Int
    let privateCount: Int

    var requiresAuthentication: Bool {
        privateCount > 0
    }
}

/// Whether a clip's backing asset is currently usable for copying/preview.
enum ClipAssetAvailability: Equatable {
    case available
    case unavailable
}

/// Why the persistent store is unusable. Presentation-level only: in every
/// case the history on disk is left untouched.
enum ClipStoreUnavailabilityReason: Equatable {
    case keyUnavailable
    /// `clips.sqlite` exists but could not be opened (damaged, locked, …).
    case databaseUnreadable
    /// The database opened but reading history failed (page-level damage).
    case historyUnreadable
    /// Schema upgrade threw. The file is usually intact; a retry may finish it.
    case migrationFailed
    /// No database could be created at all (unwritable directory, disk full).
    case storageUnavailable
}

/// Health of the persistent store as surfaced to the UI.
enum ClipStoreAvailability: Equatable {
    /// Reading and writing as usual. A fresh install with zero clips is ready
    /// too — an empty history is only *empty*, never *broken*.
    case ready
    /// Clipa refuses to write and tells the user the history is not gone.
    case unavailable(reason: ClipStoreUnavailabilityReason, detail: String)

    var isReady: Bool { self == .ready }

    var reason: ClipStoreUnavailabilityReason? {
        guard case .unavailable(let reason, _) = self else { return nil }
        return reason
    }
}

/// Main-actor memory store for the panel. This class no longer touches SQL:
/// persistence goes through `DatabaseManager`, and its searchable text lives
/// in a dedicated `MemorySearchIndex` rebuilt/updated alongside `items`.
///
/// Ordering rule: `last_copied_at DESC, db_id DESC` (no `position` rewrites).
final class ClipStore: ObservableObject {
    /// The active workspace's store. Replaced by `WorkspaceManager` when the
    /// user switches workspaces; everything that reads it late (capture,
    /// search, menus) follows the switch automatically. Anything that
    /// *captured* the instance must be rebuilt — today that is the panel, the
    /// snippet store and the availability subscription in `AppDelegate`.
    ///
    /// Opened against the workspace the registry marks active, not always the
    /// default one. This is a static, so it is built the first time *anything*
    /// asks for it — including the panel that `AppDelegate` builds during
    /// `applicationDidFinishLaunching`, which runs before the launch code gets
    /// to swap the store. Resolving the workspace here means that first build
    /// already opens the right database instead of loading the whole default
    /// history (~283MB for 103k rows) and keeping it alive all session.
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

    /// Posted after `shared` points at another workspace's store.
    ///
    /// The capture path, the menus and every late reader resolve `shared` per
    /// use and follow a switch for free. Components that *captured* the
    /// instance have to be told — the panel is the one that matters — and they
    /// listen for this rather than depending on the switcher to call them:
    /// forgetting that call shipped once, and the symptom was a panel still
    /// rendering the workspace the user had just left (129 rows instead of
    /// 103k) while every capture and every edit made from the page landed in
    /// the new one.
    static let sharedReplacedNotification = Notification.Name(
        "ClipaStoreSharedReplaced"
    )

    /// Posted (at most once per failure) when a capture was dropped because the
    /// store is unavailable. Lets the menu bar explain why copies stopped being
    /// recorded without the store reaching into the UI.
    static let captureRejectedNotification = Notification.Name(
        "ClipaStoreCaptureRejected"
    )

    /// Posted whenever the history-limit pause starts or ends, so the menu bar
    /// and panel can explain why recording stopped.
    static let autoPauseStateChanged = Notification.Name(
        "ClipaAutoPauseStateChanged"
    )

    /// Backing storage for `items`, deliberately not `@Published`.
    ///
    /// Writing through a property wrapper's subscript (`items[i] = clip`)
    /// reads the array out, mutates the copy and writes it back, so the
    /// wrapper still holds a reference to the old buffer and every single-row
    /// change copies the whole array — measured at 13ms for 100k rows, which
    /// was the entire cost of a pin toggle once the re-sort was gone.
    /// Mutating this stored property in place keeps the buffer uniquely
    /// referenced; `mutateItems` sends the notifications `@Published` used to.
    private var storedItems: [Clip] = []

    var items: [Clip] { storedItems }

    /// Fires after `items` changes, replacing the `$items` publisher.
    private let itemsDidChange = PassthroughSubject<Void, Never>()

    var itemsPublisher: AnyPublisher<Void, Never> {
        itemsDidChange.eraseToAnyPublisher()
    }

    /// True while a clear transaction is running. History-mutating UI actions
    /// are rejected during this window so a pin/delete cannot race the clear.
    @Published private(set) var isClearingHistory = false
    /// Never `.ready` while the database is unusable: a damaged store must not
    /// render as a normal fresh install with an empty history.
    @Published private(set) var availability: ClipStoreAvailability = .ready

    /// Pre-normalized "body + note" entries used by SearchEngine.
    private(set) var memoryIndex = MemorySearchIndex()

    /// Reassigned only by `retryDatabaseOpen()`.
    private(set) var database: DatabaseManager?
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private var settingsStore: SettingsStore?
    private var clipsByDBID: [Int64: ClipBox] = [:]
    private var clipsByUUID: [UUID: Int64] = [:]
    /// One explanation per failure episode, not one per dropped copy.
    private var hasAnnouncedCaptureRejection = false

    var settings: SettingsStore { settingsStore ?? .shared }

    /// Directory holding clips.sqlite (clips, snippets and search learning),
    /// plus the legacy images/ and snippets.json files kept for rollback.
    var dataDirectory: URL { baseDirectory }

    init(baseDirectory: URL? = nil, settingsStore: SettingsStore? = nil) {
        self.settingsStore = settingsStore
        let base = baseDirectory ?? Self.defaultBaseDirectory()
        self.baseDirectory = base
        try? fileManager.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        // A missing file is a fresh install, not a fault. Capture this before
        // opening, because DatabaseManager creates the file as a side effect.
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
           case .databaseKeyUnavailable = databaseError { return .keyUnavailable }
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

    /// Test/probe hook so `--selftest` and the CLI probes can never touch the
    /// user's real history. Must be assigned before `ClipStore.shared` is
    /// first used; `main.swift` does this for every non-GUI mode.
    static var defaultBaseDirectoryOverride: URL?

    // MARK: - Memory state

    func reloadFromDatabase() {
        guard let database else {
            // Keep the reason recorded by the failed open; only a store that
            // somehow lost its handle without a recorded failure needs the
            // generic fallback.
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

    /// Reopens the database after a failure. Read-only with respect to the
    /// user's data: nothing is repaired, moved or deleted here.
    @discardableResult
    func retryDatabaseOpen() -> Bool {
        if availability.isReady, database != nil { return true }
        let databasePath = DatabaseManager.databaseURL(in: baseDirectory)
        let databaseExisted = fileManager.fileExists(atPath: databasePath.path)
        // Drop the previous handle before opening another one. `availability`
        // can be `.unavailable` while `database` is still set (an unreadable
        // history keeps the manager around), and opening a second connection to
        // the same file made two writers: captures then failed with
        // SQLITE_BUSY and were dropped, and the VACUUM behind a secure erase
        // failed silently under the stale handle's read lock.
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

    /// Copy-on-write views used by `SearchSnapshot` so a search can run off
    /// the main actor without touching main-thread-confined state.
    var clipsByDBIDSnapshot: [Int64: ClipBox] { clipsByDBID }

    /// O(1) value-type snapshot of everything local search reads. Handing one
    /// of these to a background search is what keeps the main actor free
    /// while FTS recall, validation and ranking run.
    var searchSnapshot: SearchSnapshot { SearchSnapshot(store: self) }

    func clip(id: UUID) -> Clip? {
        guard let dbID = clipsByUUID[id] else { return nil }
        return clipsByDBID[dbID]?.clip
    }

    /// Persist a captured clipboard payload.
    ///
    /// - Returns: `true` when a new row was inserted; `false` when the event
    ///   touched an existing duplicate or was paused at the history limit.
    @discardableResult
    func insert(_ draft: NewClip, allowAutoPause: Bool = true) -> Bool {
        var prepared = draft
        if prepared.contentHash == nil {
            prepared.contentHash = Self.computeContentHash(for: prepared)
        }
        // A capture that lands while the user's "clear history" is running
        // would be inserted after the delete and survive it; the clear has to
        // be the last word on what the history contains.
        guard !isClearingHistory else {
            NSLog("Clipa dropped a capture that arrived during a history clear")
            return false
        }
        guard availability.isReady, let database else {
            rejectCaptureWhileUnavailable(prepared)
            return false
        }

        // Duplicate touches do not grow history, so they are allowed even at
        // the auto-pause cap; only genuinely new rows trigger the pause.
        let limitExceeded =
            allowAutoPause
            && settings.autoPauseAtLimit
            && settings.historyLimit > 0
            && historyCount >= settings.historyLimit
        if limitExceeded {
            // Hoisted out of the closure: capturing the mutable `prepared` in a
            // concurrently-executing block is an error in Swift 6.
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
                // A duplicate touched the old row. When that row has no image
                // bytes any more, adopt this capture's bytes so the row can
                // recover instead of being permanently broken.
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

    /// Explains a capture that was refused because the store is unavailable,
    /// once per failure episode so repeated copies do not spam the panel.
    private func rejectCaptureWhileUnavailable(_ draft: NewClip) {
        guard !hasAnnouncedCaptureRejection else { return }
        hasAnnouncedCaptureRejection = true
        NSLog("Clipa rejected a capture: store unavailable")
        NotificationCenter.default.post(
            name: Self.captureRejectedNotification,
            object: self
        )
    }

    /// Capture-path insertion used by ClipboardMonitor. The synchronous
    /// variant above is kept for tests/legacy callers; this one never blocks
    /// the main thread while SQLite performs the write.
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

        // Re-checked after the duplicate lookup above suspended. The clear
        // barrier can be raised while this capture waits on the actor, and a row
        // written *after* `clearAll` finished would survive the very clear the
        // user just confirmed — the epoch check in `acceptCaptured` ran before
        // this point and cannot see it.
        //
        // P1 修复（2026-10-02）：epoch 复查**下沉进 actor 任务**（见
        // `insertClip(_:captureStillCurrent:)`），与 INSERT 原子化；这里的
        // guard 只是廉价的提前拒绝。
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
            // 图片字节的 seal/还原已并入 updatePrivate 的同一事务
            // （P2 修复 2026-10-03），这里不再有第二笔写。
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
            // 图片改写：与同步路径相同的同事务语义（见 togglePrivate(dbID:)）。
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

    /// Synchronous reclassification hook for tests/migration probes. The app
    /// normally uses `reclassifyPendingAsync`.
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

    /// Runs a bounded, low-priority reclassification pass, then reloads the
    /// memory store only when rows actually changed.
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

    /// Drains the v6 → v7 image import in the background, one bounded batch
    /// at a time. Launch must never read every legacy image file at once.
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

    /// v10: moves inline image bytes into `clip_images` in bounded batches,
    /// then compacts the file once.
    ///
    /// Runs after launch rather than during it: a library with gigabytes of
    /// screenshots would otherwise delay the panel, and the compaction that
    /// makes the space (and the scan speed) come back is a whole-file
    /// operation. Every batch commits, so an interrupted run simply resumes on
    /// the next launch.
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

    /// Synchronous hook for tests and migration probes.
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

    /// UI-path history clear. Suspends while SQLite runs the transaction.
    @MainActor
    @discardableResult
    func clearAllAsync() async -> ClipClearResult {
        guard !isClearingHistory else { return .busy }
        isClearingHistory = true
        defer { isClearingHistory = false }
        // Anything already copied before this point is an old generation and
        // must not reappear after the clear finishes.
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

    /// Drops a capture that was produced before the most recent clear barrier.
    /// Image bytes now live on the draft, so nothing on disk needs cleanup.
    func discardUncaptured(_ draft: NewClip) {}

    /// Accepts a processed capture only when it belongs to the current clear
    /// generation; otherwise its already-written image is discarded.
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

    /// Counts shown before "clear history" runs.
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

    /// Async history-limit trimming. Only called from the capture async path
    /// so a large database never stalls the main thread after each capture.
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

    /// Rows the history limit applies to.
    var historyCount: Int { items.count }

    /// Applies the configured limit immediately, without waiting for the next
    /// capture. Used when the user lowers the limit and confirms the deletion.
    func applyHistoryLimitNow() {
        trimToLimit()
        reconcileAutoPauseAfterHistoryChange()
    }

    /// UI-facing limit changes report persistence failures and keep disk work
    /// on the database executor.
    @MainActor
    func trimHistory(to limit: Int) async -> ClipDeleteResult {
        guard !isClearingHistory else { return .failed }
        guard limit > 0, items.count > limit else { return .deleted(count: 0) }
        let ids = Set(items.suffix(items.count - limit).map(\.id))
        return await deleteAsync(ids: ids)
    }

    /// Ends an automatic pause once the user makes room by deleting, clearing
    /// or pinning rows — "free up space and keep going" without a relaunch.
    ///
    /// Also runs right after a workspace switch, because the pause it may have
    /// to end belongs to the workspace that set the limit: landing in a
    /// workspace that is under *its own* limit keeps recording.
    ///
    /// Only ever touches a pause the limit started: a manual pause keeps
    /// `autoPausedByLimit == false` and is left alone.
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

    // MARK: - Apply helpers

    /// Single entry point for mutations of `items`.
    ///
    /// Keeps the notification behaviour `@Published` had (a will-level
    /// `objectWillChange`, then the items publisher) while letting the array
    /// mutate in place instead of being copied through a property wrapper.
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

    /// Inserts or replaces one row, keeping `items` sorted by
    /// `recentlyUsedFirst`.
    ///
    /// That order is an invariant other code depends on — `trimToLimit()`
    /// treats the tail as the oldest rows, and the panel groups the list by
    /// recency — so it is maintained here instead of being restored by a full
    /// `sort()` after every change. Re-sorting 100k rows on each edit cost
    /// ~42ms even when nothing moved, which is every metadata-only update
    /// (pin, private, note): those never touch `lastCopiedAt`, the only
    /// ordering key that can change.
    private func upsert(_ clip: Clip) {
        clipsByDBID[clip.dbID] = ClipBox(clip)
        clipsByUUID[clip.id] = clip.dbID
        // `MemorySearchIndex.update` and `.insert` are the same operation
        // (both write the entry for this dbID), so the branches need no
        // separate call.
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
            // `dbID` is immutable and only the tie-breaker, so the row can
            // move only when its `lastCopiedAt` changed (a duplicate was
            // re-copied).
            guard previous.lastCopiedAt != clip.lastCopiedAt else { return }
            items.remove(at: oldIndex)
            items.insert(
                clip,
                at: Self.insertionIndex(for: clip, in: items)
            )
        }
    }

    /// Position that keeps `items` ordered by `recentlyUsedFirst`: binary
    /// search, so one changed row costs O(log n) comparisons instead of a
    /// full re-sort.
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

    // MARK: - Content hashing

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

    // MARK: - Image helpers

    /// Loads the stored image bytes for preview and clipboard writes. Blobs
    /// never travel with the row list, so this is the only place that pulls
    /// image data out of SQLite.
    func imageData(for item: Clip) -> Data? {
        guard item.kind == .image, let database else { return nil }
        let raw = try? runDB(database) { db in
            try await db.imageData(dbID: item.dbID)
        }
        guard let raw else { return nil }
        // 私密图片以密文落盘（2026-10-02）：读取按 magic 自识别解密；
        // 解不开返回 nil（绝不把密文当图片交出去），原因进 lastFailureDescription。
        return StoreCrypto.openDataStored(raw)
    }

    /// Async twin of `imageData(for:)` for callers that already run inside a
    /// `Task`.
    ///
    /// The synchronous version blocks its thread in `DatabaseSync.run`; doing
    /// that from a Swift-concurrency thread is what deadlocked the app when
    /// several image cards (plus a copy) read at once — see `DatabaseSync`.
    /// Awaiting the actor directly costs nothing extra and cannot starve the
    /// pool.
    func imageDataAsync(for item: Clip) async -> Data? {
        guard item.kind == .image, let database else { return nil }
        guard let raw = try? await database.imageData(dbID: item.dbID)
        else { return nil }
        return StoreCrypto.openDataStored(raw)
    }

    /// 一次性补加密（2026-10-02）：加密引入之前"设为私密"的条目，图片是
    /// 明文落盘的。启动时跑一遍：凡私密且未密封的图片行就地 seal。
    /// 失败只记日志、下次启动重试——明文原图保持原样，读取不受影响，
    /// 绝不因为迁移失败而破坏数据。
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

    /// Async twin of `hasImageData(for:)`. See `imageDataAsync(for:)`.
    func hasImageDataAsync(for item: Clip) async -> Bool {
        guard item.kind == .image, let database else { return false }
        return (try? await database.hasImageData(dbID: item.dbID)) ?? false
    }

    /// Unified availability check used before clipboard writes and previews.
    /// Images live inside Clipa and must still exist; files point at external
    /// source paths, so every stored URL must still exist.
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

    /// Async twin of `assetAvailability(for:)`. See `imageDataAsync(for:)`.
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

    // MARK: - Test / UI capture helpers

    /// Used only by `--selftest` / `--capture-ui`: replace the whole database
    /// content in one transaction (equivalent of a debug "Rebuild").
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
