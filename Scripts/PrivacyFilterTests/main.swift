import AppKit
import Foundation

// Real-environment checks for:
// 1. 自动忽略密码管理器（按来源应用 bundle id）
// 2. 自动跳过敏感内容（sk- / AKIA / ghp_ / xoxb / Bearer / PEM）
// 3. 应用自报的机密标记（org.nspasteboard.ConcealedType / TransientType）
//
// Uses a real NSPasteboard object (isolated name, not the user's general
// pasteboard), an isolated UserDefaults suite and a temporary ClipStore, so
// the checks exercise the genuine capture pipeline without touching live data.

var passed = 0
var failed = 0
var failures: [String] = []

func check(_ name: String, _ condition: Bool, detail: String = "") {
    if condition {
        passed += 1
    } else {
        failed += 1
        failures.append(name + (detail.isEmpty ? "" : " — \(detail)"))
    }
}

let suiteName = "ClipaPrivacyFilterTest-\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suiteName) else {
    print("无法创建隔离 UserDefaults")
    exit(1)
}
defaults.removePersistentDomain(forName: suiteName)
let settings = SettingsStore(defaults: defaults)

let storeDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipaPrivacyFilterStore-\(UUID().uuidString)", isDirectory: true)
let store = ClipStore(baseDirectory: storeDir)
let monitor = ClipboardMonitor.shared

func pasteboard(text: String, markers: [String] = []) -> NSPasteboard {
    let pb = NSPasteboard(name: NSPasteboard.Name("ClipaFilterPB-\(UUID().uuidString)"))
    pb.clearContents()
    pb.setString(text, forType: .string)
    for marker in markers {
        // Apps publish the marker as its own flavor, alongside the payload the
        // user would actually paste.
        pb.setData(
            Data(marker.utf8),
            forType: NSPasteboard.PasteboardType(marker)
        )
    }
    return pb
}

func decide(
    _ text: String,
    from bundleID: String?,
    pause: Bool = false,
    ignorePM: Bool = true,
    skipSensitive: Bool,
    markers: [String] = [],
    skipConfidential: Bool = true
) -> ClipboardMonitor.CaptureDecision {
    settings.pauseRecording = pause
    settings.ignorePasswordManagers = ignorePM
    settings.skipSensitive = skipSensitive
    settings.skipConfidentialPasteboard = skipConfidential
    return monitor.evaluate(
        pasteboard: pasteboard(text: text, markers: markers),
        frontBundleID: bundleID,
        sourceName: "TestApp",
        settings: settings,
        store: store
    )
}

// MARK: - 自动忽略密码管理器

for bundleID in SettingsStore.defaultPasswordManagerBundleIDs {
    let decision = decide(
        "s3cr3t-password-\(bundleID)",
        from: bundleID,
        skipSensitive: false
    )
    check(
        "忽略密码管理器：\(bundleID)",
        decision == .ignoredSource,
        detail: String(describing: decision)
    )
}

let onePassword = SettingsStore.defaultPasswordManagerBundleIDs[0]
let offDecision = decide(
    "s3cr3t-password-visible",
    from: onePassword,
    ignorePM: false,
    skipSensitive: false
)
if case .captured(let item) = offDecision {
    check(
        "关闭忽略后密码管理器内容可记录",
        item.text == "s3cr3t-password-visible"
    )
} else {
    check("关闭忽略后密码管理器内容可记录", false, detail: String(describing: offDecision))
}

let terminalDecision = decide(
    "kubectl get pods -A",
    from: "com.apple.Terminal",
    skipSensitive: false
)
if case .captured = terminalDecision {
    check("普通应用不受密码管理器忽略影响", true)
} else {
    check("普通应用不受密码管理器忽略影响", false, detail: String(describing: terminalDecision))
}

// MARK: - 自动跳过敏感内容

let sensitiveSamples = [
    "sk-" + "0123456789abcdef0123456789abcdef",
    "AKIA" + "IOSFODNN7EXAMPLE",
    "ghp_" + "abcdefghijklmnopqrstuvwxyz123456",
    "xoxb-" + "123456789012-abcdefghijklmno",
    "Authorization: Bearer " + "eyJhbGciOiJIUzI1NiJ9" + ".payload.signature",
    "-----BEGIN " + "RSA PRIVATE KEY-----\n" + "MIIEowIBAAKCAQEA" + "\n-----END RSA PRIVATE KEY-----",
    "password: hunter2hunter2",
    "api_key=abcdefgh123456",
    "密钥：abcdefgh1234567890",
    // Categories only the extended rules know about: the skip gate has to use
    // the same predicate as the stored marker, or these reach the history.
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r",
    "postgres://admin:S3cret@db.internal:5432/app",
    "mongodb+srv://svc:Pa55w0rd@cluster0.example.net/db",
    "redis://default:foobared@cache.internal:6379",
    "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----",
    #"{"password": "hunter2hunter2"}"#,
    // P0 boundary: crypt hashes start with `$` and must survive the
    // reference/template downgrade.
    "password: $6$i3/J6tE.gh$ccHhabK2FsPT2U2OwMDiFZSPL7L18K",
    "password: $y$j9T$21VgKI4Ug8Q/odUe/Tne31$6.0V1o7A4OJEjI8zXw9",
    "password: $0$admin",
    #"password: abc${REF}xyz123"#
]

// Values that only point at a credential: recorded normally, never skipped.
let referenceSamples = [
    "password: ${DB_PASSWORD}",
    "password: ${DB_PASSWORD:-}",
    "password: ${DB_PASSWORD:=fallback}",
    "password: $DB_PASSWORD",
    #"{"password": "@env:AC_PASSWORD"}"#,
    #"{"password": "[parameters('windowsAdminPassword')]"}"#,
    #"{"password": "${{ secrets.DB_PASSWORD }}"}"#
]

for (index, sample) in referenceSamples.enumerated() {
    let decision = decide(
        sample,
        from: "com.apple.Safari",
        skipSensitive: true
    )
    if case .captured = decision {
        check("引用/模板值不算敏感 #\(index + 1)", true)
    } else {
        check(
            "引用/模板值不算敏感 #\(index + 1)",
            false,
            detail: String(describing: decision)
        )
    }
}

for (index, sample) in sensitiveSamples.enumerated() {
    let skipped = decide(
        sample,
        from: "com.apple.Safari",
        skipSensitive: true
    )
    check(
        "自动跳过敏感 #\(index + 1)",
        skipped == .sensitiveSkipped,
        detail: String(describing: skipped)
    )
}

let allowSensitive = decide(
    "sk-" + "0123456789abcdef0123456789abcdef",
    from: "com.apple.Safari",
    skipSensitive: false
)
if case .captured(let item) = allowSensitive {
    check(
        "关闭跳过敏感后仍可记录（带敏感标记）",
        SensitiveDetector.containsSensitive(text: item.text)
    )
} else {
    check("关闭跳过敏感后仍可记录（带敏感标记）", false, detail: String(describing: allowSensitive))
}

let normalDecision = decide(
    "本周完成核心功能迭代，稳定性明显提升。",
    from: "com.apple.Safari",
    skipSensitive: true
)
if case .captured = normalDecision {
    check("普通内容不被敏感规则误杀", true)
} else {
    check("普通内容不被敏感规则误杀", false, detail: String(describing: normalDecision))
}

// MARK: - 应用自报的机密标记

// 本组的重点是「名单之外的来源」：一个从没被列进任何忽略名单的工具，复制一个
// 没有 password / token 字样的随机密码。以前它会被完整记录、且不带任何敏感
// 提示（纯随机串命不中凭证规则）；现在必须整条丢弃。
let concealedType = "org.nspasteboard.ConcealedType"
let transientType = "org.nspasteboard.TransientType"

let concealedSecret = decide(
    "Xk7m2Qp9vT4w9Zq",
    from: "com.example.internal-secret-tool",
    skipSensitive: false,
    markers: [concealedType]
)
check(
    "机密标记：名单外工具的密码不被记录",
    concealedSecret == .confidentialSkipped,
    detail: String(describing: concealedSecret)
)

let transientCopy = decide(
    "程序自己放上去的临时内容",
    from: "com.apple.Safari",
    skipSensitive: false,
    markers: [transientType]
)
check(
    "临时标记：不被记录",
    transientCopy == .confidentialSkipped,
    detail: String(describing: transientCopy)
)

// 同一个来源、同类内容，只是没带标记：仍然正常记录。标记不能退化成
// 「这个 App 的内容全部丢弃」。
let unmarkedSameApp = decide(
    "Xk7m2Qp9vT4w9Zq",
    from: "com.example.internal-secret-tool",
    skipSensitive: false
)
if case .captured(let item) = unmarkedSameApp {
    check("无标记的同源内容照常记录", item.text == "Xk7m2Qp9vT4w9Zq")
} else {
    check(
        "无标记的同源内容照常记录",
        false,
        detail: String(describing: unmarkedSameApp)
    )
}

// 图片 + 机密标记：判定看的是类型表，与内容形态无关。
let sealedImagePB = NSPasteboard(
    name: NSPasteboard.Name("ClipaFilterImage-\(UUID().uuidString)")
)
sealedImagePB.clearContents()
sealedImagePB.setData(
    Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!,
    forType: .png
)
sealedImagePB.setData(
    Data("1".utf8),
    forType: NSPasteboard.PasteboardType(concealedType)
)
settings.skipConfidentialPasteboard = true
let sealedImage = monitor.evaluate(
    pasteboard: sealedImagePB,
    frontBundleID: "com.apple.Safari",
    sourceName: "Safari",
    settings: settings,
    store: store
)
check(
    "机密标记：图片同样不被记录",
    sealedImage == .confidentialSkipped,
    detail: String(describing: sealedImage)
)

// 开关关闭后恢复旧行为——用户能自己验证这条标记到底做了什么。
let optedOut = decide(
    "Xk7m2Qp9vT4w9Zq",
    from: "com.example.internal-secret-tool",
    skipSensitive: false,
    markers: [concealedType],
    skipConfidential: false
)
if case .captured(let item) = optedOut {
    check("关闭开关后标记内容重新可记录", item.text == "Xk7m2Qp9vT4w9Zq")
} else {
    check(
        "关闭开关后标记内容重新可记录",
        false,
        detail: String(describing: optedOut)
    )
}

// MARK: - 汇总

try? FileManager.default.removeItem(at: storeDir)
defaults.removePersistentDomain(forName: suiteName)

print("隐私过滤真实环境测试：通过 \(passed)，失败 \(failed)")
if !failures.isEmpty {
    print("失败明细：")
    for item in failures {
        print("  - \(item)")
    }
    exit(1)
}
