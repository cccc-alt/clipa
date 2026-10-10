import AppKit
import Foundation

// P0 修复（2026-10-02）：SIGPIPE 的默认处置是**终止进程**——本进程要写 Unix
// socket（本地接口服务器、CLI 客户端），对端发完请求就断（Agent 超时很常见）
// 时，一次 send 就能杀死整个应用。改为忽略信号，让 write/send 返回 EPIPE，
// 按普通失败处理；各 socket 另设 SO_NOSIGPIPE（见 SocketProtection），双保险。
signal(SIGPIPE, SIG_IGN)

// 以 `clipa` 这个名字被调用（App 包里那个助手）时，整个进程就是一个 CLI 客户端：
// 不启动 GUI、不读数据库，只把请求转给正在运行的应用。**必须在任何探针分支之前**，
// 否则 `clipa status` 会先被别的 flag 分支接走。
if (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "")
    == "clipa" {
    exit(APIClientCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
}

// MCP stdio 薄壳（2026-10-01 U2）：已安装的机器上由 Helpers/clipa-mcp 这个副本
// 走上面的 basename 路由；显式开关 `--mcp-stdio` 给探针用——用主二进制当薄壳
// 测整条管道。
if (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "")
    == "clipa-mcp"
    || CommandLine.arguments.contains("--mcp-stdio") {
    exit(APIMcp.run())
}

// 同一个入口的显式写法，给"用主二进制测 CLI"用：`Clipa.app/.../Clipa --api-cli status`。
if let index = CommandLine.arguments.firstIndex(of: "--api-cli") {
    exit(
        APIClientCLI.run(
            arguments: Array(CommandLine.arguments.suffix(from: index + 1))
        )
    )
}

/// Every CLI mode below runs against an isolated data directory. Without this
/// the test harness would reach `ClipStore.shared` and mutate the user's real
/// history (it did exactly that during the v6→v7 image migration).
private func useIsolatedStoreForCLIMode(isolateKeychain: Bool = true) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ClipaCLI-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
    ClipStore.defaultBaseDirectoryOverride = dir
    // 令牌文件同样要隔离：否则探针会在用户的令牌列表里塞一个测试令牌。
    APITokenStore.directoryOverride = dir
    // 钥匙串也一并隔离：私密测试用进程内随机密钥，绝不碰用户的登录钥匙串。
    // 不隔离的话，测试二进制的身份不在条目 ACL 里时，securityd 会弹授权框
    // 把自检挂死（2026-10-01 实测踩过）。唯一不隔离的是 --crypto-probe：
    // 真碰钥匙串正是它要验的东西。
    if isolateKeychain, let key = try? StoreCrypto.generateKey() {
        StoreCrypto.isolationKey = key
        DBKey.isolationSeed = key
    }
}

/// `--flag value` lookup for the CLI probes.
private func argumentValue(_ flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

if CommandLine.arguments.contains("--storage-search-probe") {
    useIsolatedStoreForCLIMode()
    Task { @MainActor in exit(await StorageSearchProbe.run()) }
    dispatchMain()
}

if CommandLine.arguments.contains("--storage-search-bench") {
    useIsolatedStoreForCLIMode()
    exit(StorageSearchBenchmark.run())
}

if CommandLine.arguments.contains("--onboarding-probe") {
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated { exit(OnboardingProbe.run()) }
}
if let path = argumentValue("--capture-onboarding") {
    MainActor.assumeIsolated {
        OnboardingCapture.run(path: path,
                              step: OnboardingStep(rawValue: Int(argumentValue("--onboarding-step") ?? "0") ?? 0) ?? .welcome,
                              dark: CommandLine.arguments.contains("--ui-dark"),
                              loginError: CommandLine.arguments.contains("--ui-error"))
        exit(0)
    }
}

// UI renders use synthetic stores and ephemeral keys, including native menu previews.
if CommandLine.arguments.contains(where: { $0.hasPrefix("--capture-ui") || $0 == "--capture-menu" || $0 == "--capture-settings" }) {
    useIsolatedStoreForCLIMode()
}
if CommandLine.arguments.contains("--workflow-probe") {
    useIsolatedStoreForCLIMode()
    Task { @MainActor in exit(await WorkflowProbe.run()) }
    dispatchMain()
}
if let path = argumentValue("--capture-settings") {
    let page = ManagementPage(rawValue: argumentValue("--settings-page") ?? "general") ?? .general
    MainActor.assumeIsolated {
        ManagementCapture.run(path: path, page: page, sheet: argumentValue("--settings-sheet"))
        exit(0)
    }
}

if let path = argumentValue("--capture-menu") {
    MainActor.assumeIsolated {
        UICapture.captureMenu(path: path)
        exit(0)
    }
}

if CommandLine.arguments.contains("--panel-presentation-probe") {
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.panelPresentationProbe())
    }
}

if CommandLine.arguments.contains("--panel-retention-probe") {
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.panelRetentionProbe())
    }
}

if CommandLine.arguments.contains("--menu-structure-probe") {
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.menuStructureProbe())
    }
}

if CommandLine.arguments.contains("--classification-corpus") {
    // 分类语料：`Sources/Clipa/Tests/ClassificationCorpus.swift` 里那 100 多个用例。
    // （接入时它的理由是"规则包改的正是分类这一层"——规则包已于 2026-09-27 删除，
    // 但语料本身仍然有用：它跑的是内置判定，是分类行为唯一的一份可执行基线。）
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(ClassificationCorpus.run())
    }
}

if CommandLine.arguments.contains("--crypto-probe") {
    // M3（私密加密）的硬规则自检：钥匙串密钥、字节级落盘证据、三层索引一致、
    // 以及"老库迁移后明文从文件里消失"。用隔离目录，但**用真实钥匙串**——那正是
    // 它要验的东西之一。
    useIsolatedStoreForCLIMode(isolateKeychain: false)
    MainActor.assumeIsolated {
        exit(SelfTest.cryptoProbe())
    }
}

if CommandLine.arguments.contains("--api-probe") {
    // 本地控制面（M2）的硬规则自检：私密硬排除、作用域、写动词的闸、审计、socket 往返。
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.apiProbe())
    }
}

if CommandLine.arguments.contains("--mcp-probe") {
    // MCP stdio 薄壳的管道自检：initialize 握手、tools/list、tools/call 的翻译。
    // 策略层不在这里验 —— 那是 --api-probe 的事，薄壳只是转接。
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.mcpProbe())
    }
}

if CommandLine.arguments.contains("--panel-memory-probe") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.panelMemoryProbe(directory: directory))
    }
}

if CommandLine.arguments.contains("--compare-probe") {
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.compareProbe())
    }
}

if CommandLine.arguments.contains("--capture-evaluate") {
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.captureEvaluateProbe())
    }
}

if CommandLine.arguments.contains("--classification-perf") {
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.classificationPerfProbe())
    }
}

// CLI self-test / UI capture hooks run before any GUI application is created.
// NOTE (2026-09-23): the probe functions behind these seven entries were lost
// while deleting the AI-enhanced search module, and have since been rewritten
// from scratch (see docs/verification.md). They cover the same ground as the
// originals — panel geometry/pointer/keyboard, workspace retention and memory,
// the saved-rule path, engine-vs-brute-force parity, the capture gate and the
// classifier's accuracy/cost.

if CommandLine.arguments.contains("--selftest") {
    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.run())
    }
}

if CommandLine.arguments.contains("--async-store-probe") {
    useIsolatedStoreForCLIMode()
    exit(SelfTest.asyncStoreProbe())
}
// Parity runs against `--dir` when given (a copy of a real library is the
// useful case) and against a synthetic adversarial store otherwise, so it
// never needs the user's live store to be meaningful.
if CommandLine.arguments.contains("--search-parity") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    }
    let probes = Int(argumentValue("--probes") ?? "") ?? 60
    if directory == nil { useIsolatedStoreForCLIMode() }
    MainActor.assumeIsolated {
        exit(SearchParity.run(directory: directory, probeLimit: probes))
    }
}

// Per-query report of the same optimization: which tier each query took and
// what it cost, side by side with the reference implementation.
if CommandLine.arguments.contains("--search-examples") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    }
    let derived = Int(argumentValue("--probes") ?? "") ?? 4
    let extra = (argumentValue("--queries") ?? "")
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    MainActor.assumeIsolated {
        exit(
            SearchParity.runExamples(
                directory: directory,
                derivedClips: derived,
                extraQueries: extra
            )
        )
    }
}

// Costs outside the measured engine: store open (FTS rebuild) and the
// per-search learning lookup.
if CommandLine.arguments.contains("--search-overhead") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    }
    exit(SearchParity.runOverhead(directory: directory))
}

// Search index maintenance: `--fts-status` reports the trust decision,
// `--rebuild-fts` rebuilds and re-stamps the index marker.
if CommandLine.arguments.contains("--fts-status")
    || CommandLine.arguments.contains("--rebuild-fts") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    }
    let rebuild = CommandLine.arguments.contains("--rebuild-fts")
    exit(SearchParity.runFTSMaintenance(directory: directory, rebuild: rebuild))
}

// Stress seeding/benchmarking deliberately targets whatever `--dir` points at
// (default: the real store) instead of an isolated directory, so it does NOT
// call `useIsolatedStoreForCLIMode`.
if CommandLine.arguments.contains("--stress-seed") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    } ?? ClipStore.defaultBaseDirectory()
    let total = Int(argumentValue("--count") ?? "") ?? 2001
    let seed = UInt64(argumentValue("--seed") ?? "") ?? 20_260_911
    print("[STRESS] target store: \(directory.path)")
    exit(StressTest.runSeed(directory: directory, total: total, seedValue: seed))
}

if CommandLine.arguments.contains("--stress-bench") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    } ?? ClipStore.defaultBaseDirectory()
    let rounds = Int(argumentValue("--rounds") ?? "") ?? 10
    let itemLimit = Int(argumentValue("--items") ?? "")
    let destructive = CommandLine.arguments.contains("--destructive")
    print("[BENCH] target store: \(directory.path)")
    exit(
        StressTest.runBench(
            directory: directory,
            rounds: rounds,
            itemLimit: itemLimit,
            destructive: destructive
        )
    )
}

// The one property the parity harness structurally cannot see: FTS style
// narrowing must never drop a row the true predicate matches. Parity compares
// the engine against an oracle that narrows by the *same* candidate set, so a
// row lost in narrowing disappears from both sides and the comparison still
// passes. `--search-recall-audit` recomputes the text match with no narrowing
// at all and reports every row the engine failed to return.
if CommandLine.arguments.contains("--search-recall-audit") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    }
    let probes = Int(argumentValue("--probes") ?? "") ?? 4
    let extra = (argumentValue("--queries") ?? "")
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let synthetic = CommandLine.arguments.contains("--synthetic")
    if synthetic { useIsolatedStoreForCLIMode() }
    MainActor.assumeIsolated {
        exit(
            ScaleStressTest.runSearchRecallAudit(
                directory: directory,
                derivedProbes: probes,
                extraQueries: extra,
                synthetic: synthetic
            )
        )
    }
}

if CommandLine.arguments.contains("--stress-import") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    } ?? ClipStore.defaultBaseDirectory()
    guard let dataset = argumentValue("--dataset") else {
        print("[IMPORT] --dataset <path> is required")
        exit(1)
    }
    print("[IMPORT] target store: \(directory.path)")
    exit(
        StressTest.runImport(
            directory: directory,
            datasetRoot: URL(fileURLWithPath: dataset)
        )
    )
}

if CommandLine.arguments.contains("--stress-reclassify") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    } ?? ClipStore.defaultBaseDirectory()
    print("[RECLASSIFY] target store: \(directory.path)")
    exit(StressTest.runReclassify(directory: directory))
}

// Scale load/bench target whatever `--dir` points at (default: the real
// store), like the other stress modes. Both run inside a main-actor task so
// the async store/search paths can be awaited without blocking the main
// thread, and exit from inside the task so `dispatchMain()` can take over.
if CommandLine.arguments.contains("--scale-load") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    } ?? ClipStore.defaultBaseDirectory()
    let images = Int(argumentValue("--images") ?? "") ?? 2_000
    let bigImages = Int(argumentValue("--big-images") ?? "") ?? 500
    let bigMegabytes = Double(argumentValue("--big-mb") ?? "") ?? 20
    let texts = Int(argumentValue("--texts") ?? "") ?? 100_000
    let seed = UInt64(argumentValue("--seed") ?? "") ?? 20_260_913
    Task { @MainActor in
        let code = await ScaleStressTest.runLoad(
            directory: directory,
            imageCount: images,
            bigImageCount: bigImages,
            bigImageMegabytes: bigMegabytes,
            textCount: texts,
            seedValue: seed
        )
        exit(code)
    }
    dispatchMain()
}
// Before/after numbers for the panel list windowing, on whatever store
// `--dir` points at.
if CommandLine.arguments.contains("--memory-breakdown") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    } ?? ClipStore.defaultBaseDirectory()
    print("[MEM] target store: \(directory.path)")
    Task { @MainActor in
        exit(ScaleStressTest.runMemoryBreakdown(directory: directory))
    }
    dispatchMain()
}

// Scores the AI query-understanding call against a fixed probe set.
if CommandLine.arguments.contains("--workspace-retention-probe") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    } ?? ClipStore.defaultBaseDirectory()
    print("[WSRET] target store: \(directory.path)")
    Task { @MainActor in
        exit(
            ScaleStressTest.runWorkspaceRetentionProbe(directory: directory)
        )
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--panel-window-bench") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    } ?? ClipStore.defaultBaseDirectory()
    print("[WINDOW] target store: \(directory.path)")
    Task { @MainActor in
        exit(ScaleStressTest.runPanelWindowBench(directory: directory))
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--migrate-image-storage") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    } ?? ClipStore.defaultBaseDirectory()
    let batchSize = Int(argumentValue("--batch") ?? "") ?? 20
    print("[IMAGES] target store: \(directory.path)")
    Task { @MainActor in
        let store = ClipStore(baseDirectory: directory)
        guard store.database != nil else {
            print("[IMAGES] store unavailable")
            exit(1)
        }
        _ = await store.migrateImagesToOwnTableAsync(batchSize: batchSize)
        exit(0)
    }
    dispatchMain()
}

if let index = CommandLine.arguments.firstIndex(of: "--capture-ui"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        UICapture.capture(path: CommandLine.arguments[index + 1])
        exit(0)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--capture-ui-normal"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        UICapture.capture(
            path: CommandLine.arguments[index + 1],
            scenario: .normal
        )
        exit(0)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--capture-ui-private"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        UICapture.capture(
            path: CommandLine.arguments[index + 1],
            scenario: .privateLocked
        )
        exit(0)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--capture-ui-tags"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        UICapture.capture(
            path: CommandLine.arguments[index + 1],
            scenario: .classification
        )
        exit(0)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--capture-ui-note"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        UICapture.capture(
            path: CommandLine.arguments[index + 1],
            scenario: .noteEditor
        )
        exit(0)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--capture-ui-image"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        UICapture.capture(
            path: CommandLine.arguments[index + 1],
            scenario: .imageClip
        )
        exit(0)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--capture-ui-strip"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        UICapture.capture(
            path: CommandLine.arguments[index + 1],
            scenario: .quickStrip
        )
        exit(0)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--capture-ui-empty"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        UICapture.capture(
            path: CommandLine.arguments[index + 1],
            scenario: .emptyHistory
        )
        exit(0)
    }
}


if let index = CommandLine.arguments.firstIndex(of: "--capture-ui-store-unavailable"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        UICapture.capture(
            path: CommandLine.arguments[index + 1],
            scenario: .storeUnavailable
        )
        exit(0)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--record-demo"),
   index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        exit(
            DemoRecorder.run(
                framesRoot: CommandLine.arguments[index + 1]
            )
        )
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
