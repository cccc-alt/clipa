import AppKit
import Foundation

/// Readable audit corpus for the most confusion-prone content categories.
/// Each category has 15 representative samples; expected values encode the
/// product intent described in the user manual, not today's implementation.
struct ConfusionAuditCase {
    let category: String
    let id: String
    let kind: ClipKind
    let text: String
    let expectedTag: SmartTag?
}

enum ConfusionAudit {
    private static func c(
        _ category: String,
        _ id: String,
        _ text: String,
        expected: SmartTag?,
        kind: ClipKind = .text
    ) -> ConfusionAuditCase {
        ConfusionAuditCase(
            category: category,
            id: id,
            kind: kind,
            text: text,
            expectedTag: expected
        )
    }

    static let textCases: [ConfusionAuditCase] = [
        // JSON
        c("json", "J-01", #"{"name":"tom","age":18}"#, expected: .json, kind: .text),
        c("json", "J-02", #"["nginx","redis"]"#, expected: .json, kind: .text),
        c("json", "J-03", #"{"server":{"host":"127.0.0.1","port":8080}}"#, expected: .json, kind: .text),
        c("json", "J-04", #"{"a":1,"b":2,"c":3}"#, expected: .json, kind: .text),
        c("json", "J-05", #"2026-09-09 10:00:01 INFO response={"status":"ok"}"#, expected: nil),
        c("json", "J-06", #"{name: "tom", age: 18}"#, expected: nil),
        c("json", "J-07", #"{"name": tom}"#, expected: nil),
        c("json", "J-08", #"{"a":1,}"#, expected: nil),
        c("json", "J-09", #"["a","b",]"#, expected: nil),
        c("json", "J-10", #"echo '{"a":1}'"#, expected: nil, kind: .text),
        c("json", "J-11", #"name: nginx"#, expected: nil),
        c("json", "J-12", #"{"message":"error","level":"ERROR","time":"2026-09-09T10:00:00Z"}"#, expected: .json, kind: .text),
        c("json", "J-13", "{\r\n  \"a\": 1\r\n}", expected: .json, kind: .text),
        c("json", "J-14", #"请把 {"a":1} 放到配置里"#, expected: nil),
        c("json", "J-15", #"{'a':1}"#, expected: nil),

        // YAML
        c("yaml", "Y-01", "name: nginx\nimage: nginx:latest\nreplicas: 3", expected: .yaml, kind: .text),
        c("yaml", "Y-02", "servers:\n  - web01\n  - web02", expected: .yaml, kind: .text),
        c("yaml", "Y-03", "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: nginx", expected: .yaml, kind: .text),
        c("yaml", "Y-04", "# comment\nserver:\n  host: localhost\n  port: 8080", expected: .yaml, kind: .text),
        c("yaml", "Y-05", "kind: 说明", expected: nil),
        c("yaml", "Y-06", "结论: 成功\n原因: 网络正常", expected: nil),
        c("yaml", "Y-07", "name: app\nversion: \"1.0\"\nenabled: true", expected: .yaml, kind: .text),
        c("yaml", "Y-08", "command:\n  - kubectl\n  - get\n  - pods", expected: .yaml, kind: .text),
        c("yaml", "Y-09", "default: &defaults\n  timeout: 30\nservice:\n  <<: *defaults", expected: .yaml, kind: .text),
        c("yaml", "Y-10", "message: |\n  hello\n  world", expected: .yaml, kind: .text),
        c("yaml", "Y-11", "2026-09-09 10:00:01 ERROR parse failed\nserver:\n  port: 80", expected: nil),
        c("yaml", "Y-12", "2026-09-09 10:00:01 INFO response={\"status\":\"ok\"}", expected: nil),
        c("yaml", "Y-13", "| a | b |\n|---|---|\n| 1 | 2 |", expected: .markdown),
        c("yaml", "Y-14", "- first\n- second\n- third", expected: .markdown),
        c("yaml", "Y-15", "server:host: 8080", expected: nil),

        // Markdown
        c("markdown", "M-01", "# 网络配置\n\n下面列出常用命令：\n\n- docker network ls\n- docker network inspect", expected: .markdown),
        c("markdown", "M-02", "## 说明\n\n```bash\necho hi\n```", expected: .markdown),
        c("markdown", "M-03", "| Name | Value |\n| --- | --- |\n| a | 1 |", expected: .markdown),
        c("markdown", "M-04", "- 第一项\n- 第二项\n- 第三项", expected: .markdown),
        c("markdown", "M-05", "1. 安装依赖\n2. 启动服务\n3. 检查日志", expected: .markdown),
        c("markdown", "M-06", "> 引用内容\n> 继续引用", expected: .markdown),
        c("markdown", "M-07", "**重点**：请阅读 [文档](https://example.com)", expected: .markdown),
        c("markdown", "M-08", "---\ntitle: Clipa\n---\n# 标题", expected: .markdown),
        c("markdown", "M-09", "#hashtag 不是标题", expected: nil),
        c("markdown", "M-10", "// # 这是代码注释", expected: nil, kind: .text),
        c("markdown", "M-11", "2026-09-09 10:00:01 INFO start", expected: nil),
        c("markdown", "M-12", "name: nginx\nimage: nginx:latest", expected: .yaml, kind: .text),
        c("markdown", "M-13", "todo: fix the login flow", expected: nil),
        c("markdown", "M-14", "Plain text with a [square bracket]", expected: nil),
        c("markdown", "M-15", "```\nfunc f() {}\n```", expected: .markdown),

        // Log
        c("log", "L-01", "2026-09-09 10:00:01 INFO server started\n2026-09-09 10:00:02 INFO ready", expected: nil),
        c("log", "L-02", "2026-09-09 10:01:23 ERROR connection refused", expected: nil),
        c("log", "L-03", "[INFO] server started\n[ERROR] db failed", expected: nil),
        c("log", "L-04", "Traceback (most recent call last):\n  File \"main.py\", line 1\nValueError: bad", expected: nil),
        c("log", "L-05", "Sep  9 10:00:01 host app[123]: INFO connection accepted", expected: nil),
        c("log", "L-06", "09-09 10:00:01.123  456  789 I ActivityManager: start proc", expected: nil),
        c("log", "L-07", "[2026-09-09 10:00:01] ERROR request failed", expected: nil),
        c("log", "L-08", "2026-09-09T10:00:01.123Z ERROR request_id=abc", expected: nil),
        c("log", "L-09", "java.lang.NullPointerException\n\tat com.example.App.main(App.java:10)", expected: nil),
        c("log", "L-10", #"{"level":"ERROR","message":"connection failed"}"#, expected: .json, kind: .text),
        c("log", "L-11", "ERROR is a common word in prose", expected: nil),
        c("log", "L-12", "INFO server started", expected: nil),
        c("log", "L-13", "2026-09-09 10:00:01 INFO config loaded\nserver:\n  port: 80\n2026-09-09 10:00:02 INFO done", expected: nil),
        c("log", "L-14", "level: ERROR\nmessage: connection failed", expected: .yaml, kind: .text),
        c("log", "L-15", "10:00:01.123 123 456 I Tag: hello", expected: nil),

        // URL/link
        c("url", "U-01", "https://example.com/a?b=1", expected: nil),
        c("url", "U-02", "example.com/path", expected: nil),
        c("url", "U-03", "www.apple.com", expected: nil),
        c("url", "U-04", "http://localhost:8080/health", expected: nil),
        c("url", "U-05", "localhost:3000", expected: nil),
        c("url", "U-06", "file:///Users/me/note.txt", expected: nil),
        c("url", "U-07", "ftp://ftp.example.com/pub/file", expected: nil),
        c("url", "U-08", "http://127.0.0.1:8443/api", expected: nil),
        c("url", "U-09", "git@github.com:openai/openai-python.git", expected: nil),
        c("url", "U-10", "mailto:admin@example.com", expected: nil),
        c("url", "U-11", "请打开 https://example.com 查看文档", expected: nil),
        c("url", "U-12", "[Clipa 文档](https://example.com)", expected: .markdown),
        c("url", "U-13", "curl https://example.com", expected: nil, kind: .text),
        c("url", "U-14", "2026-09-09 10:00:01 INFO GET https://example.com/api", expected: nil),
        c("url", "U-15", "192.168.1.1", expected: nil),

        // Email
        c("email", "E-01", "admin@example.com", expected: nil),
        c("email", "E-02", "user+test@example.com", expected: nil),
        c("email", "E-03", "dev.ops@mail.example.co.jp", expected: nil),
        c("email", "E-04", "<admin@example.com>", expected: nil),
        c("email", "E-05", "mailto:admin@example.com", expected: nil),
        c("email", "E-06", "请发送到 admin@example.com", expected: nil),
        c("email", "E-07", "admin@example", expected: nil),
        c("email", "E-08", "admin@example..com", expected: nil),
        c("email", "E-09", "admin@example.com>", expected: nil),
        c("email", "E-10", "a..b@example.com", expected: nil),
        c("email", "E-11", #"{"email":"admin@example.com"}"#, expected: .json, kind: .text),
        c("email", "E-12", "admin:\n  email: admin@example.com", expected: .yaml, kind: .text),
        c("email", "E-13", "2026-09-09 10:00:01 INFO mail admin@example.com", expected: nil),
        c("email", "E-14", "@user 不是邮箱", expected: nil),
        c("email", "E-15", "admin@example.com support@example.com", expected: nil),

        // Command
        c("command", "C-01", "git status", expected: nil, kind: .text),
        c("command", "C-02", "docker compose up -d", expected: nil, kind: .text),
        c("command", "C-03", "python3 -m http.server 8000", expected: nil, kind: .text),
        c("command", "C-04", "make build", expected: nil, kind: .text),
        c("command", "C-05", "npx create-react-app my-app", expected: nil, kind: .text),
        c("command", "C-06", "pip install requests", expected: nil, kind: .text),
        c("command", "C-07", "adb devices", expected: nil, kind: .text),
        c("command", "C-08", "xcodebuild -project App.xcodeproj -scheme App", expected: nil, kind: .text),
        c("command", "C-09", "pod install", expected: nil, kind: .text),
        c("command", "C-10", "ansible-playbook deploy.yml -i hosts", expected: nil, kind: .text),
        c("command", "C-11", "swift run", expected: nil, kind: .text),
        c("command", "C-12", "docker is a tool for running containers", expected: nil),
        c("command", "C-13", "Python is a great language", expected: nil),
        c("command", "C-14", "please run the deploy script.", expected: nil),
        c("command", "C-15", "FOO=bar node app.js && echo done", expected: nil, kind: .text),

        // Text
        c("text", "T-01", "这是一段普通的中文文本。", expected: nil),
        c("text", "T-02", "This is a normal English sentence.", expected: nil),
        c("text", "T-03", "时间: 下午三点", expected: nil),
        c("text", "T-04", "姓名: 张三\n性别: 男", expected: nil),
        c("text", "T-05", "TODO: fix the login bug", expected: nil),
        c("text", "T-06", "server at 192.168.1.1", expected: nil),
        c("text", "T-07", "contact admin@example.com", expected: nil),
        c("text", "T-08", "文档见 https://example.com", expected: nil),
        c("text", "T-09", "ERROR is not a thing", expected: nil),
        c("text", "T-10", "#hashtag and **bold** text", expected: nil),
        c("text", "T-11", "Python is fun", expected: nil),
        c("text", "T-12", "make it happen", expected: nil),
        c("text", "T-13", "docker is a container tool", expected: nil),
        c("text", "T-14", "2026-09-09 我去了公司并处理了问题", expected: nil),
        c("text", "T-15", "这是一条备忘录\n另一条没有格式的备忘录", expected: nil)
    ]

    static func run() -> Int32 {
        var failed = 0
        var total = 0
        var byCategory: [String: (total: Int, failed: Int)] = [:]

        for test in textCases {
            total += 1
            var bucket = byCategory[test.category] ?? (0, 0)
            bucket.total += 1
            let actual = SmartClassifier.inferredClassification(
                text: test.text,
                kind: test.kind
            ).smartTag
            let expected = test.expectedTag ?? .text
            if actual == expected {
                byCategory[test.category] = bucket
                continue
            }
            bucket.failed += 1
            byCategory[test.category] = bucket
            failed += 1
            print(
                "[CONFUSION-FAIL] \(test.category)-\(test.id)"
                    + " expected=\(expected.rawValue)"
                    + " actual=\(actual.rawValue)"
                    + " text=\(Self.brief(test.text))"
            )
        }

        for (category, stats) in byCategory.sorted(by: {
            $0.key < $1.key
        }) {
            print(
                "[CONFUSION-SUMMARY] \(category):"
                    + " \(stats.total - stats.failed)/\(stats.total) expected"
            )
        }
        print(
            "[CONFUSION-AUDIT] text total=\(total)"
                + " failed=\(failed)"
        )

        let mediaFailed = runMediaAudit()
        print("[CONFUSION-AUDIT] media failed=\(mediaFailed)")
        return (failed + mediaFailed) == 0 ? 0 : 1
    }

    private static func brief(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: "\\n")
        return collapsed.count > 60
            ? String(collapsed.prefix(60)) + "…"
            : collapsed
    }

    // MARK: - Image / file media audit

    private static func runMediaAudit() -> Int {
        let png = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )!
        let imageExtensions = [
            "png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp", "heic", "svg"
        ]
        let fileExtensions = [
            "txt", "pdf", "log", "zip", "json", "yaml", "csv",
            "md", "sh", "swift", "plist", "xml", "py", "html", "env"
        ]
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipaConfusionMedia-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let settings = SettingsStore(
            defaults: UserDefaults(
                suiteName: "ClipaConfusionMedia-\(UUID().uuidString)"
            )!
        )
        settings.skipSensitive = false
        let processor = ClipboardProcessor()
        var failed = 0
        var imageChecks = 0
        var fileChecks = 0
        var imageFailed = 0
        var fileFailed = 0

        func auditFile(
            _ name: String,
            data: Data,
            expected: ClipKind,
            _ id: String
        ) {
            let url = root.appendingPathComponent(name)
            try? data.write(to: url)
            let pb = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaConfusionMedia-\(UUID().uuidString)"
                )
            )
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            guard let capture = ClipboardMonitor.inspect(pb) else {
                failed += 1
                print("[CONFUSION-FAIL] media-\(id) no capture")
                return
            }
            let decision = processor.process(
                capture: capture,
                sourceName: "Test",
                policy: CapturePolicySnapshot(settings: settings),
            )
            guard case .captured(let draft) = decision else {
                failed += 1
                print("[CONFUSION-FAIL] media-\(id) decision=\(decision)")
                return
            }
            if draft.kind != expected {
                failed += 1
                if expected == .image {
                    imageFailed += 1
                } else {
                    fileFailed += 1
                }
                print(
                    "[CONFUSION-FAIL] media-\(id)"
                        + " expected=\(expected.rawValue)"
                        + " actual=\(draft.kind.rawValue)"
                        + " file=\(name)"
                )
            }
        }

        for (index, ext) in imageExtensions.enumerated() {
            auditFile(
                "sample-\(index).\(ext)",
                data: png,
                expected: .image,
                "IMG-\(index + 1)"
            )
        }
        imageChecks += imageExtensions.count
        for (index, ext) in fileExtensions.enumerated() {
            auditFile(
                "sample-\(index).\(ext)",
                data: Data("plain text".utf8),
                expected: .file,
                "FILE-\(index + 1)"
            )
        }
        fileChecks += fileExtensions.count

        // Clipa stores image bytes as-is, so a file with an image extension
        // stays an image clip even when its bytes are not a real image; the
        // preview shows a placeholder instead of the capture being lost.
        auditFile(
            "broken.png",
            data: Data("not-an-image".utf8),
            expected: .image,
            "IMG-10"
        )
        imageChecks += 1

        // Multiple file URLs are one file clip, never one image clip.
        do {
            let first = root.appendingPathComponent("multi-a.png")
            let second = root.appendingPathComponent("multi-b.png")
            try? png.write(to: first)
            try? png.write(to: second)
            let pb = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaConfusionMulti-\(UUID().uuidString)"
                )
            )
            pb.clearContents()
            pb.writeObjects([first as NSURL, second as NSURL])
            guard let capture = ClipboardMonitor.inspect(pb) else {
                failed += 1
                print("[CONFUSION-FAIL] media-multi no capture")
                return failed
            }
            let decision = processor.process(
                capture: capture,
                sourceName: "Test",
                policy: CapturePolicySnapshot(settings: settings),
            )
        if case .captured(let draft) = decision, draft.kind == .file {
                // pass
            } else {
                failed += 1
                fileFailed += 1
                print(
                    "[CONFUSION-FAIL] media-multi expected=file"
                        + " actual=\(String(describing: capture.kind))"
                )
            }
        }
        imageChecks += 1
        fileChecks += 1

        func auditPasteboardData(
            _ id: String,
            type: NSPasteboard.PasteboardType,
            data: Data
        ) {
            imageChecks += 1
            let pb = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaConfusionData-\(UUID().uuidString)"
                )
            )
            pb.clearContents()
            pb.setData(data, forType: type)
            guard let capture = ClipboardMonitor.inspect(pb) else {
                failed += 1
                print("[CONFUSION-FAIL] media-\(id) no capture")
                return
            }
            let decision = processor.process(
                capture: capture,
                sourceName: "Test",
                policy: CapturePolicySnapshot(settings: settings),
            )
            guard case .captured(let draft) = decision else {
                failed += 1
                print("[CONFUSION-FAIL] media-\(id) decision=\(decision)")
                return
            }
            if draft.kind != .image {
                failed += 1
                imageFailed += 1
                print(
                    "[CONFUSION-FAIL] media-\(id) expected=image"
                        + " actual=\(draft.kind.rawValue)"
                )
            }
        }

        auditPasteboardData(
            "IMG-11",
            type: .png,
            data: png
        )
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            auditPasteboardData(
                "IMG-12",
                type: .tiff,
                data: tiff
            )
        } else {
            failed += 1
            imageChecks += 1
            imageFailed += 1
            print("[CONFUSION-FAIL] media-IMG-12 tiff unavailable")
        }

        // A text snippet whose filename looks like an image is text.
        do {
            imageChecks += 1
            let pb = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaConfusionTextImage-\(UUID().uuidString)"
                )
            )
            pb.clearContents()
            pb.setString("screenshot.png", forType: .string)
            guard let capture = ClipboardMonitor.inspect(pb) else {
                failed += 1
                print("[CONFUSION-FAIL] media-IMG-13 no capture")
                return failed
            }
            let decision = processor.process(
                capture: capture,
                sourceName: "Test",
                policy: CapturePolicySnapshot(settings: settings),
            )
            if case .captured(let draft) = decision, draft.kind == .text {
                // pass
            } else {
                failed += 1
                imageFailed += 1
                print(
                    "[CONFUSION-FAIL] media-IMG-13 expected=text"
                        + " actual=\(String(describing: capture.kind))"
                )
            }
        }

        // A directory is a file clip even when it could be confused with media.
        do {
            imageChecks += 1
            fileChecks += 1
            let dirURL = root.appendingPathComponent(
                "Pictures",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(
                at: dirURL,
                withIntermediateDirectories: true
            )
            let pb = NSPasteboard(
                name: NSPasteboard.Name(
                    "ClipaConfusionFolder-\(UUID().uuidString)"
                )
            )
            pb.clearContents()
            pb.writeObjects([dirURL as NSURL])
            guard let capture = ClipboardMonitor.inspect(pb) else {
                failed += 1
                print("[CONFUSION-FAIL] media-IMG-14 no capture")
                return failed
            }
            let decision = processor.process(
                capture: capture,
                sourceName: "Test",
                policy: CapturePolicySnapshot(settings: settings),
            )
            if case .captured(let draft) = decision, draft.kind == .file {
                // pass
            } else {
                failed += 1
                fileFailed += 1
                print(
                    "[CONFUSION-FAIL] media-IMG-14 expected=file"
                        + " actual=\(String(describing: capture.kind))"
                )
            }
        }

        print(
            "[CONFUSION-SUMMARY] image: \(imageChecks - imageFailed)"
                + "/\(imageChecks) expected"
        )
        print(
            "[CONFUSION-SUMMARY] file: \(fileChecks - fileFailed)"
                + "/\(fileChecks) expected"
        )

        try? FileManager.default.removeItem(at: root)
        return failed
    }
}
