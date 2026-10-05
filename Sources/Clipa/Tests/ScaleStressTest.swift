import AppKit
import Darwin
import Foundation
import ImageIO

enum ScaleMetrics {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
                / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }

    static func cpuNanos() -> UInt64 {
        var time = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0 else {
            return 0
        }
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func wallNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static let coreCount = ProcessInfo.processInfo.processorCount
    static let physicalMemory = ProcessInfo.processInfo.physicalMemory
}

final class ScaleSampler {
    private struct Sample {
        let at: UInt64
        let rss: UInt64
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var running = false
    private var thread: Thread?

    func start(interval: TimeInterval = 0.05) {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in
            while self?.isRunning == true {
                let sample = Sample(
                    at: ScaleMetrics.wallNanos(),
                    rss: ScaleMetrics.residentBytes()
                )
                self?.append(sample)
                Thread.sleep(forTimeInterval: interval)
            }
        }
        thread.name = "clipa.scale.sampler"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func append(_ sample: Sample) {
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    func peakRSS(from start: UInt64, to end: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        var peak: UInt64 = 0
        for sample in samples where sample.at >= start && sample.at <= end {
            peak = max(peak, sample.rss)
        }
        guard peak == 0 else { return peak }
        let before = samples.last { $0.at <= start }?.rss ?? 0
        let after = samples.first { $0.at >= end }?.rss ?? 0
        return max(before, after)
    }
}

struct ScaleFixture: Codable {
    let dbID: Int64

    let category: String

    let keyword: String
    let bytes: Int
}

struct ScaleOpStats {
    let name: String
    var wallMS: [Double] = []
    var cpuPercent: [Double] = []
    var peakRSSBytes: [UInt64] = []
    var rssDeltaBytes: [Int64] = []
    var failures = 0

    var count: Int { wallMS.count }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int(Double(sorted.count) * fraction))
        )
        return sorted[index]
    }

    var p50: Double { percentile(wallMS, 0.5) }
    var p95: Double { percentile(wallMS, 0.95) }
    var maxMS: Double { wallMS.max() ?? 0 }

    var avgCPU: Double {
        cpuPercent.isEmpty
            ? 0
            : cpuPercent.reduce(0, +) / Double(cpuPercent.count)
    }

    var peakRSS: UInt64 { peakRSSBytes.max() ?? 0 }

    var avgRSSDeltaBytes: Double {
        rssDeltaBytes.isEmpty
            ? 0
            : Double(rssDeltaBytes.reduce(Int64(0)) { $0 + $1 })
                / Double(rssDeltaBytes.count)
    }
}

final class ScaleBenchRecorder {
    private let sampler: ScaleSampler
    private(set) var order: [String] = []
    private(set) var stats: [String: ScaleOpStats] = [:]

    init(sampler: ScaleSampler) {
        self.sampler = sampler
    }

    func measure(_ name: String, rounds: Int, _ body: () -> Bool) {
        prepare(name)
        for _ in 0..<rounds {
            record(name) { body() }
        }
    }

    func measureAsync(
        _ name: String,
        rounds: Int,
        _ body: () async -> Bool
    ) async {
        prepare(name)
        for _ in 0..<rounds {
            await recordAsync(name) { await body() }
        }
    }

    private func prepare(_ name: String) {
        guard stats[name] == nil else { return }
        order.append(name)
        stats[name] = ScaleOpStats(name: name)
    }

    private func record(_ name: String, _ body: () -> Bool) {
        let wallStart = ScaleMetrics.wallNanos()
        let cpuStart = ScaleMetrics.cpuNanos()
        let rssStart = ScaleMetrics.residentBytes()
        let ok = body()
        let wallEnd = ScaleMetrics.wallNanos()
        let cpuEnd = ScaleMetrics.cpuNanos()
        let rssEnd = ScaleMetrics.residentBytes()
        append(
            name,
            wallStart: wallStart,
            wallEnd: wallEnd,
            cpuStart: cpuStart,
            cpuEnd: cpuEnd,
            rssStart: rssStart,
            rssEnd: rssEnd,
            ok: ok
        )
    }

    private func recordAsync(_ name: String, _ body: () async -> Bool) async {
        let wallStart = ScaleMetrics.wallNanos()
        let cpuStart = ScaleMetrics.cpuNanos()
        let rssStart = ScaleMetrics.residentBytes()
        let ok = await body()
        let wallEnd = ScaleMetrics.wallNanos()
        let cpuEnd = ScaleMetrics.cpuNanos()
        let rssEnd = ScaleMetrics.residentBytes()
        append(
            name,
            wallStart: wallStart,
            wallEnd: wallEnd,
            cpuStart: cpuStart,
            cpuEnd: cpuEnd,
            rssStart: rssStart,
            rssEnd: rssEnd,
            ok: ok
        )
    }

    private func append(
        _ name: String,
        wallStart: UInt64,
        wallEnd: UInt64,
        cpuStart: UInt64,
        cpuEnd: UInt64,
        rssStart: UInt64,
        rssEnd: UInt64,
        ok: Bool
    ) {
        let wall = wallEnd > wallStart ? Double(wallEnd - wallStart) : 0
        let cpu = cpuEnd > cpuStart ? Double(cpuEnd - cpuStart) : 0
        let peak = max(
            max(rssStart, rssEnd),
            sampler.peakRSS(from: wallStart, to: wallEnd)
        )
        var entry = stats[name] ?? ScaleOpStats(name: name)
        entry.wallMS.append(wall / 1_000_000)
        entry.cpuPercent.append(wall > 0 ? cpu / wall * 100 : 0)
        entry.peakRSSBytes.append(peak)
        entry.rssDeltaBytes.append(
            Int64(bitPattern: peak) - Int64(bitPattern: rssStart)
        )
        if !ok { entry.failures += 1 }
        stats[name] = entry
    }
}

enum ScaleStressTest {
    static let sourceApp = "ClipaStress"
    private static let fixturesName = "scale-fixtures.json"

    private static func fixturesURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fixturesName)
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }

    private struct LoadItem {
        let draft: NewClip
        let category: String
        let keyword: String
        let bytes: Int
    }

    static func runLoad(
        directory: URL,
        imageCount: Int,
        bigImageCount: Int,
        bigImageMegabytes: Double,
        textCount: Int,
        seedValue: UInt64
    ) async -> Int32 {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = DatabaseManager.databaseURL(in: directory)
        let sizeBefore = fileSize(databaseURL)

        let database: DatabaseManager
        do {
            database = try DatabaseManager(baseDirectory: directory)
        } catch {
            print("[SCALE] cannot open store: \(error.localizedDescription)")
            return 1
        }

        print(
            "[SCALE] target \(databaseURL.path)"
                + " current=\(megabytes(sizeBefore))"
        )
        print(
            "[SCALE] loading images=\(imageCount)"
                + " (big=\(bigImageCount) x \(bigImageMegabytes)MB)"
                + " texts=\(textCount)"
        )

        var pending: [LoadItem] = []
        var pendingBytes = 0
        var fixtures: [ScaleFixture] = []
        let started = Date()

        func flush() async throws {
            guard !pending.isEmpty else { return }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            let results = try await database.insertClipBatch(
                batch.map(\.draft)
            )
            for (offset, dbID) in results.enumerated() {
                guard let dbID else { continue }
                let item = batch[offset]
                fixtures.append(
                    ScaleFixture(
                        dbID: dbID,
                        category: item.category,
                        keyword: item.keyword,
                        bytes: item.bytes
                    )
                )
            }
        }

        for index in 0..<textCount {
            let text = textSample(index)
            let keyword = Self.textKeyword(index)
            let draft = NewClip(
                kind: .text,
                text: text,
                sourceApp: sourceApp,
                contentHash: ContentHasher.hash(
                    text: "scale-text-\(seedValue)-\(index)"
                ),
                smartTag: .text,
                containsSensitive: false
            )
            pending.append(
                LoadItem(
                    draft: draft,
                    category: "text",
                    keyword: keyword,
                    bytes: text.utf8.count
                )
            )
            pendingBytes += text.utf8.count
            if pending.count >= 4_000 || pendingBytes >= 64 * 1_048_576 {
                do {
                    try await flush()
                } catch {
                    print("[SCALE] text insert failed: \(error)")
                    return 1
                }
            }
            if (index + 1) % 10_000 == 0 {
                print(
                    "[SCALE] texts \(index + 1)/\(textCount)"
                        + " elapsed=\(Int(Date().timeIntervalSince(started)))s"
                        + " db=\(megabytes(fileSize(databaseURL)))"
                )
            }
        }

        let bigBytes = Int(bigImageMegabytes * 1_048_576)
        let smallBytes = 48 * 1024
        for index in 0..<imageCount {
            let isBig = index < bigImageCount
            let target = isBig ? bigBytes : smallBytes
            guard let data = makeNoisePNG(byteTarget: target, seed: UInt64(index))
            else {
                print("[SCALE] image \(index) encoding failed")
                return 1
            }
            let draft = NewClip(
                kind: .image,
                text: "",
                imageData: data,
                imageFormat: "public.png",
                sourceApp: sourceApp,
                contentHash: ContentHasher.hash(
                    text: "scale-image-\(seedValue)-\(index)"
                ),
                smartTag: .image,
                containsSensitive: false
            )
            pending.append(
                LoadItem(
                    draft: draft,
                    category: isBig ? "image-big" : "image-small",
                    keyword: "",
                    bytes: data.count
                )
            )
            pendingBytes += data.count
            if pendingBytes >= 256 * 1_048_576 || pending.count >= 64 {
                do {
                    try await flush()
                } catch {
                    print("[SCALE] image insert failed: \(error)")
                    return 1
                }
            }
            if (index + 1) % 25 == 0 {
                print(
                    "[SCALE] images \(index + 1)/\(imageCount)"
                        + " elapsed=\(Int(Date().timeIntervalSince(started)))s"
                        + " db=\(megabytes(fileSize(databaseURL)))"
                )
            }
        }

        do {
            try await flush()
        } catch {
            print("[SCALE] final flush failed: \(error)")
            return 1
        }

        if let encoded = try? JSONEncoder().encode(fixtures) {
            try? encoded.write(to: fixturesURL(in: directory))
        }

        let sizeAfter = fileSize(databaseURL)
        let elapsed = Date().timeIntervalSince(started)
        let imageBytes = fixtures
            .filter { $0.category.hasPrefix("image") }
            .reduce(UInt64(0)) { $0 + UInt64($1.bytes) }
        print(
            String(
                format: "[SCALE] seeded images=%d texts=%d in %.1fs",
                fixtures.filter { $0.category.hasPrefix("image") }.count,
                fixtures.filter { $0.category == "text" }.count,
                elapsed
            )
        )
        print(
            "[SCALE] image payload=\(megabytes(imageBytes))"
                + " db=\(megabytes(sizeAfter))"
                + " (was \(megabytes(sizeBefore)))"
        )
        return 0
    }

    static func runBench(
        directory: URL,
        rounds: Int,
        liveAI: Bool
    ) async -> Int32 {
        guard let data = try? Data(contentsOf: fixturesURL(in: directory)),
              let fixtures = try? JSONDecoder().decode(
                  [ScaleFixture].self,
                  from: data
              ), !fixtures.isEmpty else {
            print("[SCALE] no fixtures at \(fixturesURL(in: directory).path)")
            return 1
        }

        let databaseURL = DatabaseManager.databaseURL(in: directory)
        let suite = "ClipaScaleBench-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        let settings = SettingsStore(defaults: defaults)
        settings.historyLimit = 0

        let openStart = ScaleMetrics.wallNanos()
        let store = ClipStore(baseDirectory: directory, settingsStore: settings)
        let openMS = Double(
            ScaleMetrics.wallNanos() - openStart
        ) / 1_000_000
        defaults.removePersistentDomain(forName: suite)

        guard let database = store.database else {
            print("[SCALE] store unavailable")
            return 1
        }

        let textFixtures = fixtures.filter { $0.category == "text" }
        let smallImages = fixtures.filter { $0.category == "image-small" }
        let bigImages = fixtures.filter { $0.category == "image-big" }
        guard !textFixtures.isEmpty, !smallImages.isEmpty, !bigImages.isEmpty
        else {
            print("[SCALE] fixtures missing a category")
            return 1
        }

        let engine = LocalSearchEngine(database: database, store: store)
        let scratch = NSPasteboard(name: NSPasteboard.Name("ClipaScaleBench"))
        let sampler = ScaleSampler()
        sampler.start()
        let recorder = ScaleBenchRecorder(sampler: sampler)

        print("")
        print(
            "[SCALE] store rows=\(store.items.count)"
                + " db=\(megabytes(fileSize(databaseURL)))"
                + " open=\(String(format: "%.0f", openMS))ms"
        )
        print(
            "[SCALE] cores=\(ScaleMetrics.coreCount)"
                + " ram=\(megabytes(ScaleMetrics.physicalMemory))"
                + " rounds=\(rounds)"
        )

        var cursors: [String: Int] = [:]
        func next(_ pool: [ScaleFixture], _ key: String) -> ScaleFixture {
            let index = cursors[key] ?? 0
            cursors[key] = index + 1
            return pool[index % pool.count]
        }

        func clip(_ fixture: ScaleFixture) -> Clip? {
            store.clip(dbID: fixture.dbID)
        }

        recorder.measure("list_load", rounds: rounds) {
            store.reloadFromDatabase()
            return !store.items.isEmpty
        }

        await recorder.measureAsync("list_load_db_only", rounds: rounds) {
            guard let clips = try? await database.loadRecentClips() else {
                return false
            }
            return !clips.isEmpty
        }

        var captureIDs: [UUID] = []
        recorder.measure("capture_insert", rounds: rounds) {
            let draft = NewClip(
                kind: .text,
                text: "Clipa 压测 capture \(UUID().uuidString)",
                sourceApp: "ClipaScaleBench"
            )
            let ok = store.insert(draft)
            if ok { captureIDs.append(draft.id) }
            return ok
        }

        recorder.measure("copy_text", rounds: rounds) {
            guard let item = clip(next(textFixtures, "copy-text")) else {
                return false
            }
            let ok = ClipboardWriter.shared.copy(
                item,
                store: store,
                to: scratch
            )
            return ok && scratch.string(forType: .string) == item.text
        }
        recorder.measure("copy_image_small", rounds: rounds) {
            guard let item = clip(next(smallImages, "copy-small")) else {
                return false
            }
            let ok = ClipboardWriter.shared.copy(
                item,
                store: store,
                to: scratch
            )
            return ok
                && (scratch.data(forType: .png)?.isEmpty == false
                    || scratch.data(forType: .tiff)?.isEmpty == false)
        }
        recorder.measure("copy_image_big", rounds: rounds) {
            guard let item = clip(next(bigImages, "copy-big")) else {
                return false
            }
            let ok = ClipboardWriter.shared.copy(
                item,
                store: store,
                to: scratch
            )
            return ok
                && (scratch.data(forType: .png)?.isEmpty == false
                    || scratch.data(forType: .tiff)?.isEmpty == false)
        }

        recorder.measure("image_blob_read_big", rounds: rounds) {
            guard let item = clip(next(bigImages, "blob-big")) else {
                return false
            }
            return (store.imageData(for: item)?.isEmpty == false)
        }
        recorder.measure("image_blob_read_small", rounds: rounds) {
            guard let item = clip(next(smallImages, "blob-small")) else {
                return false
            }
            return (store.imageData(for: item)?.isEmpty == false)
        }

        recorder.measure("search_unique_keyword", rounds: rounds) {
            let fixture = next(textFixtures, "search-unique")
            let response = engine.search(
                query: fixture.keyword,
                filter: SearchFilter(),
                store: store
            )
            return !response.clips.isEmpty
        }
        recorder.measure("search_common_term", rounds: rounds) {
            let response = engine.search(
                query: "clipa",
                filter: SearchFilter(),
                store: store
            )
            return !response.clips.isEmpty
        }
        recorder.measure("search_phrase", rounds: rounds) {
            let response = engine.search(
                query: "压测 样本",
                filter: SearchFilter(),
                store: store
            )
            return !response.clips.isEmpty
        }
        recorder.measure("search_kind_image", rounds: rounds) {
            let response = engine.search(
                query: "",
                filter: SearchFilter(kinds: [.image]),
                store: store
            )
            return !response.clips.isEmpty
        }
        recorder.measure("search_empty_browse", rounds: rounds) {
            let response = engine.search(
                query: "",
                filter: SearchFilter(),
                store: store
            )
            return !response.clips.isEmpty
        }
        recorder.measure("search_no_match", rounds: rounds) {
            let response = engine.search(
                query: "zqxnomatchzzq",
                filter: SearchFilter(),
                store: store
            )
            return response.clips.isEmpty
        }

        let toggleFixture = textFixtures[min(5, textFixtures.count - 1)]

        recorder.measure("scan_items_by_id", rounds: rounds) {
            let target = next(textFixtures, "scan").dbID
            return store.items.firstIndex { $0.dbID == target } != nil
        }

        recorder.measure("clip_lookup", rounds: rounds) {
            clip(next(textFixtures, "lookup")) != nil
        }
        recorder.measure("memory_index_write", rounds: rounds) {
            guard let item = clip(next(textFixtures, "mi")) else { return false }
            store.memoryIndex.insert(clip: item)
            return true
        }

        recorder.measure("memory_index_write_shared", rounds: rounds) {
            let snapshot = SearchSnapshot(store: store)
            guard let item = clip(next(textFixtures, "mi-shared")) else {
                return false
            }
            store.memoryIndex.insert(clip: item)
            return withExtendedLifetime(snapshot) { true }
        }
        await recorder.measureAsync("private_on", rounds: rounds) {
            await store.togglePrivateAsync(dbID: toggleFixture.dbID)
        }
        await recorder.measureAsync("private_off", rounds: rounds) {
            await store.togglePrivateAsync(dbID: toggleFixture.dbID)
        }
        await recorder.measureAsync("note_set", rounds: rounds) {
            guard let item = clip(toggleFixture) else { return false }
            return await store.setNoteAsync("压测备注", for: item)
        }
        await recorder.measureAsync("note_clear", rounds: rounds) {
            guard let item = clip(toggleFixture) else { return false }
            return await store.setNoteAsync(nil, for: item)
        }

        recorder.measure("delete", rounds: rounds) {
            guard let id = captureIDs.popLast() else { return false }
            if case .deleted = store.delete(ids: [id]) { return true }
            return false
        }

        sampler.stop()
        let leftover = captureIDs
        if !leftover.isEmpty {
            _ = store.delete(ids: Set(leftover))
        }

        printReport(
            recorder: recorder,
            directory: directory,
            databaseURL: databaseURL,
            rows: store.items.count,
            rounds: rounds
        )
        return 0
    }

    @MainActor
    static func runWorkspaceRetentionProbe(directory: URL) -> Int32 {
        func mb(_ bytes: UInt64) -> String {
            String(format: "%.0fMB", Double(bytes) / 1_048_576)
        }
        func footprint() -> UInt64 { ScaleMetrics.footprintBytes() }
        func snapshot(_ label: String) {
            print(
                "[WSRET] \(label): RSS \(mb(ScaleMetrics.residentBytes()))"
                    + " / footprint \(mb(footprint()))"
            )
        }
        print("")
        snapshot("baseline")

        var control: ClipStore? = ClipStore(baseDirectory: directory)
        let controlRows = control?.items.count ?? 0
        snapshot("对照：打开大工作区（\(controlRows) 行）")
        control = nil
        snapshot("对照：仅释放（立即）")
        let relieved = malloc_zone_pressure_relief(malloc_default_zone(), 0)
        print("[WSRET] 对照：malloc_zone_pressure_relief 归还 \(relieved / 1_048_576)MB")
        snapshot("对照：归还后")
        Thread.sleep(forTimeInterval: 3)
        snapshot("对照：仅释放（3 秒后）")

        var store: ClipStore? = ClipStore(baseDirectory: directory)
        weak var previousStore = store
        let rows = store?.items.count ?? 0
        print(
            "[WSRET] 打开大工作区（\(rows) 行）: "
                + mb(ScaleMetrics.residentBytes())
        )
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClipaWSRetention-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: emptyDir,
            withIntermediateDirectories: true
        )
        let next = ClipStore(baseDirectory: emptyDir)
        print(
            "[WSRET] 空工作区已打开（尚未替换）: "
                + mb(ScaleMetrics.residentBytes())
        )
        ClipStore.replaceShared(with: next)
        print(
            "[WSRET] 替换共享 store 后: "
                + mb(ScaleMetrics.residentBytes())
        )
        store = nil
        print(
            "[WSRET] 旧 store 引用置空（\(previousStore == nil ? "已释放" : "仍被持有")）: "
                + mb(ScaleMetrics.residentBytes())
        )
        print(
            "[WSRET] 切换到空工作区（立即）: "
                + mb(ScaleMetrics.residentBytes())
        )
        Thread.sleep(forTimeInterval: 3)
        print(
            "[WSRET] 切换后 3 秒: " + mb(ScaleMetrics.residentBytes())
        )
        Thread.sleep(forTimeInterval: 7)
        print(
            "[WSRET] 切换后 10 秒: " + mb(ScaleMetrics.residentBytes())
        )
        try? FileManager.default.removeItem(at: emptyDir)
        return 0
    }

    static func runMemoryBreakdown(directory: URL) -> Int32 {
        func megabytes(_ bytes: UInt64) -> String {
            String(format: "%.0f", Double(bytes) / 1_048_576)
        }
        func delta(_ from: UInt64, _ to: UInt64) -> String {
            "+" + megabytes(to &- from)
        }
        let baseline = ScaleMetrics.residentBytes()
        print("")
        print("[MEM] baseline (runtime + frameworks): \(megabytes(baseline))MB")

        let suite = "ClipaMemory-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        let settings = SettingsStore(defaults: defaults)
        settings.historyLimit = 0
        let store = ClipStore(
            baseDirectory: directory,
            settingsStore: settings
        )
        defaults.removePersistentDomain(forName: suite)
        let afterStore = ScaleMetrics.residentBytes()
        print(
            "[MEM] + store open (\(store.items.count) clips,"
                + " rows + id maps + search index):"
                + " \(megabytes(afterStore))MB (\(delta(baseline, afterStore)))"
        )

        var textBytes = 0
        var noteBytes = 0
        var imageBytes = 0
        var imageCount = 0
        if let conn = try? DatabaseConnection(
            path: DatabaseManager.databaseURL(in: directory).path
        ) {
            try? conn.configure()
            textBytes = (try? conn.scalarInt(
                "SELECT COALESCE(SUM(LENGTH(CAST(text AS BLOB))), 0) FROM clips"
            )) ?? 0
            noteBytes = (try? conn.scalarInt(
                "SELECT COALESCE(SUM(LENGTH(CAST(note AS BLOB))), 0) FROM clips"
            )) ?? 0
            imageBytes = (try? conn.scalarInt(
                "SELECT COALESCE(SUM(LENGTH(blob)), 0) FROM clip_images"
            )) ?? 0
            imageCount = (try? conn.scalarInt(
                "SELECT COUNT(*) FROM clip_images"
            )) ?? 0
        }
        print(
            "[MEM] database (on disk, not resident):"
                + " text=\(megabytes(UInt64(textBytes)))MB"
                + " note=\(megabytes(UInt64(noteBytes)))MB"
                + " images=\(megabytes(UInt64(imageBytes)))MB"
                + " in \(imageCount) blobs"
        )

        var decoded: [NSImage] = []
        let imageStart = ScaleMetrics.residentBytes()
        var biggest = 0
        for clip in store.items where clip.kind == .image {
            guard decoded.count < 5, let data = store.imageData(for: clip),
                  let source = CGImageSourceCreateWithData(
                      data as CFData,
                      nil
                  ) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else { continue }
            biggest = max(biggest, thumbnail.width)
            decoded.append(
                NSImage(
                    cgImage: thumbnail,
                    size: NSSize(
                        width: thumbnail.width,
                        height: thumbnail.height
                    )
                )
            )
        }
        let afterImages = ScaleMetrics.residentBytes()
        print(
            "[MEM] + \(decoded.count) decoded previews (max \(biggest)px,"
                + " the cache has no eviction):"
                + " \(megabytes(afterImages))MB"
                + " (\(delta(imageStart, afterImages)))"
        )
        print("[MEM] final resident: \(megabytes(afterImages))MB")
        withExtendedLifetime(decoded) {}
        return 0
    }

    @MainActor
    static func runPanelWindowBench(directory: URL) -> Int32 {
        let suite = "ClipaPanelWindow-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        let settings = SettingsStore(defaults: defaults)
        settings.historyLimit = 0
        let store = ClipStore(
            baseDirectory: directory,
            settingsStore: settings
        )
        defaults.removePersistentDomain(forName: suite)
        guard store.database != nil else {
            print("[WINDOW] store unavailable")
            return 1
        }
        let vm = PanelViewModel(
            store: store,
            settings: settings
        )

        let refreshStart = DispatchTime.now().uptimeNanoseconds
        vm.query = ""
        vm.refreshSearch()
        let refreshMS = Double(
            DispatchTime.now().uptimeNanoseconds - refreshStart
        ) / 1_000_000

        let rows = vm.navigationOrder.count
        let entries = vm.listEntries.count
        let window = vm.renderedEntries.count

        var legacyEntries = 0
        let legacyStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<3 {
            let flat = vm.results.flatMap { section -> [HistoryListEntry] in
                [.header(section)] + section.clips.map { .clip($0.id) }
            }
            legacyEntries = flat.count
        }
        let legacyMS = Double(
            DispatchTime.now().uptimeNanoseconds - legacyStart
        ) / 3 / 1_000_000

        var windowEntries = 0
        let windowStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<3 {
            windowEntries = vm.renderedEntries.count
        }
        let windowMS = Double(
            DispatchTime.now().uptimeNanoseconds - windowStart
        ) / 1_000_000

        print("")
        print("[WINDOW] store rows=\(store.items.count) db=\(megabytes(fileSize(DatabaseManager.databaseURL(in: directory))))")
        print(
            String(
                format: "[WINDOW] search+flatten once: %.0fms", refreshMS
            )
        )
        print(
            "[WINDOW] entries handed to the view per redraw:"
                + " before=\(legacyEntries) after=\(windowEntries)"
                + " (window=\(window), total=\(entries), rows=\(rows))"
        )
        print(
            String(
                format: "[WINDOW] per-redraw list cost: before=%.2fms"
                    + " after=%.2fms (%.0f× fewer entries)",
                legacyMS,
                windowMS,
                legacyMS > 0 ? legacyMS / max(windowMS, 0.000_1) : 0
            )
        )
        return 0
    }

    static func runSearchRecallAudit(
        directory: URL?,
        derivedProbes: Int,
        extraQueries: [String],
        synthetic: Bool
    ) -> Int32 {
        let suite = "ClipaRecallAudit-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        let settings = SettingsStore(defaults: defaults)
        settings.historyLimit = 0
        let temporaryDirectory = synthetic
            ? FileManager.default.temporaryDirectory.appendingPathComponent(
                "ClipaRecallAudit-\(UUID().uuidString)",
                isDirectory: true
            )
            : nil
        let baseDirectory = temporaryDirectory
            ?? directory
            ?? ClipStore.defaultBaseDirectory()
        let store = ClipStore(
            baseDirectory: baseDirectory,
            settingsStore: settings
        )
        defaults.removePersistentDomain(forName: suite)
        guard let database = store.database else {
            print("[RECALL] store unavailable")
            return 1
        }

        var queries = extraQueries
        if synthetic {
            _ = store.replaceAllForTesting(SearchParity.adversarialCorpus())
            queries += SearchParity.adversarialQueries()
        } else {
            var sampled = 0
            for clip in store.items {
                guard sampled < derivedProbes else { break }
                let characters = Array(QueryNormalizer.normalize(clip.text))
                guard characters.count >= 6 else { continue }
                sampled += 1
                let width = min(8, max(3, characters.count / 3))
                let span = characters.count - width
                let start = span > 0
                    ? Int(clip.dbID % Int64(span + 1))
                    : 0
                queries.append(String(characters[start..<(start + width)]))
                queries.append(String(characters[0..<min(12, characters.count)]))
            }
        }
        queries = Array(NSOrderedSet(array: queries)) as? [String] ?? queries

        let engine = LocalSearchEngine(database: database, store: store)
        var checked = 0
        var misses = 0
        var engineOnly = 0
        var details: [String] = []
        for query in queries {
            let plan = SearchQueryPlan.keyword(query)
            let criteria = SearchCriteria(plan: plan, filter: SearchFilter())
            let engineIDs = Set(
                engine.search(
                    query: query,
                    filter: SearchFilter(),
                    store: store
                ).clips.map(\.dbID)
            )

            let bruteIDs: Set<Int64>
            if plan.sort == .relevance {
                bruteIDs = Set(
                    store.memoryIndex.evidenceMatches(
                        groups: plan.keywordGroups,
                        excludedKeywords: plan.excludedKeywords,
                        termLengths: plan.keywordGroups
                            .flatMap { $0 }
                            .map {
                                QueryNormalizer.normalizeQuery($0).count
                            },
                        phrase: SearchRanker.orderedPhrase(
                            groups: plan.keywordGroups
                        )
                    ).map(\.dbID)
                )
            } else {
                bruteIDs = Set(
                    store.memoryIndex.matchingIDs(
                        groups: plan.keywordGroups,
                        excludedKeywords: plan.excludedKeywords
                    )
                )
            }
            let filtered = Set(
                bruteIDs.filter { dbID in
                    guard let clip = store.clip(dbID: dbID) else {
                        return false
                    }
                    return criteria.matches(clip: clip)
                }
            )
            checked += 1
            let missing = filtered.subtracting(engineIDs)
            let extra = engineIDs.subtracting(filtered)
            if !missing.isEmpty {
                misses += 1
                if details.count < 5 {
                    details.append(
                        "\(query) → missed \(missing.sorted().prefix(3))"
                    )
                }
            }
            if !extra.isEmpty {
                engineOnly += 1
                if details.count < 5 {
                    details.append(
                        "\(query) → unexpected \(extra.sorted().prefix(3))"
                    )
                }
            }
        }
        print(
            "[RECALL] queries=\(checked) rows=\(store.items.count)"
                + " recall-misses=\(misses) extra-results=\(engineOnly)"
        )
        for detail in details {
            print("[RECALL]   \(detail)")
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        return (misses == 0 && engineOnly == 0) ? 0 : 1
    }

    private static func printReport(
        recorder: ScaleBenchRecorder,
        directory: URL,
        databaseURL: URL,
        rows: Int,
        rounds: Int
    ) {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width
                ? text
                : text + String(repeating: " ", count: width - text.count)
        }

        print("")
        print(
            "[SCALE] operations, \(rounds) rounds each"
                + " (CPU% is share of one core)"
        )
        print(
            "[SCALE] "
                + pad("operation", 22)
                + pad("p50", 10)
                + pad("p95", 10)
                + pad("max", 10)
                + pad("cpu%", 8)
                + pad("peakRSS", 11)
                + pad("ΔRSS", 10)
                + "fail"
        )
        var jsonRows: [[String: Any]] = []
        for name in recorder.order {
            guard let stats = recorder.stats[name] else { continue }
            print(
                "[SCALE] "
                    + pad(name, 22)
                    + pad(String(format: "%.1fms", stats.p50), 10)
                    + pad(String(format: "%.1fms", stats.p95), 10)
                    + pad(String(format: "%.1fms", stats.maxMS), 10)
                    + pad(String(format: "%.1f%%", stats.avgCPU), 8)
                    + pad(megabytes(stats.peakRSS), 11)
                    + pad(
                        String(
                            format: "%+.1fMB",
                            stats.avgRSSDeltaBytes / 1_048_576
                        ),
                        10
                    )
                    + "\(stats.failures)"
            )
            jsonRows.append([
                "operation": name,
                "rounds": stats.count,
                "p50ms": stats.p50,
                "p95ms": stats.p95,
                "maxms": stats.maxMS,
                "avgCPUPercent": stats.avgCPU,
                "peakRSSBytes": stats.peakRSS,
                "avgRSSDeltaBytes": stats.avgRSSDeltaBytes,
                "failures": stats.failures
            ])
        }

        let report: [String: Any] = [
            "store": databaseURL.path,
            "rows": rows,
            "rounds": rounds,
            "cores": ScaleMetrics.coreCount,
            "physicalMemoryBytes": ScaleMetrics.physicalMemory,
            "databaseBytes": fileSize(databaseURL),
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "operations": jsonRows
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(
                to: directory.appendingPathComponent("scale-bench-report.json")
            )
        }
    }

    private static func textKeyword(_ index: Int) -> String {
        String(format: "zsq%06dq", index)
    }

    private static let fragments: [String] = [
        "Kubernetes 集群的网络插件选型需要同时考虑吞吐、可观测性与排障成本。",
        "把日志按天切分后再压缩，检索速度会明显提升。",
        "Payment service latency increased after the 14:20 deploy.",
        "数据库迁移前先做一次全量备份，再验证回滚路径。",
        "会议纪要：下周确认灰度范围和回滚预案。",
        "缓存命中率下降通常先看热点 key 的分布变化。",
        "The release checklist is stored in the shared drive.",
        "接口超时排查顺序：DNS、连接池、慢查询、下游限流。",
        "压测样本用于验证索引规模对检索延迟的影响。",
        "这段文本会重复出现在语料里，用来制造可命中的公共词。"
    ]

    static func textSample(_ index: Int) -> String {
        let keyword = textKeyword(index)
        let target = 120 + (index % 9) * 160
        var body = "clipa 压测样本 \(keyword)\n"
        var cursor = index % fragments.count
        while body.utf8.count < target {
            body += fragments[cursor % fragments.count] + "\n"
            cursor += 1
        }
        return body
    }

    static func makeNoisePNG(byteTarget: Int, seed: UInt64) -> Data? {
        let side = max(8, Int((Double(byteTarget) / 3.0).squareRoot()))
        let width = side
        let height = side
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1
            var offset = 0
            while offset < buffer.count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let chunk = withUnsafeBytes(of: state.bigEndian) {
                    Array($0)
                }
                let count = min(chunk.count, buffer.count - offset)
                base.advanced(by: offset).copyMemory(
                    from: chunk,
                    byteCount: count
                )
                offset += count
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
