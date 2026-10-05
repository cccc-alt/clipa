import Foundation

enum SearchParity {

    enum PlanShapes {
        case all
        case wholeKeywordOnly
    }

    struct Timing {
        var oracleTotalMS = 0.0
        var fastTotalMS = 0.0
        var oracleCalls = 0
        var fastCalls = 0

        var engagedTotalMS = 0.0
        var engagedCalls = 0

        var engagedOracleTotalMS = 0.0

        var oracleAverageMS: Double {
            oracleCalls == 0 ? 0 : oracleTotalMS / Double(oracleCalls)
        }

        var fastAverageMS: Double {
            fastCalls == 0 ? 0 : fastTotalMS / Double(fastCalls)
        }

        var engagedAverageMS: Double {
            engagedCalls == 0 ? 0 : engagedTotalMS / Double(engagedCalls)
        }

        var engagedOracleAverageMS: Double {
            engagedCalls == 0 ? 0 : engagedOracleTotalMS / Double(engagedCalls)
        }
    }

    struct Comparison {
        let query: String
        let planShape: String
        let oracle: [Int64]
        let fast: [Int64]
        let fastPathEngaged: Bool

        var isMatch: Bool { oracle == fast }
    }

    static func plans(for query: String) -> [(shape: String, plan: SearchQueryPlan)] {
        let normalized = QueryNormalizer.normalizeQuery(query)
        let tokens = normalized
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        func make(
            _ shape: String,
            groups: [[String]],
            excluded: [String] = [],
            sort: SearchSort = .relevance
        ) -> (shape: String, plan: SearchQueryPlan) {
            (
                shape,
                SearchQueryPlan(
                    originalQuery: query,
                    keywordGroups: groups,
                    excludedKeywords: excluded,
                    timeRange: nil,
                    kinds: [],
                    smartTags: [],
                    sort: sort,
                    limit: nil
                )
            )
        }

        var result = [
            make("whole-keyword", groups: [[normalized]]),
            make("whole-keyword+newest", groups: [[normalized]], sort: .newest),
            make("whole-keyword+oldest", groups: [[normalized]], sort: .oldest)
        ]
        if tokens.count > 1 {
            result.append(make("and", groups: tokens.map { [$0] }))
            result.append(make("or", groups: [tokens]))
            result.append(make("or+excluding-first", groups: [tokens], excluded: [tokens[0]]))
        }
        if tokens.count > 2 {
            result.append(
                make(
                    "and+excluding-last",
                    groups: tokens.dropLast().map { [$0] },
                    excluded: [tokens[tokens.count - 1]]
                )
            )
        }
        return result
    }

    static func compare(
        store: ClipStore,
        queries: [String],
        filter: SearchFilter = SearchFilter(),
        planShapes: PlanShapes = .all,
        timing: UnsafeMutablePointer<Timing>? = nil
    ) -> [Comparison] {
        let oracle = LocalSearchEngine(
            database: store.database,
            store: store,
            textMatchMode: .oracleOnly
        )
        let fast = LocalSearchEngine(
            database: store.database,
            store: store,
            textMatchMode: .sqlOnly
        )
        var comparisons: [Comparison] = []
        for query in queries {
            let candidates = planShapes == .all
                ? plans(for: query)
                : Array(plans(for: query).prefix(1))
            for entry in candidates {
                let oracleStart = DispatchTime.now().uptimeNanoseconds
                let reference = oracle.search(
                    query: query,
                    filter: filter,
                    store: store,
                    plan: entry.plan
                )
                let oracleEnd = DispatchTime.now().uptimeNanoseconds
                let fastStart = DispatchTime.now().uptimeNanoseconds
                let candidate = fast.search(
                    query: query,
                    filter: filter,
                    store: store,
                    plan: entry.plan
                )
                let fastEnd = DispatchTime.now().uptimeNanoseconds
                if let timing {
                    timing.pointee.oracleTotalMS +=
                        Double(oracleEnd - oracleStart) / 1_000_000
                    timing.pointee.fastTotalMS +=
                        Double(fastEnd - fastStart) / 1_000_000
                    timing.pointee.oracleCalls += 1
                    timing.pointee.fastCalls += 1
                    if candidate.metrics?.exactFastPath == true {
                        timing.pointee.engagedTotalMS +=
                            Double(fastEnd - fastStart) / 1_000_000
                        timing.pointee.engagedOracleTotalMS +=
                            Double(oracleEnd - oracleStart) / 1_000_000
                        timing.pointee.engagedCalls += 1
                    }
                }
                comparisons.append(
                    Comparison(
                        query: query,
                        planShape: entry.shape,
                        oracle: reference.clips.map(\.dbID),
                        fast: candidate.clips.map(\.dbID),
                        fastPathEngaged: candidate.metrics?.exactFastPath ?? false
                    )
                )
            }
        }
        return comparisons
    }

    static func scoringMismatches(
        store: ClipStore,
        queries: [String],
        now: Date = Date()
    ) -> [Comparison] {
        let engine = LocalSearchEngine(
            database: store.database,
            store: store,
            textMatchMode: .oracleOnly
        )
        var mismatches: [Comparison] = []
        for query in queries {
            for entry in plans(for: query) {
                guard entry.plan.sort == .relevance else { continue }
                let response = engine.search(
                    query: query,
                    filter: SearchFilter(),
                    store: store,
                    plan: entry.plan,
                    now: now
                )
                let candidates = response.clips.map { clip -> RankCandidate in
                    RankCandidate(
                        clip: clip,
                        fields: store.memoryIndex.normalizedFields(
                            dbID: clip.dbID
                        ) ?? NormalizedSearchFields(
                            body: QueryNormalizer.normalize(clip.text),
                            note: QueryNormalizer.normalize(clip.note)
                        )
                    )
                }
                let reference = SearchRanker.rank(
                    candidates: candidates,
                    groups: entry.plan.keywordGroups,
                    now: now
                ).map(\.dbID)
                let evidence = response.clips.map(\.dbID)
                if reference != evidence {
                    mismatches.append(
                        Comparison(
                            query: query,
                            planShape: entry.shape,
                            oracle: reference,
                            fast: evidence,
                            fastPathEngaged: true
                        )
                    )
                }
            }
        }
        return mismatches
    }

    static func adversarialCorpus() -> [NewClip] {
        let texts: [String] = [
            "docker network bridge on host-a",
            "kubectl apply -f deployment.yaml",
            "HTTP 500 from api-gateway at /api/v1?x=1",
            "网络配置备份与恢复",
            "剪贴板历史记录整理",
            #"{"name":"tom","age":18,"note":"say \"hello\""}"#,
            "a-b-c ::1 192.168.1.100 C++ /usr/local/bin",
            "family 👨‍👩‍👧 goes shopping",
            "flag 🇨🇳 waves here",
            "waving 👋 hello",
            "각\u{0301} blocked composition",
            "e\u{0301} decomposed accent",
            "İstanbul to STRASSE for ß",
            "ΣΟΦΟΣ and σοφος are the same word",
            "   ",
            String(repeating: "long-line-token ", count: 400) + "tail-marker"
        ]
        var clips = texts.enumerated().map { index, text in
            NewClip(
                kind: .text,
                text: text,
                note: index % 3 == 0 ? "备注 \(index) note-\(index)" : "",
                contentHash: ContentHasher.hash(text: text + "#\(index)")
            )
        }

        clips.append(
            NewClip(
                kind: .image,
                text: "",
                note: "screenshot of the network diagram",
                contentHash: ContentHasher.hash(text: "image-parity")
            )
        )
        clips.append(
            NewClip(
                kind: .file,
                text: "/tmp/report-final.pdf",
                note: "quarterly report",
                contentHash: ContentHasher.hash(text: "file-parity")
            )
        )
        return clips
    }

    static func adversarialQueries() -> [String] {
        [
            "docker network",
            "docker",
            "kubectl",
            "deployment",
            "网络",
            "网络配置",
            "剪贴板",
            "tom",
            "192.168.1",
            "a-b-c",
            "hello",
            "👨",
            "👨‍👩‍👧",
            "🇨🇳",
            "👋",
            "각",
            "각\u{0301}",
            "istanbul",
            "strasse",
            "ß",
            "σοφος",
            "ΣΟΦΟΣ",
            "tail-marker",
            "report",
            "zzzz-nothing-matches",
            "note-3",
            "备注"
        ]
    }

    static func probes(from store: ClipStore, limit: Int = 120) -> [String] {
        var probes: [String] = []
        for clip in store.items.prefix(limit) {
            let normalized = QueryNormalizer.normalize(clip.text)
            let characters = Array(normalized)
            guard characters.count >= 6 else { continue }
            let width = min(8, characters.count / 2)
            let middle = (characters.count - width) / 2
            probes.append(String(characters[middle..<(middle + width)]))

            probes.append(String(characters[0..<2]))
            if characters.count >= 12 {
                probes.append(String(characters[0..<width]))
                probes.append(
                    String(
                        characters[(characters.count - width)..<characters.count]
                    )
                )
            }
        }
        return Array(Set(probes)).sorted()
    }

    static func runFTSMaintenance(directory: URL?, rebuild: Bool) -> Int32 {
        print("========== Clipa FTS Index ==========")
        let base = directory ?? ClipStore.defaultBaseDirectory()
        print("[FTS] store: \(base.path)")
        guard let database = try? DatabaseManager(baseDirectory: base) else {
            print("[FTS] store unavailable")
            return 1
        }
        func milliseconds(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000
        }
        if let marker = (try? DatabaseSync.run(database) { db in
            try await db.ftsIndexMarker()
        }) ?? nil {
            print("""
                [FTS] marker: buildCount=\(marker.buildCount) \
                rows=\(marker.rowCount) \
                ddl=\(marker.ddlFingerprint.prefix(48))
                """)
        }

        if rebuild {
            let time = milliseconds {
                _ = try? DatabaseSync.run(database) { db in
                    try await db.rebuildFTS()
                }
            }
            print(String(format: "[FTS] rebuild: %.1f ms", time))
        } else {
            let decision = try? DatabaseSync.run(database) { db in
                try await db.ftsIndexDecision()
            }
            if let decision {
                switch decision {
                case .trusted(let marker):
                    print("[FTS] decision: trusted (buildCount=\(marker.buildCount))")
                case .rebuild(let reason, let detail):
                    print("[FTS] decision: rebuild (\(reason.rawValue)) \(detail)")
                }
            }
        }

        let strong = try? DatabaseSync.run(database) { db in
            try await db.verifyFTSIndexStrong()
        }
        if let strong {
            print("[FTS] strong verify: ok=\(strong.ok) \(strong.detail)")
        }
        return 0
    }

    static func runOverhead(directory: URL?, rounds: Int = 3) -> Int32 {
        print("========== Clipa Search Overhead ==========")
        guard let directory else {
            print("[OVERHEAD] --dir <store> is required")
            return 1
        }
        func milliseconds(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000
        }

        var openTimes: [Double] = []
        var opened: DatabaseManager?
        for round in 0..<max(1, rounds) {
            var manager: DatabaseManager?
            let time = milliseconds {
                manager = try? DatabaseManager(baseDirectory: directory)
            }
            opened = manager
            openTimes.append(time)
            print(String(
                format: "[OVERHEAD] open #%d: %.1f ms",
                round + 1,
                time
            ))
        }
        guard let database = opened else {
            print("[OVERHEAD] store unavailable")
            return 1
        }

        let rebuild = milliseconds {
            _ = try? DatabaseSync.run(database) { db in
                try await db.rebuildFTS()
            }
        }
        print(String(format: "[OVERHEAD] isolated FTS rebuild: %.1f ms", rebuild))

        let average = openTimes.reduce(0, +) / Double(openTimes.count)
        print(String(
            format: "[OVERHEAD] open average %.1f ms (includes the FTS rebuild)",
            average
        ))
        return 0
    }

    static func runExamples(
        directory: URL?,
        derivedClips: Int = 4,
        extraQueries: [String] = []
    ) -> Int32 {
        print("========== Clipa Search Examples ==========")
        guard let directory else {
            print("[EXAMPLES] --dir <store> is required")
            return 1
        }
        let defaults = UserDefaults(
            suiteName: "ClipaExamples-\(UUID().uuidString)"
        )!
        let store = ClipStore(
            baseDirectory: directory,
            settingsStore: SettingsStore(defaults: defaults)
        )
        guard let database = store.database else {
            print("[EXAMPLES] store unavailable")
            return 1
        }
        print("[EXAMPLES] store: \(directory.path) — \(store.items.count) clips")
        let status = (try? DatabaseBridge.normalizationStatus(database))
            ?? (ready: false, pending: -1, clips: -1)
        print("""
            [EXAMPLES] normalization ready=\(status.ready) \
            pending=\(status.pending)
            """)

        let oracle = LocalSearchEngine(
            database: store.database,
            store: store,
            textMatchMode: .oracleOnly
        )
        let fast = LocalSearchEngine(
            database: store.database,
            store: store,
            textMatchMode: .sqlOnly
        )

        func measure(
            _ engine: LocalSearchEngine,
            query: String,
            plan: SearchQueryPlan
        ) -> (
            hits: Int,
            ms: Double,
            tier: SearchTextTier?,
            ids: [Int64],
            candidateMS: Double,
            rankingMS: Double,

            mainActorMS: Double
        ) {
            var best = Double.infinity
            var hits = 0
            var tier: SearchTextTier?
            var ids: [Int64] = []
            var candidateMS = 0.0
            var rankingMS = 0.0
            var mainActorMS = 0.0
            for _ in 0..<2 {
                let start = DispatchTime.now().uptimeNanoseconds
                let response = engine.search(
                    query: query,
                    filter: SearchFilter(),
                    store: store,
                    plan: plan
                )
                let end = DispatchTime.now().uptimeNanoseconds
                let elapsed = Double(end - start) / 1_000_000
                let mainStart = DispatchTime.now().uptimeNanoseconds
                let sections = ClipGrouper.group(
                    clips: response.clips,
                    calendar: .current,
                    now: Date()
                )
                _ = sections.flatMap(\.clips).map(\.id)
                let mainEnd = DispatchTime.now().uptimeNanoseconds
                if elapsed <= best {
                    best = elapsed
                    hits = response.clips.count
                    tier = response.metrics?.textTier
                    ids = response.clips.map(\.dbID)
                    candidateMS = response.metrics?.validationMS ?? 0
                    rankingMS = response.metrics?.rankingMS ?? 0
                    mainActorMS = Double(mainEnd - mainStart) / 1_000_000
                }
            }
            return (hits, best, tier, ids, candidateMS, rankingMS, mainActorMS)
        }

        func label(_ tier: SearchTextTier?) -> String {
            switch tier {
            case .sqlExact: return "SQL 精确谓词"
            case .ftsCandidates: return "FTS 候选+内存验证"
            case .memoryScan: return "内存全量扫描"
            case nil: return "—"
            }
        }

        var mismatches = 0
        var sqlSpeedups: [Double] = []
        func pad(_ value: String, _ width: Int, alignRight: Bool = false) -> String {
            let length = value.count
            guard length < width else { return value }
            let fill = String(repeating: " ", count: width - length)
            return alignRight ? fill + value : value + fill
        }
        print(
            pad("查询", 22) + pad("命中", 6, alignRight: true)
                + pad("命中文本", 12, alignRight: true)
                + pad("打分重扫", 12, alignRight: true)
                + pad("rank()", 12, alignRight: true)
                + pad("候选计算", 14, alignRight: true)
                + pad("排序", 10, alignRight: true)
                + pad("主线程", 12, alignRight: true)
                + pad("引擎合计", 12, alignRight: true)
                + "  路径"
        )
        var cases: [(label: String, query: String, plan: SearchQueryPlan)] = []
        cases.append(
            (
                "（默认视图：空查询）",
                "",
                SearchQueryPlan(
                    originalQuery: "",
                    keywordGroups: [],
                    excludedKeywords: [],
                    timeRange: nil,
                    kinds: [],
                    smartTags: [],
                    sort: .relevance,
                    limit: nil
                )
            )
        )
        for query in exampleQueries(
            from: store,
            derivedClips: derivedClips,
            extra: extraQueries
        ) {
            guard let plan = plans(for: query).first?.plan else { continue }
            cases.append((query, query, plan))

            cases.append(
                (
                    query + " ·newest",
                    query,
                    SearchQueryPlan(
                        originalQuery: plan.originalQuery,
                        keywordGroups: plan.keywordGroups,
                        excludedKeywords: plan.excludedKeywords,
                        timeRange: plan.timeRange,
                        kinds: plan.kinds,
                        smartTags: plan.smartTags,
                        sort: .newest,
                        limit: plan.limit
                    )
                )
            )
        }
        for entry in cases {
            let query = entry.query
            let plan = entry.plan
            let reference = measure(oracle, query: query, plan: plan)
            let optimized = measure(fast, query: query, plan: plan)
            let same = reference.ids == optimized.ids
            if !same { mismatches += 1 }
            if optimized.tier == .sqlExact, optimized.ms > 0 {
                sqlSpeedups.append(reference.ms / optimized.ms)
            }

            let term = plan.keywordGroups.first?.first
            var hitBytes = 0
            var maxBytes = 0
            var rescanSeconds = 0.0
            var rankSeconds = 0.0
            if let term {
                let rescanStart = DispatchTime.now().uptimeNanoseconds
                var rankCandidates: [RankCandidate] = []
                rankCandidates.reserveCapacity(optimized.ids.count)
                for id in optimized.ids {
                    guard let fields = store.memoryIndex.normalizedFields(
                        dbID: id
                    ) else { continue }
                    hitBytes += fields.body.utf8.count + fields.note.utf8.count
                    maxBytes = max(maxBytes, fields.body.utf8.count)
                    _ = fields.body.range(of: term)
                    _ = fields.note.range(of: term)
                    if let clip = store.clip(dbID: id) {
                        rankCandidates.append(
                            RankCandidate(clip: clip, fields: fields)
                        )
                    }
                }
                rescanSeconds =
                    Double(DispatchTime.now().uptimeNanoseconds - rescanStart)
                    / 1_000_000_000
                let rankStart = DispatchTime.now().uptimeNanoseconds
                _ = SearchRanker.rank(
                    candidates: rankCandidates,
                    groups: plan.keywordGroups,
                    now: Date()
                )
                rankSeconds =
                    Double(DispatchTime.now().uptimeNanoseconds - rankStart)
                    / 1_000_000_000
            }
            print(
                pad(entry.label, 22)
                    + pad("\(reference.hits)", 6, alignRight: true)
                    + pad(
                        String(
                            format: "%.1f MB",
                            Double(hitBytes) / 1_048_576
                        )
                            + (maxBytes > 1_048_576
                                ? " max\(maxBytes / 1_048_576)MB"
                                : ""),
                        12,
                        alignRight: true
                    )
                    + pad(
                        String(format: "%.1f ms", rescanSeconds * 1_000),
                        12,
                        alignRight: true
                    )
                    + pad(
                        String(format: "%.1f ms", rankSeconds * 1_000),
                        12,
                        alignRight: true
                    )
                    + pad(String(format: "%.1f ms", optimized.candidateMS), 14, alignRight: true)
                    + pad(String(format: "%.1f ms", optimized.rankingMS), 10, alignRight: true)
                    + pad(String(format: "%.1f ms", optimized.mainActorMS), 12, alignRight: true)
                    + pad(String(format: "%.1f ms", optimized.ms), 12, alignRight: true)
                    + "  " + label(optimized.tier)
            )
            print(
                pad("  ↳ 参考实现", 22)
                    + pad("", 6)
                    + pad("", 12)
                    + pad("", 12)
                    + pad("", 12)
                    + pad(String(format: "%.1f ms", reference.candidateMS), 14, alignRight: true)
                    + pad(String(format: "%.1f ms", reference.rankingMS), 10, alignRight: true)
                    + pad(String(format: "%.1f ms", reference.mainActorMS), 12, alignRight: true)
                    + pad(String(format: "%.1f ms", reference.ms), 12, alignRight: true)
                    + "  " + label(reference.tier)
                    + (same ? "" : "   不一致 ←")
            )
        }
        if !sqlSpeedups.isEmpty {
            let average = sqlSpeedups.reduce(0, +) / Double(sqlSpeedups.count)
            print(String(
                format: "[EXAMPLES] %d 条走 SQL 精确谓词的查询平均提速 %.1f×",
                sqlSpeedups.count,
                average
            ))
        }
        print("[EXAMPLES] 结果不一致 \(mismatches) 条")
        return mismatches == 0 ? 0 : 1
    }

    static func exampleQueries(
        from store: ClipStore,
        derivedClips: Int = 4,
        extra: [String] = []
    ) -> [String] {
        var queries = ["k", "ku", "zzzz-nothing-matches"]
        queries.append(contentsOf: extra)
        var derived = 0
        for clip in store.items {
            guard derived < derivedClips else { break }
            let characters = Array(QueryNormalizer.normalize(clip.text))
            guard characters.count >= 12 else { continue }
            derived += 1
            queries.append(String(characters[0..<1]))
            queries.append(String(characters[0..<2]))
            queries.append(String(characters[4..<12]))
        }
        var seen = Set<String>()
        return queries.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func run(directory: URL?, probeLimit: Int = 60) -> Int32 {
        print("========== Clipa Search Parity ==========")
        let isTemporary: Bool
        let baseDirectory: URL
        if let directory {
            isTemporary = false
            baseDirectory = directory
        } else {
            isTemporary = true
            baseDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClipaParity-\(UUID().uuidString)",
                    isDirectory: true
                )
        }
        let defaults = UserDefaults(suiteName: "ClipaParity-\(UUID().uuidString)")!
        let store = ClipStore(
            baseDirectory: baseDirectory,
            settingsStore: SettingsStore(defaults: defaults)
        )
        if isTemporary {
            let inserted = store.replaceAllForTesting(adversarialCorpus())
            print("[PARITY] synthetic corpus: \(inserted.count) clips")
        } else {
            print("[PARITY] store: \(baseDirectory.path) — \(store.items.count) clips")
        }

        guard let database = store.database else {
            print("[PARITY] store unavailable, nothing to compare")
            return 1
        }
        let status = (try? DatabaseBridge.normalizationStatus(database))
            ?? (ready: false, pending: -1, clips: -1)
        print("""
            [PARITY] normalization ready=\(status.ready) \
            pending=\(status.pending) clips=\(status.clips)
            """)

        let queries = adversarialQueries()
        var timing = Timing()
        let adversarial = compare(store: store, queries: adversarialQueries())
        let probeComparisons = compare(
            store: store,
            queries: probes(from: store, limit: probeLimit),
            planShapes: .wholeKeywordOnly,
            timing: &timing
        )
        let comparisons = adversarial + probeComparisons
        let mismatches = comparisons.filter { !$0.isMatch }

        let scoringMismatches = Self.scoringMismatches(
            store: store,
            queries: adversarialQueries()
        )

        let engaged = comparisons.filter(\.fastPathEngaged).count
        print("""
            [PARITY] \(comparisons.count) comparisons \
            (\(queries.count) queries), fast path engaged \(engaged), \
            mismatches \(mismatches.count), scoring mismatches \(scoringMismatches.count)
            """)
        print(String(
            format: """
                [PARITY] probe timing: all %d calls — oracle avg %.1f ms, \
                fast avg %.1f ms; fast path engaged %d — oracle %.1f ms vs \
                fast %.1f ms on the same calls
                """,
            timing.oracleCalls,
            timing.oracleAverageMS,
            timing.fastAverageMS,
            timing.engagedCalls,
            timing.engagedOracleAverageMS,
            timing.engagedAverageMS
        ))
        for mismatch in mismatches.prefix(20) {
            print("""
                [MISMATCH] query="\(mismatch.query)" plan=\(mismatch.planShape)
                  oracle=\(mismatch.oracle)
                  fast  =\(mismatch.fast)
                """)
        }

        var failures = 0
        if !status.ready {
            print("[PARITY] FAIL: normalization columns are not ready")
            failures += 1
        }
        if engaged == 0 {
            print("[PARITY] FAIL: fast path never engaged, comparison is vacuous")
            failures += 1
        }
        if !mismatches.isEmpty {
            failures += 1
        }
        if !scoringMismatches.isEmpty {
            failures += 1
        }
        if isTemporary {
            try? FileManager.default.removeItem(at: baseDirectory)
        }
        if failures == 0 {
            print("[PARITY] 全部一致")
            return 0
        }
        print("[PARITY] \(failures) 项失败")
        return 1
    }

    private enum DatabaseBridge {
        static func normalizationStatus(
            _ database: DatabaseManager
        ) throws -> (ready: Bool, pending: Int, clips: Int) {
            try DatabaseSync.run(database) { db in
                try await db.searchNormalizationStatus()
            }
        }
    }
}
