import AppKit
import Foundation

private struct StressRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func int(_ upper: Int) -> Int {
        upper <= 1 ? 0 : Int(next() % UInt64(upper))
    }
}

struct StressFixture: Codable {
    let dbID: Int64
    let category: String

    let expectedTag: String

    let keyword: String
    let bytes: Int
    let isImage: Bool
    let isFile: Bool
}

enum StressTest {
    static let sourceApp = "ClipaStress"

    private static func fixtureURL(in directory: URL) -> URL {
        directory.appendingPathComponent("stress-fixtures.json")
    }

    static func runSeed(directory: URL, total: Int, seedValue: UInt64) -> Int32 {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let assets = directory.appendingPathComponent(
            "stress-assets",
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )

        let database: DatabaseManager
        do {
            database = try DatabaseManager(baseDirectory: directory)
        } catch {
            print("[STRESS] cannot open store: \(error.localizedDescription)")
            return 1
        }

        var random = StressRandom(seed: seedValue)
        var fixtures: [StressFixture] = []
        var index = 0

        let shape: [(String, Int, Int)] = [
            ("text", 801, 0),
            ("json", 300, 30),
            ("yaml", 300, 30),
            ("markdown", 300, 30),
            ("image", 150, 0),
            ("file", 150, 0)
        ]

        var confusion: [String: [ConfusionAuditCase]] = [:]
        for category in ["json", "yaml", "markdown"] {
            confusion[category] = ConfusionAudit.textCases
                .filter { $0.category == category }
                .prefix(30)
                .map { $0 }
        }

        let started = Date()
        for (category, count, confusionCount) in shape {
            for slot in 0..<count {
                index += 1
                let isConfusion = slot < confusionCount
                let draft: NewClip
                let expectedTag: String
                var keyword = ""
                var bytes = 0
                var isImage = false
                var isFile = false

                let auditCases = confusion[category] ?? []
                if isConfusion, slot < auditCases.count {

                    let caseFile = auditCases[slot]
                    draft = NewClip(
                        kind: caseFile.kind,
                        text: caseFile.text,
                        sourceApp: sourceApp
                    )
                    expectedTag = caseFile.expectedTag?.rawValue ?? "text"
                    keyword = ""
                } else if isConfusion {

                    let text = Self.confusionSample(
                        category,
                        index: slot,
                        &random
                    )
                    draft = NewClip(
                        kind: .text,
                        text: text,
                        sourceApp: sourceApp
                    )
                    expectedTag = "text"
                    keyword = ""
                    bytes = text.utf8.count
                } else {
                    switch category {
                    case "json":
                        let text = Self.jsonSample(index, &random)
                        keyword = Self.keyword(index)
                        draft = NewClip(
                            kind: .text,
                            text: text,
                            sourceApp: sourceApp
                        )
                        expectedTag = "json"
                        bytes = text.utf8.count
                    case "yaml":
                        let text = Self.yamlSample(index, &random)
                        keyword = Self.keyword(index)
                        draft = NewClip(
                            kind: .text,
                            text: text,
                            sourceApp: sourceApp
                        )
                        expectedTag = "yaml"
                        bytes = text.utf8.count
                    case "markdown":
                        let text = Self.markdownSample(index, &random)
                        keyword = Self.keyword(index)
                        draft = NewClip(
                            kind: .text,
                            text: text,
                            sourceApp: sourceApp
                        )
                        expectedTag = "markdown"
                        bytes = text.utf8.count
                    case "image":
                        let payload = Self.imageSample(slot, index: index)
                        keyword = ""
                        draft = NewClip(
                            kind: .image,
                            text: "",
                            imageData: payload.data,
                            imageFormat: payload.format,
                            sourceApp: sourceApp
                        )
                        expectedTag = "image"
                        bytes = payload.data.count
                        isImage = true
                    case "file":
                        let url = assets.appendingPathComponent(
                            "stress-file-\(index).txt"
                        )
                        let body = Self.textSample(index, &random)
                        try? body.write(to: url, atomically: true, encoding: .utf8)
                        keyword = ""
                        draft = NewClip(
                            kind: .file,
                            text: "",
                            fileURLs: [url],
                            sourceApp: sourceApp
                        )
                        expectedTag = "file"
                        bytes = body.utf8.count
                        isFile = true
                    default:
                        let text = Self.textSample(index, &random)
                        keyword = Self.keyword(index)
                        draft = NewClip(
                            kind: .text,
                            text: text,
                            sourceApp: sourceApp
                        )
                        expectedTag = "text"
                        bytes = text.utf8.count
                    }
                }

                var prepared = draft

                prepared.contentHash = ContentHasher.hash(
                    text: "\(seedValue)-\(index)-\(prepared.text)"
                        + "\(prepared.imageData?.count ?? 0)"
                )
                prepared.isPrivate = index % 24 == 0
                prepared.containsSensitive = false

                do {
                    let result = try DatabaseSync.run(database) { db in
                        try await db.insertClip(prepared)
                    }
                    fixtures.append(
                        StressFixture(
                            dbID: result.clip.dbID,
                            category: isConfusion
                                ? "confusion-\(category)"
                                : category,
                            expectedTag: expectedTag,
                            keyword: keyword,
                            bytes: bytes,
                            isImage: isImage,
                            isFile: isFile
                        )
                    )
                } catch {
                    print(
                        "[STRESS] insert \(index) failed: "
                            + error.localizedDescription
                    )
                }
                if index % 250 == 0 {
                    print("[STRESS] seeded \(index)/\(total)")
                }
            }
        }

        if let data = try? JSONEncoder().encode(fixtures) {
            try? data.write(to: fixtureURL(in: directory))
        }
        let elapsed = Date().timeIntervalSince(started)
        print(
            String(
                format: "[STRESS] seeded %d rows in %.1fs, fixtures=%d",
                index,
                elapsed,
                fixtures.count
            )
        )
        return 0
    }

    private struct CrawlRecord: Decodable {
        struct Content: Decodable {
            let bytes: Int
            let sha256: String
        }
        let id: Int
        let domain: String
        let format: String
        let file: String
        let content: Content
    }

    static func runImport(directory: URL, datasetRoot: URL) -> Int32 {
        let manifest = datasetRoot.appendingPathComponent("metadata.jsonl")
        guard let manifestText = try? String(
            contentsOf: manifest,
            encoding: .utf8
        ) else {
            print("[IMPORT] no metadata.jsonl at \(manifest.path)")
            return 1
        }

        let database: DatabaseManager
        do {
            database = try DatabaseManager(baseDirectory: directory)
        } catch {
            print("[IMPORT] cannot open store: \(error.localizedDescription)")
            return 1
        }

        let decoder = JSONDecoder()
        var fixtures: [StressFixture] = []
        var skipped = 0
        let started = Date()

        for line in manifestText.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(
                      CrawlRecord.self,
                      from: data
                  ) else {
                skipped += 1
                continue
            }
            let fileURL = datasetRoot.appendingPathComponent(record.file)
            guard let content = try? String(
                contentsOf: fileURL,
                encoding: .utf8
            ), !content.isEmpty else {
                skipped += 1
                continue
            }
            var draft = NewClip(
                kind: .text,
                text: content,
                sourceApp: "ClipaCrawl"
            )
            draft.contentHash = record.content.sha256
            do {
                let result = try DatabaseSync.run(database) { db in
                    try await db.insertClip(draft)
                }
                fixtures.append(
                    StressFixture(
                        dbID: result.clip.dbID,
                        category: "\(record.domain)/\(record.format)",
                        expectedTag: record.format,
                        keyword: Self.searchProbe(in: content),
                        bytes: record.content.bytes,
                        isImage: false,
                        isFile: false
                    )
                )
            } catch {
                skipped += 1
            }
        }

        if let data = try? JSONEncoder().encode(fixtures) {
            try? data.write(to: fixtureURL(in: directory))
        }
        print(
            String(
                format: "[IMPORT] %d rows in %.1fs (skipped %d)",
                fixtures.count,
                Date().timeIntervalSince(started),
                skipped
            )
        )
        return 0
    }

    private static func searchProbe(in text: String) -> String {
        let run = text
            .split { !($0.isLetter || $0.isNumber) }
            .first { $0.count >= 6 }
            .map(String.init) ?? ""
        return String(run.prefix(16))
    }

    static func runReclassify(directory: URL) -> Int32 {
        let fixtureFile = fixtureURL(in: directory)
        guard let data = try? Data(contentsOf: fixtureFile),
              let fixtures = try? JSONDecoder().decode(
                  [StressFixture].self,
                  from: data
              ) else {
            print("[RECLASSIFY] no fixtures")
            return 1
        }
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: "ClipaReclassify-\(UUID())")!

        )
        settings.historyLimit = 0
        let store = ClipStore(baseDirectory: directory, settingsStore: settings)
        guard let database = store.database else {
            print("[RECLASSIFY] store unavailable")
            return 1
        }

        var before = 0
        var after = 0
        var total = 0
        var flips: [String: Int] = [:]
        let started = Date()
        for fixture in fixtures {
            guard let clip = store.clip(dbID: fixture.dbID) else { continue }
            total += 1
            if clip.smartTag.rawValue == fixture.expectedTag { before += 1 }
            let result = SmartClassifier.inferredClassification(
                text: clip.text,
                kind: clip.kind
            )
            if result.smartTag.rawValue == fixture.expectedTag { after += 1 }
            if result.smartTag != clip.smartTag {
                flips[
                    "\(clip.smartTag.rawValue)->\(result.smartTag.rawValue)"
                , default: 0] += 1
            }
            _ = try? DatabaseSync.run(database) { db in
                try await db.reclassifyClip(dbID: fixture.dbID)
            }
        }
        print(
            String(
                format: "[RECLASSIFY] %d rows in %.1fs | before %.1f%% | after %.1f%%",
                total,
                Date().timeIntervalSince(started),
                100 * Double(before) / Double(max(1, total)),
                100 * Double(after) / Double(max(1, total))
            )
        )
        for key in flips.keys.sorted() {
            print("[RECLASSIFY]   \(key): \(flips[key] ?? 0)")
        }
        return 0
    }

    private struct Timing {
        var samples: [Double] = []

        mutating func add(_ milliseconds: Double) {
            samples.append(milliseconds)
        }

        var count: Int { samples.count }

        var median: Double {
            guard !samples.isEmpty else { return 0 }
            let sorted = samples.sorted()
            return sorted[sorted.count / 2]
        }

        var p95: Double {
            guard !samples.isEmpty else { return 0 }
            let sorted = samples.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        }
    }

    static func runBench(
        directory: URL,
        rounds: Int,
        itemLimit: Int?,
        destructive: Bool
    ) -> Int32 {
        let fixtureFile = fixtureURL(in: directory)
        guard let data = try? Data(contentsOf: fixtureFile),
              let fixtures = try? JSONDecoder().decode(
                  [StressFixture].self,
                  from: data
              ), !fixtures.isEmpty else {
            print("[BENCH] no fixtures at \(fixtureFile.path)")
            return 1
        }

        let suite = "ClipaStressBench-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        let settings = SettingsStore(defaults: defaults)

        settings.historyLimit = 0
        let store = ClipStore(baseDirectory: directory, settingsStore: settings)
        guard let database = store.database else {
            print("[BENCH] store unavailable")
            return 1
        }
        defaults.removePersistentDomain(forName: suite)

        let selected = itemLimit.map { Array(fixtures.prefix($0)) } ?? fixtures
        let engine = LocalSearchEngine(database: database, store: store)
        let scratch = NSPasteboard(
            name: NSPasteboard.Name("ClipaStressBench")
        )

        var searchTimings: [String: Timing] = [:]
        var copyTimings: [String: Timing] = [:]
        var searchHits = 0
        var searchMisses = 0
        var copyOK = 0
        var copyFailed = 0
        var copyPayloadFailures = 0
        var opTimings: [String: Timing] = [:]
        var opFailures: [String: Int] = [:]
        var deleteTimings: [String: Timing] = [:]
        var deleted = 0

        let started = Date()
        for fixture in selected {
            let clip = store.clip(dbID: fixture.dbID)
            let key = fixture.category

            for _ in 0..<rounds {
                let begin = DispatchTime.now().uptimeNanoseconds
                let response: SearchResponse
                if fixture.keyword.isEmpty, !fixture.isImage, !fixture.isFile {

                    let probe = (clip?.text ?? "")
                        .split { !($0.isLetter || $0.isNumber) }
                        .first { $0.count >= 3 }
                        .map(String.init) ?? ""
                    response = engine.search(
                        query: String(probe.prefix(12)),
                        filter: SearchFilter(),
                        store: store
                    )
                } else if fixture.keyword.isEmpty {
                    response = engine.search(
                        query: "",
                        filter: SearchFilter(
                            kinds: fixture.isImage ? [.image] : [.file]
                        ),
                        store: store
                    )
                } else {
                    response = engine.search(
                        query: fixture.keyword,
                        filter: SearchFilter(),
                        store: store
                    )
                }
                let ms = Double(
                    DispatchTime.now().uptimeNanoseconds - begin
                ) / 1_000_000
                searchTimings[key, default: Timing()].add(ms)
                if let clip, response.clips.contains(where: {
                    $0.dbID == clip.dbID
                }) {
                    searchHits += 1
                } else {
                    searchMisses += 1
                }
            }

            guard let clip else { continue }

            func measure(_ name: String, _ body: () -> Bool) {
                let begin = DispatchTime.now().uptimeNanoseconds
                let ok = body()
                let ms = Double(
                    DispatchTime.now().uptimeNanoseconds - begin
                ) / 1_000_000
                opTimings[name, default: Timing()].add(ms)
                if !ok { opFailures[name, default: 0] += 1 }
            }

            let manager = store.database
            if let manager {
                for _ in 0..<rounds {
                    measure("private") {
                        let on = (try? DatabaseSync.run(manager) { db in
                            try await db.updatePrivate(
                                dbID: clip.dbID,
                                isPrivate: true
                            )
                        }) ?? nil
                        let off = (try? DatabaseSync.run(manager) { db in
                            try await db.updatePrivate(
                                dbID: clip.dbID,
                                isPrivate: false
                            )
                        }) ?? nil
                        return on != nil && off != nil
                    }
                    measure("note") {
                        let set = (try? DatabaseSync.run(manager) { db in
                            try await db.updateNote(
                                dbID: clip.dbID,
                                note: "stress-note"
                            )
                        }) ?? nil
                        let clear = (try? DatabaseSync.run(manager) { db in
                            try await db.updateNote(
                                dbID: clip.dbID,
                                note: ""
                            )
                        }) ?? nil
                        return set != nil && clear != nil
                    }
                }
            }

            for _ in 0..<rounds {
                let begin = DispatchTime.now().uptimeNanoseconds
                let ok = ClipboardWriter.shared.copy(
                    clip,
                    store: store,
                    to: scratch
                )
                let ms = Double(
                    DispatchTime.now().uptimeNanoseconds - begin
                ) / 1_000_000
                copyTimings[key, default: Timing()].add(ms)

                let payloadOK: Bool
                switch clip.kind {
                case .text:
                    payloadOK = scratch.string(forType: .string) == clip.text
                case .file:
                    payloadOK =
                        scratch.string(forType: .string)
                            == clip.fileURLs.map(\.path)
                                .joined(separator: "\n")
                        && (scratch.types ?? []).contains(.fileURL)
                case .image:
                    let payload = scratch.data(forType: .png)
                        ?? scratch.data(forType: .tiff)
                    payloadOK = (payload?.count ?? 0) > 0
                }
                if ok, payloadOK {
                    copyOK += 1
                } else {
                    copyFailed += 1
                    if ok, !payloadOK { copyPayloadFailures += 1 }
                }
            }

            if destructive, fixture.dbID % Int64(rounds) == 0 {
                let begin = DispatchTime.now().uptimeNanoseconds
                let outcome = store.delete(ids: [clip.id])
                let ms = Double(
                    DispatchTime.now().uptimeNanoseconds - begin
                ) / 1_000_000
                deleteTimings[key, default: Timing()].add(ms)
                if case .deleted(let count) = outcome { deleted += count }
            }
        }
        let elapsed = Date().timeIntervalSince(started)

        var expected: [UInt64: String] = [:]
        for fixture in selected {
            expected[UInt64(bitPattern: fixture.dbID)] = fixture.expectedTag
        }
        var accuracyTotal = 0
        var accuracyHits = 0
        var byCategory: [String: (Int, Int)] = [:]
        for fixture in selected {
            guard let clip = store.clip(dbID: fixture.dbID) else { continue }
            accuracyTotal += 1
            let ok = clip.smartTag.rawValue == fixture.expectedTag
            if ok { accuracyHits += 1 }
            var bucket = byCategory[fixture.category] ?? (0, 0)
            bucket.0 += 1
            if !ok { bucket.1 += 1 }
            byCategory[fixture.category] = bucket
        }

        print("")
        print("[BENCH] rows=\(selected.count) rounds=\(rounds) in \(Int(elapsed))s")
        for key in searchTimings.keys.sorted() {
            guard let search = searchTimings[key] else { continue }
            let copy = copyTimings[key]
            print(
                String(
                    format: "[BENCH] %-16@ search n=%d p50=%.2fms p95=%.2fms"
                        + " | copy n=%d p50=%.2fms p95=%.2fms",
                    key as NSString,
                    search.count,
                    search.median,
                    search.p95,
                    copy?.count ?? 0,
                    copy?.median ?? 0,
                    copy?.p95 ?? 0
                )
            )
        }
        for key in opTimings.keys.sorted() {
            guard let timing = opTimings[key] else { continue }
            print(
                String(
                    format: "[BENCH] %-8@ n=%d p50=%.2fms p95=%.2fms failures=%d",
                    key as NSString,
                    timing.count,
                    timing.median,
                    timing.p95,
                    opFailures[key] ?? 0
                )
            )
        }
        print(
            "[BENCH] search recall \(searchHits)/\(searchHits + searchMisses)"
                + "  copy ok \(copyOK)/\(copyOK + copyFailed)"
                + "  payload-rejected \(copyPayloadFailures)"
        )
        if destructive {
            print("[BENCH] deleted \(deleted) rows (destructive round)")
        }
        print(
            String(
                format: "[BENCH] classification accuracy %.2f%% (%d/%d)",
                accuracyTotal == 0
                    ? 0
                    : 100 * Double(accuracyHits) / Double(accuracyTotal),
                accuracyHits,
                accuracyTotal
            )
        )
        for key in byCategory.keys.sorted() {
            guard let bucket = byCategory[key], bucket.1 > 0 else { continue }
            print("[BENCH]   mismatch \(key): \(bucket.1)/\(bucket.0)")
        }

        let total = store.items.count
        let sensitiveMarked = store.items.filter(\.containsSensitive).count
        let markerMismatches = store.items.filter {
            $0.containsSensitive
                != SensitiveDetector.containsSensitive($0)
        }.count
        print(
            "[BENCH] privacy: rows \(total),"
                + " sensitive-marked \(sensitiveMarked),"
                + " marker mismatches \(markerMismatches)"
        )

        let report: [String: Any] = [
            "rows": accuracyTotal,
            "rounds": rounds,
            "destructive": destructive,
            "elapsedSeconds": elapsed,
            "searchRecall": "\(searchHits)/\(searchHits + searchMisses)",
            "copySuccess": "\(copyOK)/\(copyOK + copyFailed)",
            "accuracy": accuracyTotal == 0
                ? 0
                : Double(accuracyHits) / Double(accuracyTotal),
            "images": selected.filter(\.isImage).count
        ]
        if let json = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? json.write(
                to: directory.appendingPathComponent("stress-report.json")
            )
        }
        return 0
    }

    private static func keyword(_ index: Int) -> String {
        String(format: "zq%04dk", index)
    }

    private static func textSample(_ index: Int, _ random: inout StressRandom) -> String {
        let topics = ["周报", "会议纪要", "部署说明", "读书笔记", "旅行计划"]
        let topic = topics[random.int(topics.count)]
        return """
        \(topic)：这是第 \(index) 条压测样本 \(keyword(index))。
        今天把相关的材料整理了一遍，重点看了流程和依赖关系。
        下周需要再确认一次口径，然后同步给相关同学。
        """
    }

    private static func jsonSample(_ index: Int, _ random: inout StressRandom) -> String {
        let enabled = random.int(2) == 0
        return """
        {
          "id": \(index),
          "name": "item-\(index)",
          "keyword": "\(keyword(index))",
          "enabled": \(enabled),
          "tags": ["alpha", "beta"],
          "nested": { "port": \(8000 + random.int(1000)), "host": "127.0.0.1" }
        }
        """
    }

    private static func yamlSample(_ index: Int, _ random: inout StressRandom) -> String {
        """
        id: \(index)
        name: item-\(index)
        keyword: \(keyword(index))
        replicas: \(1 + random.int(9))
        metadata:
          owner: team-\(random.int(9))
          enabled: true
        ports:
          - \(8000 + random.int(1000))
          - \(9000 + random.int(1000))
        """
    }

    private static func markdownSample(_ index: Int, _ random: inout StressRandom) -> String {
        """
        # 压测文档 \(index) `\(keyword(index))`

        这一段是正文，包含 **粗体**、*斜体* 与 [链接](https://example.com/\(index))。

        - 要点一：\(random.int(100))
        - 要点二：\(random.int(100))

        ```bash
        echo "\(index)"
        ```
        """
    }

    private static func confusionSample(
        _ category: String,
        index: Int,
        _ random: inout StressRandom
    ) -> String {
        switch category {
        case "json":
            let samples = [
                #"{name: "tom", age: 18}"#,
                #"{"a":1,}"#,
                #"{'a': 1, 'b': 2}"#,
                #"[1, 2,]"#,
                #"{“name”: "tom"}"#,
                "2026-09-11 10:00:0\(random.int(9)) INFO response={\"status\":\"ok\"}",
                "POST /api/v1 返回 {status: ok}（未加引号）",
                #"curl -X POST https://example.com/api -d '{"name":"nginx"}'"#
            ]
            return samples[index % samples.count]
        case "yaml":
            let samples = [
                "结论: 成功\n原因: 网络正常\n备注: 无",
                "时间: 下午三点\n地点: 会议室",
                "2026-09-11 10:00:01 ERROR 配置解析失败\nserver: nginx\nport: 8080",
                "这是一段说明文字: 里面有一个冒号\n但没有 YAML 结构",
                "raw: 不是 JSON",
                "kind: 说明",
                "- 早上开会\n- 下午写文档",
                "备注：以下内容请在会后确认"
            ]
            return samples[index % samples.count]
        default:
            let samples = [
                "今天做了三件事 - 吃饭 - 睡觉 - 写代码，没有列表结构",
                "表格里的竖线 | 只是标点 | 不是表格",
                "// # 这是代码注释，不是标题",
                "#标签 不是标题",
                "订单号 A-123，金额 | 100 元",
                "问题：为什么 # 开头的行不一定是标题？",
                "文本里出现 ``` 但没有代码块围栏配对",
                "**加粗** 出现在一段没有块级结构的句子中间"
            ]
            return samples[index % samples.count]
        }
    }

    private static func imageSample(_ slot: Int, index: Int) -> (data: Data, format: String) {

        slot == 0
            ? makeNoiseImage(width: 3_135, height: 3_135)
            : makeNoiseImage(width: 160, height: 120)
    }

    private static func makeNoiseImage(
        width: Int,
        height: Int
    ) -> (data: Data, format: String) {

        var random = StressRandom(seed: UInt64(width * height))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for offset in stride(from: 0, to: pixels.count, by: 4) {

            pixels[offset] = UInt8(truncatingIfNeeded: random.next())
            pixels[offset + 1] = UInt8(truncatingIfNeeded: random.next() >> 8)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: random.next() >> 16)
            pixels[offset + 3] = 255
        }
        guard let provider = CGDataProvider(
            data: Data(pixels) as CFData
        ), let image = CGImage(
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
            return (Data(), "public.png")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil
        ) else {
            return (Data(), "public.png")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return (Data(), "public.png")
        }
        return (output as Data, "public.png")
    }
}
