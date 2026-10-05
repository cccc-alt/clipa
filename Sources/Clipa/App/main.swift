import AppKit
import Foundation

signal(SIGPIPE, SIG_IGN)

if (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "")
    == "clipa" {
    exit(APIClientCLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
}

if (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "")
    == "clipa-mcp"
    || CommandLine.arguments.contains("--mcp-stdio") {
    exit(APIMcp.run())
}

if let index = CommandLine.arguments.firstIndex(of: "--api-cli") {
    exit(
        APIClientCLI.run(
            arguments: Array(CommandLine.arguments.suffix(from: index + 1))
        )
    )
}

private func useIsolatedStoreForCLIMode(isolateKeychain: Bool = true) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ClipaCLI-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
    ClipStore.defaultBaseDirectoryOverride = dir

    APITokenStore.directoryOverride = dir

    if isolateKeychain, let key = try? StoreCrypto.generateKey() {
        StoreCrypto.isolationKey = key
        DBKey.isolationSeed = key
    }
}

private func argumentValue(_ flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
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

    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(ClassificationCorpus.run())
    }
}

if CommandLine.arguments.contains("--crypto-probe") {

    useIsolatedStoreForCLIMode(isolateKeychain: false)
    MainActor.assumeIsolated {
        exit(SelfTest.cryptoProbe())
    }
}

if CommandLine.arguments.contains("--api-probe") {

    useIsolatedStoreForCLIMode()
    MainActor.assumeIsolated {
        exit(SelfTest.apiProbe())
    }
}

if CommandLine.arguments.contains("--mcp-probe") {

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

/// CLI entry: self-tests, probes, stress tools, MCP/CLI dispatch.
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

if CommandLine.arguments.contains("--search-parity") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    }
    let probes = Int(argumentValue("--probes") ?? "") ?? 60
    MainActor.assumeIsolated {
        exit(SearchParity.run(directory: directory, probeLimit: probes))
    }
}

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

if CommandLine.arguments.contains("--search-overhead") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    }
    exit(SearchParity.runOverhead(directory: directory))
}

if CommandLine.arguments.contains("--fts-status")
    || CommandLine.arguments.contains("--rebuild-fts") {
    let directory = argumentValue("--dir").map {
        URL(fileURLWithPath: $0)
    }
    let rebuild = CommandLine.arguments.contains("--rebuild-fts")
    exit(SearchParity.runFTSMaintenance(directory: directory, rebuild: rebuild))
}

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
